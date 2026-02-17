extends Control


enum Role {
	SOLO,
	HOST,
	CLIENT,
}

@export var role: Role = Role.SOLO
@export var auto_run: bool = false
@export_range(1, 20, 1) var iterations: int = 3
@export var room_prefix: String = "simple_webrtc_autotest"
@export var signaling_url: String = "ws://127.0.0.1:8000/ws"

@onready var role_option: OptionButton = %RoleOption
@onready var iterations_spin: SpinBox = %IterationsSpin
@onready var run_button: Button = %RunButton
@onready var clear_button: Button = %ClearButton
@onready var status_label: Label = %StatusLabel
@onready var output: RichTextLabel = %Output

var _webrtc: SimpleWebRTC
var _running: bool = false

var _last_error: String = ""
var _last_signaling_peer_id: int = 0
var _match_ready_count: int = 0
var _peer_connected_count: int = 0

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	role_option.add_item("Solo (single client)", int(Role.SOLO))
	role_option.add_item("Host (paired)", int(Role.HOST))
	role_option.add_item("Client (paired)", int(Role.CLIENT))
	role_option.select(int(role))
	iterations_spin.value = iterations

	run_button.pressed.connect(_on_run_pressed)
	clear_button.pressed.connect(_on_clear_pressed)

	var singleton: Node = get_node_or_null("/root/SimpleWebRTC")
	if singleton == null:
		status_label.text = "SimpleWebRTC autoload not found"
		_append("[color=red]Enable plugin/autoload first.[/color]")
		run_button.disabled = true
		return

	_webrtc = singleton as SimpleWebRTC
	_webrtc.signaling_connected.connect(_on_signaling_connected)
	_webrtc.connection_error.connect(_on_connection_error)
	_webrtc.match_ready.connect(_on_match_ready)
	multiplayer.peer_connected.connect(_on_peer_connected)

	_append("Auto test scene ready.")
	_append("Tip: run 2 instances for paired HOST/CLIENT suites.")

	if auto_run:
		_run_suite()


func _on_run_pressed() -> void:
	_run_suite()


func _on_clear_pressed() -> void:
	output.clear()


func _run_suite() -> void:
	if _running:
		_append("Suite already running.")
		return

	_running = true
	run_button.disabled = true
	_passed = 0
	_failed = 0
	_last_error = ""
	_last_signaling_peer_id = 0
	_match_ready_count = 0
	_peer_connected_count = 0

	role = role_option.get_selected_id() as Role
	iterations = int(iterations_spin.value)

	_webrtc.signaling_url = signaling_url
	status_label.text = "Running..."
	_append("Starting suite role=%s iterations=%d" % [_role_to_text(role), iterations])

	match role:
		Role.SOLO:
			await _run_solo_suite()
		Role.HOST:
			await _run_host_suite()
		Role.CLIENT:
			await _run_client_suite()

	status_label.text = "Done: %d passed / %d failed" % [_passed, _failed]
	_append("Suite finished: %d passed / %d failed" % [_passed, _failed])
	run_button.disabled = false
	_running = false


func _run_solo_suite() -> void:
	# 1) Joining a missing room should fail early.
	_reset_observed_state()
	var missing_room: String = "%s_missing_%d" % [room_prefix, Time.get_unix_time_from_system()]
	_webrtc.join_lobby(missing_room, SimpleWebRTC.Topology.SERVER_AUTHORITATIVE)
	var got_missing_error: bool = await _wait_for_error_contains("room_not_found", 6.0)
	_assert_true("join missing room returns room_not_found", got_missing_error)
	_webrtc.leave()
	await _sleep(0.5)

	# 2) Host, leave, then host same room again.
	var room: String = "%s_solo_rehost" % room_prefix
	_reset_observed_state()
	_webrtc.host_lobby(room, SimpleWebRTC.Topology.SERVER_AUTHORITATIVE, 2)
	var host_connected_once: bool = await _wait_for_signaling_connected(6.0)
	_assert_true("host lobby connects", host_connected_once)
	_webrtc.leave()
	await _sleep(1.0)

	_reset_observed_state()
	_webrtc.host_lobby(room, SimpleWebRTC.Topology.SERVER_AUTHORITATIVE, 2)
	var host_connected_twice: bool = await _wait_for_signaling_connected(6.0)
	_assert_true("re-host same room connects", host_connected_twice)
	_webrtc.leave()
	await _sleep(0.5)


func _run_host_suite() -> void:
	_append("Host suite expects a separate CLIENT instance running the same index sequence.")
	for i: int in range(iterations):
		var room: String = "%s_pair_%02d" % [room_prefix, i]
		_append("[HOST] Iteration %d room=%s" % [i + 1, room])
		_reset_observed_state()

		_webrtc.host_lobby(room, SimpleWebRTC.Topology.SERVER_AUTHORITATIVE, 2)
		var host_ok: bool = await _wait_for_signaling_connected(8.0)
		_assert_true("host signaling connected (%s)" % room, host_ok)

		var peer_ok: bool = await _wait_for_peer_connected(20.0)
		_assert_true("host got peer_connected (%s)" % room, peer_ok)

		_webrtc.leave()
		await _sleep(2.0)


func _run_client_suite() -> void:
	_append("Client suite expects a separate HOST instance running the same index sequence.")
	for i: int in range(iterations):
		var room: String = "%s_pair_%02d" % [room_prefix, i]
		_append("[CLIENT] Iteration %d room=%s" % [i + 1, room])
		_reset_observed_state()

		await _sleep(1.5)
		_webrtc.join_lobby(room, SimpleWebRTC.Topology.SERVER_AUTHORITATIVE)

		var client_ok: bool = await _wait_for_signaling_connected(8.0)
		_assert_true("client signaling connected (%s)" % room, client_ok)

		var peer_ok: bool = await _wait_for_peer_connected(20.0)
		_assert_true("client got peer_connected (%s)" % room, peer_ok)

		_webrtc.leave()
		await _sleep(2.0)


func _reset_observed_state() -> void:
	_last_error = ""
	_last_signaling_peer_id = 0
	_match_ready_count = 0
	_peer_connected_count = 0


func _wait_for_signaling_connected(timeout_seconds: float) -> bool:
	var elapsed: float = 0.0
	while elapsed < timeout_seconds:
		if _last_signaling_peer_id > 0:
			return true
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	return false


func _wait_for_error_contains(token: String, timeout_seconds: float) -> bool:
	var elapsed: float = 0.0
	while elapsed < timeout_seconds:
		if not _last_error.is_empty() and _last_error.findn(token) >= 0:
			return true
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	return false


func _wait_for_peer_connected(timeout_seconds: float) -> bool:
	var elapsed: float = 0.0
	while elapsed < timeout_seconds:
		if _peer_connected_count > 0:
			return true
		if not _last_error.is_empty():
			return false
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	return false


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _assert_true(test_name: String, condition: bool) -> void:
	if condition:
		_passed += 1
		_append("[color=lime]PASS[/color] %s" % test_name)
	else:
		_failed += 1
		_append("[color=red]FAIL[/color] %s" % test_name)


func _on_signaling_connected(peer_id: int) -> void:
	_last_signaling_peer_id = peer_id
	_append("signaling_connected peer_id=%d multiplayer_id=%d" % [peer_id, multiplayer.get_unique_id()])


func _on_connection_error(reason: String) -> void:
	_last_error = reason
	_append("[color=red]connection_error: %s[/color]" % reason)


func _on_match_ready() -> void:
	_match_ready_count += 1
	_append("match_ready")


func _on_peer_connected(peer_id: int) -> void:
	_peer_connected_count += 1
	_append("multiplayer.peer_connected id=%d" % peer_id)


func _append(text: String) -> void:
	output.append_text("%s\n" % text)


func _role_to_text(value: Role) -> String:
	match value:
		Role.SOLO:
			return "SOLO"
		Role.HOST:
			return "HOST"
		Role.CLIENT:
			return "CLIENT"
		_:
			return "UNKNOWN"
