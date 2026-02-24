extends RefCounted

signal id_assigned(message: Dictionary)
signal peer_joined(message: Dictionary)
signal peer_left(message: Dictionary)
signal signal_received(message: Dictionary)
signal match_ready()
signal room_closed()
signal connection_error(reason: String)
signal connection_closed()

var signaling_url: String = ""

var _socket: WebSocketPeer = WebSocketPeer.new()
var _pending_join_payload: Dictionary = {}
var _last_ready_state: int = WebSocketPeer.STATE_CLOSED


func poll() -> void:
	var ready_state: int = _socket.get_ready_state()
	if ready_state == WebSocketPeer.STATE_CONNECTING or ready_state == WebSocketPeer.STATE_OPEN:
		_socket.poll()

	ready_state = _socket.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN:
		if not _pending_join_payload.is_empty():
			_send(_pending_join_payload)
			_pending_join_payload.clear()
		while _socket.get_available_packet_count() > 0:
			var packet_text: String = _socket.get_packet().get_string_from_utf8()
			_handle_packet(packet_text)
	elif _last_ready_state == WebSocketPeer.STATE_OPEN and ready_state == WebSocketPeer.STATE_CLOSED:
		connection_closed.emit()

	_last_ready_state = ready_state


func connect_to_signaling(room_id: String, is_host_intent: bool, topology: String, capacity: int) -> Error:
	if signaling_url.strip_edges().is_empty():
		connection_error.emit("signaling_url_required")
		return FAILED

	_socket = WebSocketPeer.new()
	_last_ready_state = WebSocketPeer.STATE_CLOSED
	var connect_error: Error = _socket.connect_to_url(signaling_url)
	if connect_error != OK:
		connection_error.emit("Unable to connect to signaling server")
		return connect_error

	var join_payload: Dictionary = {
		"type": "join",
		"room_id": room_id,
		"is_host_intent": is_host_intent,
		"topology": topology,
		"capacity": capacity,
	}
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send(join_payload)
	else:
		_pending_join_payload = join_payload
	return OK


func close(reason: String = "") -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, reason)
	_pending_join_payload.clear()
	_last_ready_state = WebSocketPeer.STATE_CLOSED


func send(payload: Dictionary) -> void:
	_send(payload)


func get_ready_state() -> int:
	return _socket.get_ready_state()


func _handle_packet(raw_message: String) -> void:
	var parsed: Variant = JSON.parse_string(raw_message)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var message: Dictionary = parsed
	var message_type: String = str(message.get("type", ""))

	match message_type:
		"id_assigned":
			id_assigned.emit(message)
		"peer_joined":
			peer_joined.emit(message)
		"peer_left":
			peer_left.emit(message)
		"signal":
			signal_received.emit(message)
		"match_ready":
			match_ready.emit()
		"room_closed":
			room_closed.emit()
		"error":
			connection_error.emit(str(message.get("message", "unknown signaling error")))
		_:
			pass


func _send(payload: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var serialized: String = JSON.stringify(payload)
	_socket.put_packet(serialized.to_utf8_buffer())
