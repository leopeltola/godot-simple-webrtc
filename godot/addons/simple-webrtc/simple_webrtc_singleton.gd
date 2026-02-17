extends Node

enum Topology {
	MESH,
	SERVER_AUTHORITATIVE,
}

enum State {
	IDLE,
	SIGNALING,
	CONNECTED,
	CLEANUP,
}

signal lobby_list_received(lobbies: Array[Dictionary])
signal signaling_connected(peer_id: int)
signal match_ready()
signal room_closed()
signal connection_error(reason: String)
signal state_changed(new_state: int)

const DEFAULT_SIGNALING_URL: String = "ws://127.0.0.1:8000/ws"
const HANDSHAKE_TIMEOUT_SECONDS: float = 15.0

var signaling_url: String = DEFAULT_SIGNALING_URL
var ice_servers: Array[Dictionary] = [
	{"urls": PackedStringArray(["stun:stun.l.google.com:19302"])}
]

var _state: State = State.IDLE
var _socket: WebSocketPeer = WebSocketPeer.new()
var _webrtc_peer: WebRTCMultiplayerPeer = WebRTCMultiplayerPeer.new()
var _rtc_connections: Dictionary[int, WebRTCPeerConnection] = {}
var _rtc_connection_states: Dictionary[int, int] = {}
var _handshake_timers: Dictionary[int, Timer] = {}
var _room_id: String = ""
var _peer_id: int = 0
var _host_peer_id: int = 0
var _is_host: bool = false
var _topology: Topology = Topology.MESH
var _requested_topology: Topology = Topology.MESH
var _capacity: int = 0
var _pending_join_payload: Dictionary = {}

func _ready() -> void:
	set_process(true)
	multiplayer.peer_connected.connect(_on_peer_connected)


func _process(_delta: float) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING or _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.poll()

	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _pending_join_payload.is_empty():
			_send_to_signaling(_pending_join_payload)
			_pending_join_payload.clear()
		while _socket.get_available_packet_count() > 0:
			var packet_text: String = _socket.get_packet().get_string_from_utf8()
			_handle_signaling_packet(packet_text)
	elif _state == State.SIGNALING and _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		connection_error.emit("Signaling socket closed")
		leave()

	var rtc_peer_ids: Array = _rtc_connections.keys()
	for remote_peer_id_variant: Variant in rtc_peer_ids:
		var remote_peer_id: int = int(remote_peer_id_variant)
		if not _rtc_connections.has(remote_peer_id):
			continue
		var connection: WebRTCPeerConnection = _rtc_connections.get(remote_peer_id)
		if connection == null:
			continue
		connection.poll()
		_poll_connection_state(remote_peer_id, connection)


func refresh_lobby_list() -> void:
	_send_to_signaling({"type": "list_lobbies"})


func join_lobby(room_id: String, topology: Topology = Topology.MESH) -> void:
	_setup_webrtc_peer(ice_servers)
	_topology = topology
	_requested_topology = topology
	_connect_to_signaling(room_id, false, topology, 0)


func host_lobby(room_id: String, topology: Topology, capacity: int) -> void:
	_setup_webrtc_peer(ice_servers)
	_topology = topology
	_requested_topology = topology
	_connect_to_signaling(room_id, true, topology, capacity)


func leave() -> void:
	_transition_to(State.CLEANUP)
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "leaving")
	_cleanup()
	_transition_to(State.IDLE)


func _transition_to(new_state: State) -> void:
	_state = new_state
	state_changed.emit(int(new_state))


func _setup_webrtc_peer(config_ice_servers: Array[Dictionary]) -> void:
	ice_servers = config_ice_servers
	_webrtc_peer = WebRTCMultiplayerPeer.new()
	_rtc_connections.clear()
	_rtc_connection_states.clear()
	_clear_handshake_timers()


func _connect_to_signaling(room_id: String, is_host_intent: bool, topology: Topology, capacity: int) -> void:
	_room_id = room_id
	_is_host = is_host_intent
	_capacity = capacity
	_transition_to(State.SIGNALING)
	var connect_error: Error = _socket.connect_to_url(signaling_url)
	if connect_error != OK:
		connection_error.emit("Unable to connect to signaling server")
		_cleanup()
		_transition_to(State.IDLE)
		return

	var join_payload: Dictionary = {
		"type": "join",
		"room_id": room_id,
		"is_host_intent": is_host_intent,
		"topology": _topology_to_string(topology),
		"capacity": capacity,
	}
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_to_signaling(join_payload)
	else:
		_pending_join_payload = join_payload


func _handle_signaling_packet(raw_message: String) -> void:
	var parsed: Variant = JSON.parse_string(raw_message)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var message: Dictionary = parsed
	var message_type: String = str(message.get("type", ""))

	match message_type:
		"id_assigned":
			_handle_id_assigned(message)
		"peer_joined":
			_handle_peer_joined(message)
		"peer_left":
			_handle_peer_left(message)
		"signal":
			_handle_signal(message)
		"lobby_list":
			lobby_list_received.emit(message.get("lobbies", []))
		"match_ready":
			match_ready.emit()
			if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
				_socket.close(1000, "match ready")
			_transition_to(State.CONNECTED)
		"room_closed":
			room_closed.emit()
			leave()
		"error":
			connection_error.emit(str(message.get("message", "unknown signaling error")))
			leave()
		_:
			pass


func _handle_id_assigned(message: Dictionary) -> void:
	_peer_id = int(message.get("peer_id", 0))
	_host_peer_id = int(message.get("host_id", _peer_id))
	_is_host = _peer_id == _host_peer_id
	_capacity = int(message.get("capacity", _capacity))
	if str(message.get("topology", "mesh")) == "server_authoritative":
		_topology = Topology.SERVER_AUTHORITATIVE
	else:
		_topology = Topology.MESH
	if _topology != _requested_topology:
		connection_error.emit("Topology mismatch. Requested %s, room is %s." % [_topology_to_string(_requested_topology), _topology_to_string(_topology)])
		leave()
		return
	if message.has("ice_servers"):
		var provided: Variant = message.get("ice_servers")
		if typeof(provided) == TYPE_ARRAY:
			var provided_array: Array = provided
			var typed_ice_servers: Array[Dictionary] = []
			typed_ice_servers.assign(provided_array)
			ice_servers = typed_ice_servers
	var init_error: Error = OK
	if _topology == Topology.SERVER_AUTHORITATIVE:
		if _is_host:
			init_error = _webrtc_peer.create_server()
		else:
			init_error = _webrtc_peer.create_client(_peer_id)
	else:
		init_error = _webrtc_peer.create_mesh(_peer_id)
	if init_error != OK:
		connection_error.emit("Failed to initialize WebRTCMultiplayerPeer")
		leave()
		return
	multiplayer.multiplayer_peer = _webrtc_peer
	signaling_connected.emit(_peer_id)


func _handle_peer_joined(message: Dictionary) -> void:
	var target_peer_id: int = int(message.get("peer_id", 0))
	if target_peer_id == 0 or target_peer_id == _peer_id:
		return
	var should_offer: bool = _topology == Topology.MESH or (_topology == Topology.SERVER_AUTHORITATIVE and _is_host)
	if should_offer:
		var connection: WebRTCPeerConnection = _get_or_create_connection(target_peer_id)
		if connection == null:
			return
		var create_error: Error = connection.create_offer()
		if create_error != OK:
			connection_error.emit("Failed to create WebRTC offer")
			return
	_start_handshake_timer(target_peer_id)


func _handle_signal(message: Dictionary) -> void:
	var from_id: int = int(message.get("from_id", 0))
	if from_id == 0:
		return
	var connection: WebRTCPeerConnection = _get_or_create_connection(from_id)
	if connection == null:
		return

	if message.has("sdp"):
		var sdp_data: Dictionary = message.get("sdp", {})
		var sdp_type: String = str(sdp_data.get("type", ""))
		var sdp_value: String = str(sdp_data.get("sdp", ""))
		var remote_error: Error = connection.set_remote_description(sdp_type, sdp_value)
		if remote_error != OK:
			connection_error.emit("Failed to apply remote SDP")
			return
		if sdp_type == "offer":
			# Godot generates the answer automatically after set_remote_description("offer", ...)
			# and emits session_description_created("answer", ...).
			_start_handshake_timer(from_id)

	if message.has("ice"):
		var ice_data: Dictionary = message.get("ice", {})
		var candidate_name: String = str(ice_data.get("candidate", ""))
		var mid_name: String = str(ice_data.get("sdp_mid", "0"))
		var mline_index: int = int(ice_data.get("sdp_mline_index", 0))
		connection.add_ice_candidate(mid_name, mline_index, candidate_name)


func _handle_peer_left(message: Dictionary) -> void:
	var remote_peer_id: int = int(message.get("peer_id", 0))
	if remote_peer_id == 0:
		return
	_remove_connection(remote_peer_id)


func _get_or_create_connection(remote_peer_id: int) -> WebRTCPeerConnection:
	if _rtc_connections.has(remote_peer_id):
		return _rtc_connections[remote_peer_id]

	var connection: WebRTCPeerConnection = WebRTCPeerConnection.new()
	var init_config: Dictionary = {"iceServers": ice_servers}
	var init_error: Error = connection.initialize(init_config)
	if init_error != OK:
		connection_error.emit(
			"Failed to initialize WebRTCPeerConnection (%s). Install/enable a WebRTC backend (godot-webrtc-native) for this platform."
			% error_string(init_error)
		)
		return null

	connection.session_description_created.connect(_on_session_description_created.bind(remote_peer_id))
	connection.ice_candidate_created.connect(_on_ice_candidate_created.bind(remote_peer_id))

	var multiplayer_remote_peer_id: int = _to_multiplayer_peer_id(remote_peer_id)
	var add_error: Error = _webrtc_peer.add_peer(connection, multiplayer_remote_peer_id)
	if add_error != OK:
		connection_error.emit(
			"Failed to add peer %d to WebRTCMultiplayerPeer: %s" % [remote_peer_id, error_string(add_error)]
		)
		return null
	_rtc_connections[remote_peer_id] = connection
	_rtc_connection_states[remote_peer_id] = int(connection.get_connection_state())
	return connection


func _to_multiplayer_peer_id(remote_signal_peer_id: int) -> int:
	if _topology == Topology.MESH:
		return remote_signal_peer_id

	# Server-authoritative mapping:
	# - Host runs as multiplayer server with id=1.
	# - Clients connect only to host (peer id 1).
	# - Host sees clients with their assigned signaling ids.
	if _is_host:
		return remote_signal_peer_id
	return 1


func _on_session_description_created(sdp_type: String, sdp: String, remote_peer_id: int) -> void:
	var connection: WebRTCPeerConnection = _rtc_connections.get(remote_peer_id)
	if connection == null:
		return
	var local_error: Error = connection.set_local_description(sdp_type, sdp)
	if local_error != OK:
		connection_error.emit("Failed to set local SDP")
		return
	_send_to_signaling({
		"type": "signal",
		"target_id": remote_peer_id,
		"sdp": {
			"type": sdp_type,
			"sdp": sdp,
		},
	})


func _on_ice_candidate_created(media: String, index: int, name: String, remote_peer_id: int) -> void:
	_send_to_signaling({
		"type": "signal",
		"target_id": remote_peer_id,
		"ice": {
			"candidate": name,
			"sdp_mid": media,
			"sdp_mline_index": index,
		},
	})


func _poll_connection_state(remote_peer_id: int, connection: WebRTCPeerConnection) -> void:
	var current_state: int = int(connection.get_connection_state())
	var previous_state: int = int(_rtc_connection_states.get(remote_peer_id, -1))
	if current_state == previous_state:
		return
	_rtc_connection_states[remote_peer_id] = current_state

	if current_state == WebRTCPeerConnection.STATE_CONNECTED:
		_cancel_handshake_timer(remote_peer_id)
		_send_to_signaling({"type": "peer_connected"})
	elif current_state == WebRTCPeerConnection.STATE_FAILED or current_state == WebRTCPeerConnection.STATE_CLOSED:
		_remove_connection(remote_peer_id)
		if _state == State.CLEANUP or _state == State.IDLE:
			return
		connection_error.emit("Peer connection failed for peer %d" % remote_peer_id)
		leave()


func _remove_connection(remote_peer_id: int) -> void:
	var connection: WebRTCPeerConnection = _rtc_connections.get(remote_peer_id)
	if connection != null:
		connection.close()
	var multiplayer_remote_peer_id: int = _to_multiplayer_peer_id(remote_peer_id)
	if _webrtc_peer.has_peer(multiplayer_remote_peer_id):
		_webrtc_peer.remove_peer(multiplayer_remote_peer_id)
	_rtc_connections.erase(remote_peer_id)
	_rtc_connection_states.erase(remote_peer_id)
	_cancel_handshake_timer(remote_peer_id)


func _on_peer_connected(remote_peer_id: int) -> void:
	_cancel_handshake_timer(remote_peer_id)


func _start_handshake_timer(remote_peer_id: int) -> void:
	_cancel_handshake_timer(remote_peer_id)
	var timer: Timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = HANDSHAKE_TIMEOUT_SECONDS
	timer.timeout.connect(_on_handshake_timeout.bind(remote_peer_id))
	add_child(timer)
	_handshake_timers[remote_peer_id] = timer
	timer.start()


func _cancel_handshake_timer(remote_peer_id: int) -> void:
	if not _handshake_timers.has(remote_peer_id):
		return
	var timer: Timer = _handshake_timers[remote_peer_id]
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
	_handshake_timers.erase(remote_peer_id)


func _clear_handshake_timers() -> void:
	for timer: Timer in _handshake_timers.values():
		if is_instance_valid(timer):
			timer.stop()
			timer.queue_free()
	_handshake_timers.clear()


func _on_handshake_timeout(remote_peer_id: int) -> void:
	if _state != State.SIGNALING:
		return
	connection_error.emit("Handshake timeout for peer %d" % remote_peer_id)
	leave()


func _send_to_signaling(payload: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var serialized: String = JSON.stringify(payload)
	_socket.put_packet(serialized.to_utf8_buffer())


func _topology_to_string(topology: Topology) -> String:
	match topology:
		Topology.MESH:
			return "mesh"
		Topology.SERVER_AUTHORITATIVE:
			return "server_authoritative"
		_:
			return "mesh"


func _cleanup() -> void:
	_clear_handshake_timers()
	_rtc_connections.clear()
	_rtc_connection_states.clear()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	_peer_id = 0
	_host_peer_id = 0
	_room_id = ""
	_is_host = false
	_topology = Topology.MESH
	_requested_topology = Topology.MESH
	_capacity = 0
	_pending_join_payload.clear()
