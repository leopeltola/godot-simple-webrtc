extends Node

const LobbyFeedClient = preload("res://addons/simple-webrtc/internal/lobby_feed_client.gd")
const SignalingClient = preload("res://addons/simple-webrtc/internal/signaling_client.gd")
const WebRTCSession = preload("res://addons/simple-webrtc/internal/webrtc_session.gd")

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

## Human-readable messages for signaling error codes.
const SIGNALING_ERROR_MESSAGES: Dictionary = {
	"signaling_url_required": "Signaling URL is missing. Set game_id and signaling_server_url before joining.",
	"room_id_required": "Room ID is required to join or host a lobby.",
	"room_not_found": "Lobby not found. Check the room id or host the lobby first.",
	"topology_mismatch": "Topology mismatch. The lobby uses a different topology.",
	"room_unavailable": "Lobby is full or unavailable.",
	"host_already_exists": "A host already exists for this lobby.",
	"join_required": "Join the lobby before sending signaling messages.",
	"invalid_json": "Received invalid JSON from signaling server.",
	"json_object_required": "Received non-object JSON from signaling server.",
	"invalid_utf8_payload": "Received invalid UTF-8 payload from signaling server.",
	"empty_payload": "Received empty payload from signaling server.",
}

## Default WebSocket endpoint for the signaling server.
const DEFAULT_SIGNALING_URL: String = "ws://127.0.0.1:8000/ws"
## Maximum time to wait for a per-peer WebRTC handshake before failing.
const HANDSHAKE_TIMEOUT_SECONDS: float = 15.0

## Signaling server base URL (without game_id). Game ID will be appended to this URL.
## Set this before connecting if your signaling server is not local.
var signaling_server_url: String = "ws://127.0.0.1:8000/ws"
## Game ID for this client. This scopes all lobbies and matchmaking to this game.
## Must be set before calling join_lobby() or host_lobby().
var game_id: String = ""
## ICE server configuration passed to [method WebRTCPeerConnection.initialize].
## Defaults to Google's public STUN server. Can be replaced before joining/hosting.
var ice_servers: Array[Dictionary] = [
	{"urls": PackedStringArray(["stun:stun.l.google.com:19302"])}
]

var _state: State = State.IDLE
var _signaling: SignalingClient
var _lobby_feed: LobbyFeedClient
var _session: WebRTCSession
var _room_id: String = ""
var _peer_id: int = 0
var _host_peer_id: int = 0
var _is_host: bool = false
var _topology: Topology = Topology.MESH
var _requested_topology: Topology = Topology.MESH
var _capacity: int = 0

func _ready() -> void:
	set_process(true)
	_session = WebRTCSession.new()
	_session.handshake_timeout_seconds = HANDSHAKE_TIMEOUT_SECONDS
	_session.connection_error.connect(_on_session_connection_error)
	_session.peer_connected.connect(_on_session_peer_connected)
	_session.signaling_payload.connect(_on_session_signaling_payload)
	add_child(_session)

	_signaling = SignalingClient.new()
	_signaling.id_assigned.connect(_handle_id_assigned)
	_signaling.peer_joined.connect(_handle_peer_joined)
	_signaling.peer_left.connect(_handle_peer_left)
	_signaling.signal_received.connect(_handle_signal)
	_signaling.match_ready.connect(_on_match_ready)
	_signaling.room_closed.connect(_on_room_closed)
	_signaling.connection_error.connect(_on_signaling_error)
	_signaling.connection_closed.connect(_on_signaling_closed)

	_lobby_feed = LobbyFeedClient.new()
	_lobby_feed.lobby_list_received.connect(_on_lobby_list_received)
	_lobby_feed.lobby_feed_connected.connect(_on_lobby_feed_connected)
	_lobby_feed.lobby_feed_disconnected.connect(_on_lobby_feed_disconnected)
	_lobby_feed.lobby_snapshot_received.connect(_on_lobby_snapshot_received)
	_lobby_feed.lobby_delta_received.connect(_on_lobby_delta_received)
	_lobby_feed.lobby_error.connect(_on_lobby_error)


func _process(_delta: float) -> void:
	_signaling.poll()
	_session.poll()
	_lobby_feed.poll()


func _get_signaling_url() -> String:
	if game_id == "":
		push_error("game_id must be set before connecting")
		return ""
	return signaling_server_url.trim_suffix("/") + "/" + game_id


## Connects the dedicated websocket lobby feed.
##
## Returns [code]OK[/code] on success or [code]FAILED[/code] if [member game_id]
## is empty, [member signaling_server_url] is invalid, or the websocket cannot start connecting.
func connect_lobby_feed() -> Error:
	_lobby_feed.signaling_url = _get_signaling_url()
	return _lobby_feed.connect_lobby_feed()


## Disconnects the dedicated websocket lobby feed.
func disconnect_lobby_feed() -> void:
	_lobby_feed.disconnect_lobby_feed()


## Subscribes to lobby snapshot + delta updates over the dedicated lobby feed.
##
## [param filter_tags] applies server-side tag filtering.
func subscribe_lobbies(filter_tags: PackedStringArray = PackedStringArray()) -> void:
	_lobby_feed.signaling_url = _get_signaling_url()
	_lobby_feed.subscribe_lobbies(filter_tags)


## Unsubscribes from lobby snapshot + delta updates.
func unsubscribe_lobbies() -> void:
	_lobby_feed.unsubscribe_lobbies()


## Requests an on-demand lobby snapshot over websocket.
##
## This keeps compatibility with existing [signal lobby_list_received] consumers.
func refresh_lobby_list(filter_tags: PackedStringArray = PackedStringArray()) -> void:
	_lobby_feed.signaling_url = _get_signaling_url()
	_lobby_feed.refresh_lobby_list(filter_tags)


## Returns the current in-memory lobby cache.
func get_lobbies() -> Array[Dictionary]:
	return _lobby_feed.get_lobbies()


## Joins an existing lobby by id.
##
## [param room_id] must identify a valid room on the signaling server.
## [param topology] must match the room topology or the singleton emits
## [signal connection_error] and leaves.
##
## This initializes a fresh WebRTC session state and starts signaling.
func join_lobby(room_id: String, topology: Topology = Topology.MESH) -> void:
	_session.reset(ice_servers)
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
	_session.reset(ice_servers)
	_topology = topology
	_requested_topology = topology
	_connect_to_signaling(room_id, true, topology, capacity)


## Leaves the current lobby/session and resets all internal networking state.
##
## Safe to call from any state. This closes signaling (if open), tears down
## peer connections, clears timers, and returns to [code]State.IDLE[/code].
func leave() -> void:
	_transition_to(State.CLEANUP)
	_signaling.close("leaving")
	_cleanup()
	_transition_to(State.IDLE)


func _transition_to(new_state: State) -> void:
	_state = new_state
	state_changed.emit(int(new_state))


func _connect_to_signaling(room_id: String, is_host_intent: bool, topology: Topology, capacity: int) -> void:
	_room_id = room_id
	_is_host = is_host_intent
	_capacity = capacity
	_transition_to(State.SIGNALING)
	_signaling.signaling_url = _get_signaling_url()
	var connect_error: Error = _signaling.connect_to_signaling(room_id, is_host_intent, _topology_to_string(topology), capacity)
	if connect_error != OK:
		_cleanup()
		_transition_to(State.IDLE)


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
	_session.ice_servers = ice_servers
	var init_error: Error = _session.initialize_peer(_peer_id, int(_topology), _is_host)
	if init_error != OK:
		connection_error.emit("Failed to initialize WebRTCMultiplayerPeer")
		leave()
		return
	signaling_connected.emit(_peer_id)


func _handle_peer_joined(message: Dictionary) -> void:
	var target_peer_id: int = int(message.get("peer_id", 0))
	if target_peer_id == 0 or target_peer_id == _peer_id:
		return
	var should_offer: bool = _topology == Topology.MESH or (_topology == Topology.SERVER_AUTHORITATIVE and _is_host)
	_session.handle_peer_joined(target_peer_id, should_offer)


func _handle_signal(message: Dictionary) -> void:
	_session.handle_signal(message)


func _handle_peer_left(message: Dictionary) -> void:
	var remote_peer_id: int = int(message.get("peer_id", 0))
	if remote_peer_id == 0:
		return
	_session.remove_connection(remote_peer_id)


func _topology_to_string(topology: Topology) -> String:
	match topology:
		Topology.MESH:
			return "mesh"
		Topology.SERVER_AUTHORITATIVE:
			return "server_authoritative"
		_:
			return "mesh"


func _cleanup() -> void:
	_session.cleanup()
	_peer_id = 0
	_host_peer_id = 0
	_room_id = ""
	_is_host = false
	_topology = Topology.MESH
	_requested_topology = Topology.MESH
	_capacity = 0


func _on_signaling_error(reason: String) -> void:
	var friendly_reason: String = _format_signaling_error(reason)
	connection_error.emit(friendly_reason)
	leave()


func _on_signaling_closed() -> void:
	if _state == State.SIGNALING:
		connection_error.emit("Signaling socket closed")
		leave()


func _on_match_ready() -> void:
	match_ready.emit()
	_signaling.close("match ready")
	_transition_to(State.CONNECTED)


func _on_room_closed() -> void:
	room_closed.emit()
	leave()


func _on_session_connection_error(reason: String) -> void:
	if _state == State.CLEANUP or _state == State.IDLE:
		return
	connection_error.emit(reason)
	leave()


func _on_session_peer_connected(_remote_peer_id: int) -> void:
	_signaling.send({"type": "peer_connected"})


func _on_session_signaling_payload(payload: Dictionary) -> void:
	_signaling.send(payload)


func _on_lobby_list_received(lobbies: Array[Dictionary]) -> void:
	lobby_list_received.emit(lobbies)


func _on_lobby_feed_connected() -> void:
	lobby_feed_connected.emit()


func _on_lobby_feed_disconnected() -> void:
	lobby_feed_disconnected.emit()


func _on_lobby_snapshot_received(lobbies: Array[Dictionary]) -> void:
	lobby_snapshot_received.emit(lobbies)


func _on_lobby_delta_received(op: String, room_id: String, lobby: Dictionary) -> void:
	lobby_delta_received.emit(op, room_id, lobby)


func _on_lobby_error(reason: String) -> void:
	lobby_error.emit(reason)
	push_error(reason)


func _format_signaling_error(reason: String) -> String:
	var trimmed_reason: String = reason.strip_edges()
	if trimmed_reason.is_empty():
		return "Unknown signaling error"
	var code: String = trimmed_reason
	if ":" in trimmed_reason:
		code = trimmed_reason.split(":", false, 1)[0]
	if SIGNALING_ERROR_MESSAGES.has(code):
		return SIGNALING_ERROR_MESSAGES[code]
	return trimmed_reason
