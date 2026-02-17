extends Node

## SimpleWebRTC singleton for lobby discovery, signaling, and WebRTC peer setup.
##
##
## This node manages the full connection lifecycle:[br]
## [br]
## - connect to signaling,[br]
## - join/host lobbies,[br]
## - exchange SDP/ICE,[br]
## - initialize [code]WebRTCMultiplayerPeer[/code],[br]
## - track handshake timeouts and cleanup.[br]
##[br]
## Assumptions:[br]
## - A compatible signaling server is available at [member signaling_url] and uses the
##   message schema expected in this script ([code]join[/code], [code]signal[/code], [code]lobby_list[/code], etc.).[br]
## - A WebRTC backend is installed/enabled for the running platform
##   ([code]godot-webrtc-native[/code]).[br]
## - Consumers call [method join_lobby] or [method host_lobby] to start a session, and call
##   [method leave] when done.[br]
##[br]
## Typical usage:[br]
## 1) Optionally set [member signaling_url] and [member ice_servers].[br]
## 2) Connect to [signal connection_error], [signal signaling_connected], and
##    [signal match_ready].[br]
## 3) Call [method host_lobby] or [method join_lobby].[br]
## 4) Wait for [signal match_ready]/multiplayer events.[br]
## 5) Call [method leave] to close and reset state.[br]

## Network topology requested/used by a lobby.
enum Topology {
	MESH,
	SERVER_AUTHORITATIVE,
}

## High-level lifecycle state for this singleton.
enum State {
	IDLE,
	SIGNALING,
	CONNECTED,
	CLEANUP,
}

## Emitted when the lobby cache is updated (from snapshot or delta events).
## [param lobbies] is an array of dictionaries supplied by the signaling server.
signal lobby_list_received(lobbies: Array[Dictionary])
## Emitted when the lobby websocket feed connects.
signal lobby_feed_connected()
## Emitted when the lobby websocket feed disconnects.
signal lobby_feed_disconnected()
## Emitted when a full lobby snapshot is received from signaling.
signal lobby_snapshot_received(lobbies: Array[Dictionary])
## Emitted when a lobby delta update is received from signaling.
## [param op] is [code]upsert[/code] or [code]remove[/code].
signal lobby_delta_received(op: String, room_id: String, lobby: Dictionary)
## Emitted for lobby feed protocol errors.
signal lobby_error(reason: String)
## Emitted after a successful signaling join and peer id assignment.
## [param peer_id] is this client's signaling id.
signal signaling_connected(peer_id: int)
## Emitted when signaling determines the room is ready to start the match.
signal match_ready()
## Emitted when the signaling server closes the room.
signal room_closed()
## Emitted for connection/signaling/WebRTC errors with a human-readable reason.
signal connection_error(reason: String)
## Emitted whenever the internal lifecycle state changes.
signal state_changed(new_state: int)

## Default WebSocket endpoint for the signaling server.
const DEFAULT_SIGNALING_URL: String = "ws://127.0.0.1:8000/ws"
## Maximum time to wait for a per-peer WebRTC handshake before failing.
const HANDSHAKE_TIMEOUT_SECONDS: float = 15.0

## Signaling server URL used by [method join_lobby] and [method host_lobby].
## Set this before connecting if your signaling server is not local.
var signaling_url: String = DEFAULT_SIGNALING_URL
## ICE server configuration passed to [method WebRTCPeerConnection.initialize].
## Defaults to Google's public STUN server. Can be replaced before joining/hosting.
var ice_servers: Array[Dictionary] = [
	{"urls": PackedStringArray(["stun:stun.l.google.com:19302"])}
]

var _state: State = State.IDLE
var _socket: WebSocketPeer = WebSocketPeer.new()
var _lobby_socket: WebSocketPeer = WebSocketPeer.new()
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
var _pending_lobby_payload: Dictionary = {}
var _lobby_filter_tags: PackedStringArray = PackedStringArray()
var _lobby_cache: Dictionary[String, Dictionary] = {}
var _lobby_last_ready_state: int = WebSocketPeer.STATE_CLOSED

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

	if _lobby_socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING or _lobby_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_lobby_socket.poll()

	if _lobby_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if _lobby_last_ready_state != WebSocketPeer.STATE_OPEN:
			lobby_feed_connected.emit()
		if not _pending_lobby_payload.is_empty():
			_send_to_lobby_feed(_pending_lobby_payload)
			_pending_lobby_payload.clear()
		while _lobby_socket.get_available_packet_count() > 0:
			var packet_text: String = _lobby_socket.get_packet().get_string_from_utf8()
			_handle_lobby_packet(packet_text)
	elif _lobby_last_ready_state == WebSocketPeer.STATE_OPEN and _lobby_socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		lobby_feed_disconnected.emit()

	_lobby_last_ready_state = _lobby_socket.get_ready_state()


## Connects the dedicated websocket lobby feed.
##
## Returns [code]OK[/code] on success or [code]FAILED[/code] if [member signaling_url]
## is invalid or the websocket cannot start connecting.
func connect_lobby_feed() -> Error:
	if signaling_url.strip_edges().is_empty():
		lobby_error.emit("signaling_url_required")
		return FAILED

	var ready_state: int = _lobby_socket.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN or ready_state == WebSocketPeer.STATE_CONNECTING:
		return OK

	_lobby_socket = WebSocketPeer.new()
	_lobby_last_ready_state = WebSocketPeer.STATE_CLOSED
	var connect_error: Error = _lobby_socket.connect_to_url(signaling_url)
	if connect_error != OK:
		lobby_error.emit("Unable to connect to lobby feed")
		return connect_error
	return OK


## Disconnects the dedicated websocket lobby feed.
func disconnect_lobby_feed() -> void:
	if _lobby_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_to_lobby_feed({"type": "unsubscribe_lobbies"})
		_lobby_socket.close(1000, "lobby feed disconnect")
	_pending_lobby_payload.clear()
	_lobby_last_ready_state = WebSocketPeer.STATE_CLOSED


## Subscribes to lobby snapshot + delta updates over the dedicated lobby feed.
##
## [param filter_tags] applies server-side tag filtering.
func subscribe_lobbies(filter_tags: PackedStringArray = PackedStringArray()) -> void:
	_lobby_filter_tags = filter_tags
	var connect_error: Error = connect_lobby_feed()
	if connect_error != OK:
		return

	var payload: Dictionary = {
		"type": "subscribe_lobbies",
		"filter_tags": Array(filter_tags),
	}
	if _lobby_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_to_lobby_feed(payload)
	else:
		_pending_lobby_payload = payload


## Unsubscribes from lobby snapshot + delta updates.
func unsubscribe_lobbies() -> void:
	_lobby_filter_tags = PackedStringArray()
	_pending_lobby_payload.clear()
	_send_to_lobby_feed({"type": "unsubscribe_lobbies"})


## Requests an on-demand lobby snapshot over websocket.
##
## This keeps compatibility with existing [signal lobby_list_received] consumers.
func refresh_lobby_list(filter_tags: PackedStringArray = PackedStringArray()) -> void:
	if filter_tags.size() > 0:
		_lobby_filter_tags = filter_tags
	var connect_error: Error = connect_lobby_feed()
	if connect_error != OK:
		return
	var payload: Dictionary = {
		"type": "list_lobbies",
		"filter_tags": Array(_lobby_filter_tags),
	}
	if _lobby_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_to_lobby_feed(payload)
	else:
		_pending_lobby_payload = payload


## Returns the current in-memory lobby cache.
func get_lobbies() -> Array[Dictionary]:
	var lobbies: Array[Dictionary] = []
	for lobby: Dictionary in _lobby_cache.values():
		lobbies.append(lobby)
	return lobbies


## Joins an existing lobby by id.
##
## [param room_id] must identify a valid room on the signaling server.
## [param topology] must match the room topology or the singleton emits
## [signal connection_error] and leaves.
##
## This initializes a fresh WebRTC session state and starts signaling.
func join_lobby(room_id: String, topology: Topology = Topology.MESH) -> void:
	_setup_webrtc_peer(ice_servers)
	_topology = topology
	_requested_topology = topology
	_connect_to_signaling(room_id, false, topology, 0)


## Hosts (creates) a lobby with the given topology and capacity.
##
## [param capacity] is forwarded to signaling and enforced server-side.
## For [code]SERVER_AUTHORITATIVE[/code], the host becomes multiplayer server peer id [code]1[/code].
##
## This initializes a fresh WebRTC session state and starts signaling.
func host_lobby(room_id: String, topology: Topology, capacity: int) -> void:
	_setup_webrtc_peer(ice_servers)
	_topology = topology
	_requested_topology = topology
	_connect_to_signaling(room_id, true, topology, capacity)


## Leaves the current lobby/session and resets all internal networking state.
##
## Safe to call from any state. This closes signaling (if open), tears down
## peer connections, clears timers, and returns to [code]State.IDLE[/code].
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
			pass
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


func _handle_lobby_packet(raw_message: String) -> void:
	var parsed: Variant = JSON.parse_string(raw_message)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var message: Dictionary = parsed
	var message_type: String = str(message.get("type", ""))

	match message_type:
		"lobby_snapshot", "lobby_list":
			_apply_lobby_snapshot(message.get("lobbies", []))
		"lobby_delta":
			_apply_lobby_delta(message)
		"error":
			lobby_error.emit(str(message.get("message", "unknown lobby error")))
		_:
			pass


func _apply_lobby_snapshot(lobbies_variant: Variant) -> void:
	if typeof(lobbies_variant) != TYPE_ARRAY:
		return
	var lobbies_raw: Array = lobbies_variant
	_lobby_cache.clear()
	for entry_variant: Variant in lobbies_raw:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var lobby: Dictionary = entry_variant
		var room_id: String = str(lobby.get("room_id", "")).strip_edges()
		if room_id.is_empty():
			continue
		_lobby_cache[room_id] = lobby

	var lobbies: Array[Dictionary] = get_lobbies()
	lobby_snapshot_received.emit(lobbies)
	lobby_list_received.emit(lobbies)


func _apply_lobby_delta(message: Dictionary) -> void:
	var op: String = str(message.get("op", "")).strip_edges().to_lower()
	var room_id: String = str(message.get("room_id", "")).strip_edges()
	var lobby: Dictionary = {}

	if op == "upsert":
		if typeof(message.get("lobby", null)) == TYPE_DICTIONARY:
			lobby = message.get("lobby")
		if room_id.is_empty():
			room_id = str(lobby.get("room_id", "")).strip_edges()
		if room_id.is_empty():
			return
		_lobby_cache[room_id] = lobby
	elif op == "remove":
		if room_id.is_empty():
			return
		_lobby_cache.erase(room_id)
	else:
		return

	lobby_delta_received.emit(op, room_id, lobby)
	lobby_list_received.emit(get_lobbies())


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


func _send_to_lobby_feed(payload: Dictionary) -> void:
	if _lobby_socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var serialized: String = JSON.stringify(payload)
	_lobby_socket.put_packet(serialized.to_utf8_buffer())


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
	_pending_lobby_payload.clear()
