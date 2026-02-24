extends Node

signal connection_error(reason: String)
signal peer_connected(remote_peer_id: int)
signal signaling_payload(payload: Dictionary)

var handshake_timeout_seconds: float = 15.0
var ice_servers: Array[Dictionary] = []
var topology: int = 0
var is_host: bool = false

var _webrtc_peer: WebRTCMultiplayerPeer = WebRTCMultiplayerPeer.new()
var _rtc_connections: Dictionary[int, WebRTCPeerConnection] = {}
var _rtc_connection_states: Dictionary[int, int] = {}
var _handshake_timers: Dictionary[int, Timer] = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)


func reset(config_ice_servers: Array[Dictionary]) -> void:
	ice_servers = config_ice_servers
	_webrtc_peer = WebRTCMultiplayerPeer.new()
	_rtc_connections.clear()
	_rtc_connection_states.clear()
	_clear_handshake_timers()


func initialize_peer(peer_id: int, new_topology: int, host_flag: bool) -> Error:
	topology = new_topology
	is_host = host_flag

	var init_error: Error = OK
	if topology == 1:
		if is_host:
			init_error = _webrtc_peer.create_server()
		else:
			init_error = _webrtc_peer.create_client(peer_id)
	else:
		init_error = _webrtc_peer.create_mesh(peer_id)

	if init_error != OK:
		return init_error
	multiplayer.multiplayer_peer = _webrtc_peer
	return OK


func poll() -> void:
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


func handle_peer_joined(remote_peer_id: int, should_offer: bool) -> void:
	if remote_peer_id == 0:
		return
	if should_offer:
		var connection: WebRTCPeerConnection = _get_or_create_connection(remote_peer_id)
		if connection == null:
			return
		var create_error: Error = connection.create_offer()
		if create_error != OK:
			connection_error.emit("Failed to create WebRTC offer")
			return
	_start_handshake_timer(remote_peer_id)


func handle_signal(message: Dictionary) -> void:
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
			_start_handshake_timer(from_id)

	if message.has("ice"):
		var ice_data: Dictionary = message.get("ice", {})
		var candidate_name: String = str(ice_data.get("candidate", ""))
		var mid_name: String = str(ice_data.get("sdp_mid", "0"))
		var mline_index: int = int(ice_data.get("sdp_mline_index", 0))
		connection.add_ice_candidate(mid_name, mline_index, candidate_name)


func remove_connection(remote_peer_id: int) -> void:
	var connection: WebRTCPeerConnection = _rtc_connections.get(remote_peer_id)
	if connection != null:
		connection.close()
	var multiplayer_remote_peer_id: int = _to_multiplayer_peer_id(remote_peer_id)
	if _webrtc_peer.has_peer(multiplayer_remote_peer_id):
		_webrtc_peer.remove_peer(multiplayer_remote_peer_id)
	_rtc_connections.erase(remote_peer_id)
	_rtc_connection_states.erase(remote_peer_id)
	_cancel_handshake_timer(remote_peer_id)


func cleanup() -> void:
	_clear_handshake_timers()
	_rtc_connections.clear()
	_rtc_connection_states.clear()
	for peer_id in multiplayer.get_peers():
		var peer: WebRTCMultiplayerPeer = multiplayer.multiplayer_peer
		peer.disconnect_peer(peer_id)
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null


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
	if topology == 0:
		return remote_signal_peer_id

	if is_host:
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
	signaling_payload.emit({
		"type": "signal",
		"target_id": remote_peer_id,
		"sdp": {
			"type": sdp_type,
			"sdp": sdp,
		},
	})


func _on_ice_candidate_created(media: String, index: int, name: String, remote_peer_id: int) -> void:
	signaling_payload.emit({
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
		peer_connected.emit(remote_peer_id)
	elif current_state == WebRTCPeerConnection.STATE_FAILED or current_state == WebRTCPeerConnection.STATE_CLOSED:
		remove_connection(remote_peer_id)
		connection_error.emit("Peer connection failed for peer %d" % remote_peer_id)


func _on_peer_connected(remote_peer_id: int) -> void:
	_cancel_handshake_timer(remote_peer_id)


func _start_handshake_timer(remote_peer_id: int) -> void:
	_cancel_handshake_timer(remote_peer_id)
	var timer: Timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = handshake_timeout_seconds
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
	connection_error.emit("Handshake timeout for peer %d" % remote_peer_id)


