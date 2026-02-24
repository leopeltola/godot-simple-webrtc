extends RefCounted

signal lobby_list_received(lobbies: Array[Dictionary])
signal lobby_feed_connected()
signal lobby_feed_disconnected()
signal lobby_snapshot_received(lobbies: Array[Dictionary])
signal lobby_delta_received(op: String, room_id: String, lobby: Dictionary)
signal lobby_error(reason: String)

var signaling_url: String = ""

var _socket: WebSocketPeer = WebSocketPeer.new()
var _pending_payload: Dictionary = {}
var _filter_tags: PackedStringArray = PackedStringArray()
var _lobby_cache: Dictionary[String, Dictionary] = {}
var _last_ready_state: int = WebSocketPeer.STATE_CLOSED


func poll() -> void:
	var ready_state: int = _socket.get_ready_state()
	if ready_state == WebSocketPeer.STATE_CONNECTING or ready_state == WebSocketPeer.STATE_OPEN:
		_socket.poll()

	ready_state = _socket.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN:
		if _last_ready_state != WebSocketPeer.STATE_OPEN:
			lobby_feed_connected.emit()
		if not _pending_payload.is_empty():
			_send(_pending_payload)
			_pending_payload.clear()
		while _socket.get_available_packet_count() > 0:
			var packet_text: String = _socket.get_packet().get_string_from_utf8()
			_handle_packet(packet_text)
	elif _last_ready_state == WebSocketPeer.STATE_OPEN and ready_state == WebSocketPeer.STATE_CLOSED:
		lobby_feed_disconnected.emit()

	_last_ready_state = ready_state


func connect_lobby_feed() -> Error:
	if signaling_url.strip_edges().is_empty():
		lobby_error.emit("signaling_url_required")
		return FAILED

	var ready_state: int = _socket.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN or ready_state == WebSocketPeer.STATE_CONNECTING:
		return OK

	_socket = WebSocketPeer.new()
	_last_ready_state = WebSocketPeer.STATE_CLOSED
	var connect_error: Error = _socket.connect_to_url(signaling_url)
	if connect_error != OK:
		lobby_error.emit("Unable to connect to lobby feed")
		return connect_error
	return OK


func disconnect_lobby_feed() -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send({"type": "unsubscribe_lobbies"})
		_socket.close(1000, "lobby feed disconnect")
	_pending_payload.clear()
	_last_ready_state = WebSocketPeer.STATE_CLOSED


func subscribe_lobbies(filter_tags: PackedStringArray = PackedStringArray()) -> void:
	_filter_tags = filter_tags
	var connect_error: Error = connect_lobby_feed()
	if connect_error != OK:
		return

	var payload: Dictionary = {
		"type": "subscribe_lobbies",
		"filter_tags": Array(filter_tags),
	}
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send(payload)
	else:
		_pending_payload = payload


func unsubscribe_lobbies() -> void:
	_filter_tags = PackedStringArray()
	_pending_payload.clear()
	_send({"type": "unsubscribe_lobbies"})


func refresh_lobby_list(filter_tags: PackedStringArray = PackedStringArray()) -> void:
	if filter_tags.size() > 0:
		_filter_tags = filter_tags
	var connect_error: Error = connect_lobby_feed()
	if connect_error != OK:
		return
	var payload: Dictionary = {
		"type": "list_lobbies",
		"filter_tags": Array(_filter_tags),
	}
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send(payload)
	else:
		_pending_payload = payload


func get_lobbies() -> Array[Dictionary]:
	var lobbies: Array[Dictionary] = []
	for lobby: Dictionary in _lobby_cache.values():
		lobbies.append(lobby)
	return lobbies


func _handle_packet(raw_message: String) -> void:
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


func _send(payload: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var serialized: String = JSON.stringify(payload)
	_socket.put_packet(serialized.to_utf8_buffer())
