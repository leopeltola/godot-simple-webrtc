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
	_webrtc.lobby_feed_connected.connect(_on_lobby_feed_connected)
	_webrtc.lobby_feed_disconnected.connect(_on_lobby_feed_disconnected)
	_webrtc.lobby_delta_received.connect(_on_lobby_delta_received)
	_webrtc.lobby_error.connect(_on_lobby_error)
	_webrtc.signaling_connected.connect(_on_signaling_connected)
	_webrtc.match_ready.connect(_on_match_ready)
	_webrtc.room_closed.connect(_on_room_closed)
	_webrtc.connection_error.connect(_on_connection_error)
	_webrtc.state_changed.connect(_on_state_changed)
	multiplayer.peer_connected.connect(_on_multiplayer_peer_connected)

	signaling_url_input.text = _webrtc.signaling_url
	_start_lobby_feed()
	status_label.text = "Ready"
	_append_log("Demo initialized.")


func _on_refresh_pressed() -> void:
	if _webrtc == null:
		return
	_webrtc.signaling_url = signaling_url_input.text.strip_edges()
	_start_lobby_feed()
	_append_log("Requested lobby snapshot + delta feed.")


func _start_lobby_feed() -> void:
	if _webrtc == null:
		return
	_webrtc.disconnect_lobby_feed()
	var connect_error: Error = _webrtc.connect_lobby_feed()
	if connect_error != OK:
		status_label.text = "Lobby feed failed"
		_append_log("[color=red]Unable to connect lobby feed: %s[/color]" % error_string(connect_error))
		return
	_webrtc.subscribe_lobbies()


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
	_log_connected_peer_ids("Demo ending")
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


func _on_lobby_feed_connected() -> void:
	_append_log("Lobby feed connected.")


func _on_lobby_feed_disconnected() -> void:
	_append_log("Lobby feed disconnected.")


func _on_lobby_delta_received(op: String, room_id: String, _lobby: Dictionary) -> void:
	_append_log("Lobby delta: %s %s" % [op, room_id])


func _on_lobby_error(reason: String) -> void:
	_append_log("[color=red]Lobby error: %s[/color]" % reason)


func _on_signaling_connected(peer_id: int) -> void:
	var multiplayer_id: int = multiplayer.get_unique_id()
	status_label.text = "Signaling peer %d | Multiplayer peer %d" % [peer_id, multiplayer_id]
	_append_log("Assigned signaling peer_id=%d, Godot multiplayer unique_id=%d" % [peer_id, multiplayer_id])


func _on_match_ready() -> void:
	status_label.text = "Match ready, websocket closed"
	_append_log("match_ready received; continuing over WebRTC.")
	_log_connected_peer_ids("Match ready")


func _on_multiplayer_peer_connected(remote_peer_id: int) -> void:
	_append_log("Godot multiplayer peer_connected: remote_peer_id=%d" % remote_peer_id)
	_log_connected_peer_ids("After peer_connected")


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


func _log_connected_peer_ids(context: String) -> void:
	var local_id: int = multiplayer.get_unique_id()
	var peers: PackedInt32Array = multiplayer.get_peers()
	var peer_ids_text: String = "[]"
	if peers.size() > 0:
		peer_ids_text = "[%s]" % ", ".join(Array(peers).map(func(peer_id: int) -> String: return str(peer_id)))
	_append_log("%s | local_unique_id=%d | connected_peer_ids=%s" % [context, local_id, peer_ids_text])


func _set_buttons_enabled(enabled: bool) -> void:
	refresh_button.disabled = not enabled
	host_button.disabled = not enabled
	join_button.disabled = not enabled
	leave_button.disabled = not enabled
