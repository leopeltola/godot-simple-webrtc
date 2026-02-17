extends Control

@onready var signaling_url_input: LineEdit = %SignalingUrlInput
@onready var room_id_input: LineEdit = %RoomIdInput
@onready var topology_option: OptionButton = %TopologyOption
@onready var capacity_spin: SpinBox = %CapacitySpin
@onready var refresh_button: Button = %RefreshButton
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var leave_button: Button = %LeaveButton
@onready var lobby_list: ItemList = %LobbyList
@onready var status_label: Label = %StatusLabel
@onready var log_output: RichTextLabel = %LogOutput

var _webrtc: SimpleWebRTC
var _lobby_items: Array[Dictionary] = []
var _lobby_request: HTTPRequest
var _lobby_request_in_flight: bool = false


func _ready() -> void:
	topology_option.add_item("Mesh", int(SimpleWebRTC.Topology.MESH))
	topology_option.add_item("Server Authoritative", int(SimpleWebRTC.Topology.SERVER_AUTHORITATIVE))
	topology_option.select(0)

	refresh_button.pressed.connect(_on_refresh_pressed)
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	lobby_list.item_selected.connect(_on_lobby_selected)

	var singleton: Node = SimpleWebRTC
	if singleton == null:
		status_label.text = "SimpleWebRTC autoload not found"
		_append_log("[color=red]Enable the plugin to register the autoload.[/color]")
		_set_buttons_enabled(false)
		return

	_webrtc = singleton as SimpleWebRTC
	_webrtc.lobby_list_received.connect(_on_lobby_list_received)
	_webrtc.signaling_connected.connect(_on_signaling_connected)
	_webrtc.match_ready.connect(_on_match_ready)
	_webrtc.room_closed.connect(_on_room_closed)
	_webrtc.connection_error.connect(_on_connection_error)
	_webrtc.state_changed.connect(_on_state_changed)

	_lobby_request = HTTPRequest.new()
	add_child(_lobby_request)
	_lobby_request.request_completed.connect(_on_lobby_http_completed)

	signaling_url_input.text = _webrtc.signaling_url
	status_label.text = "Ready"
	_append_log("Demo initialized.")


func _on_refresh_pressed() -> void:
	if _webrtc == null:
		return
	_webrtc.signaling_url = signaling_url_input.text.strip_edges()
	_request_lobbies_over_http(_webrtc.signaling_url)
	_append_log("Requested lobby list.")


func _request_lobbies_over_http(ws_url: String) -> void:
	if _lobby_request_in_flight:
		_append_log("Lobby request already in flight.")
		return

	var http_url: String = _lobbies_http_url_from_ws(ws_url)
	if http_url.is_empty():
		status_label.text = "Invalid signaling URL"
		_append_log("[color=red]Could not convert signaling URL to HTTP endpoint.[/color]")
		return

	var request_error: Error = _lobby_request.request(http_url)
	if request_error != OK:
		status_label.text = "Lobby request failed"
		_append_log("[color=red]HTTP request start failed: %s[/color]" % error_string(request_error))
		return

	_lobby_request_in_flight = true


func _lobbies_http_url_from_ws(ws_url: String) -> String:
	var trimmed: String = ws_url.strip_edges()
	if trimmed.is_empty():
		return ""

	var rest: String = ""
	var scheme: String = ""
	if trimmed.begins_with("ws://"):
		scheme = "http://"
		rest = trimmed.substr(5)
	elif trimmed.begins_with("wss://"):
		scheme = "https://"
		rest = trimmed.substr(6)
	else:
		return ""

	var base_url: String = "%s%s" % [scheme, rest]
	var ws_suffix_index: int = base_url.find("/ws")
	if ws_suffix_index >= 0:
		base_url = base_url.substr(0, ws_suffix_index)

	if base_url.ends_with("/"):
		return "%slobbies" % base_url
	return "%s/lobbies" % base_url


func _on_lobby_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_lobby_request_in_flight = false

	if result != HTTPRequest.RESULT_SUCCESS:
		status_label.text = "Lobby request failed"
		_append_log("[color=red]HTTP request failed with result=%d[/color]" % result)
		return

	if response_code != 200:
		status_label.text = "Lobby request failed"
		_append_log("[color=red]Unexpected HTTP status: %d[/color]" % response_code)
		return

	var payload_text: String = body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(payload_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		status_label.text = "Lobby parse failed"
		_append_log("[color=red]Invalid lobby response JSON.[/color]")
		return

	var payload: Dictionary = parsed
	var lobbies_variant: Variant = payload.get("lobbies", [])
	if typeof(lobbies_variant) != TYPE_ARRAY:
		status_label.text = "Lobby parse failed"
		_append_log("[color=red]Lobby payload missing lobbies array.[/color]")
		return

	var lobbies_raw: Array = lobbies_variant
	var lobbies_typed: Array[Dictionary] = []
	lobbies_typed.assign(lobbies_raw)
	_on_lobby_list_received(lobbies_typed)


func _on_host_pressed() -> void:
	if _webrtc == null:
		return
	var room_id: String = room_id_input.text.strip_edges()
	if room_id.is_empty():
		status_label.text = "Room ID required"
		return

	_webrtc.signaling_url = signaling_url_input.text.strip_edges()
	_webrtc.ice_servers = [
		{"urls": PackedStringArray(["stun:stun.l.google.com:19302"])}
	]

	var selected_topology: SimpleWebRTC.Topology = topology_option.get_selected_id() as SimpleWebRTC.Topology
	var capacity: int = int(capacity_spin.value)
	_webrtc.host_lobby(room_id, selected_topology, capacity)
	_append_log("Hosting room '%s' with capacity %d." % [room_id, capacity])


func _on_join_pressed() -> void:
	if _webrtc == null:
		return

	var room_id: String = room_id_input.text.strip_edges()
	if room_id.is_empty() and lobby_list.get_selected_items().size() > 0:
		var selected_index: int = lobby_list.get_selected_items()[0]
		if selected_index >= 0 and selected_index < _lobby_items.size():
			room_id = str(_lobby_items[selected_index].get("room_id", ""))

	if room_id.is_empty():
		status_label.text = "Room ID required"
		return

	_webrtc.signaling_url = signaling_url_input.text.strip_edges()
	_webrtc.ice_servers = [
		{"urls": PackedStringArray(["stun:stun.l.google.com:19302"])}
	]
	var selected_topology: SimpleWebRTC.Topology = topology_option.get_selected_id() as SimpleWebRTC.Topology
	_webrtc.join_lobby(room_id, selected_topology)
	_append_log("Joining room '%s'." % room_id)


func _on_leave_pressed() -> void:
	if _webrtc == null:
		return
	_webrtc.leave()
	_append_log("Left signaling session.")


func _on_lobby_selected(index: int) -> void:
	if index < 0 or index >= _lobby_items.size():
		return
	var lobby: Dictionary = _lobby_items[index]
	room_id_input.text = str(lobby.get("room_id", ""))
	var topology_text: String = str(lobby.get("topology", "mesh"))
	if topology_text == "server_authoritative":
		topology_option.select(1)
	else:
		topology_option.select(0)


func _on_lobby_list_received(lobbies: Array[Dictionary]) -> void:
	_lobby_items = lobbies
	lobby_list.clear()
	for lobby: Dictionary in lobbies:
		var room_id: String = str(lobby.get("room_id", "unknown"))
		var players: int = int(lobby.get("players", 0))
		var capacity: int = int(lobby.get("capacity", 0))
		var topology: String = str(lobby.get("topology", "mesh"))
		lobby_list.add_item("%s | %s | %d/%d" % [room_id, topology, players, capacity])

	status_label.text = "Lobbies: %d" % lobbies.size()
	_append_log("Received %d lobby entries." % lobbies.size())


func _on_signaling_connected(peer_id: int) -> void:
	var multiplayer_id: int = multiplayer.get_unique_id()
	status_label.text = "Signaling peer %d | Multiplayer peer %d" % [peer_id, multiplayer_id]
	_append_log("Assigned signaling peer_id=%d, Godot multiplayer unique_id=%d" % [peer_id, multiplayer_id])


func _on_match_ready() -> void:
	status_label.text = "Match ready, websocket closed"
	_append_log("match_ready received; continuing over WebRTC.")


func _on_room_closed() -> void:
	status_label.text = "Room closed by host disconnect"
	_append_log("room_closed received.")


func _on_connection_error(reason: String) -> void:
	status_label.text = "Connection error"
	_append_log("[color=red]%s[/color]" % reason)


func _on_state_changed(new_state: int) -> void:
	var state_name: String = _state_to_text(new_state)
	status_label.text = "State: %s" % state_name


func _state_to_text(state_value: int) -> String:
	match state_value:
		SimpleWebRTC.State.IDLE:
			return "IDLE"
		SimpleWebRTC.State.SIGNALING:
			return "SIGNALING"
		SimpleWebRTC.State.CONNECTED:
			return "CONNECTED"
		SimpleWebRTC.State.CLEANUP:
			return "CLEANUP"
		_:
			return "UNKNOWN"


func _append_log(message: String) -> void:
	log_output.append_text("%s\n" % message)


func _set_buttons_enabled(enabled: bool) -> void:
	refresh_button.disabled = not enabled
	host_button.disabled = not enabled
	join_button.disabled = not enabled
	leave_button.disabled = not enabled
