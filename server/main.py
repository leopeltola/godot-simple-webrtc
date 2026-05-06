from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any, Literal

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from dotenv import load_dotenv

load_dotenv()

Topology = Literal["mesh", "server_authoritative"]

LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("simple_webrtc.server")

DEFAULT_ICE_SERVERS: list[dict[str, Any]] = [
    {"urls": ["stun:stun.l.google.com:19302"]},
]


def _load_ice_servers() -> list[dict[str, Any]]:
    raw_value: str | None = os.getenv("ICE_SERVERS_JSON")
    if not raw_value:
        logger.info("Using default ICE servers configuration")
        return DEFAULT_ICE_SERVERS

    try:
        loaded: Any = json.loads(raw_value)
    except json.JSONDecodeError:
        logger.warning("Invalid ICE_SERVERS_JSON, falling back to default ICE servers")
        return DEFAULT_ICE_SERVERS

    if not isinstance(loaded, list):
        logger.warning("ICE_SERVERS_JSON is not a list, falling back to defaults")
        return DEFAULT_ICE_SERVERS
    validated: list[dict[str, Any]] = [
        entry for entry in loaded if isinstance(entry, dict)
    ]
    if not validated:
        logger.warning(
            "ICE_SERVERS_JSON contains no valid dict entries, using defaults"
        )
        return DEFAULT_ICE_SERVERS
    logger.info("Loaded %d ICE server entries from environment", len(validated))
    return validated


@dataclass(slots=True)
class PeerSession:
    peer_id: int
    websocket: WebSocket
    room_id: str
    joined_at: float = field(default_factory=lambda: time.time())


@dataclass(slots=True)
class LobbySubscription:
    connection_id: int
    websocket: WebSocket
    filter_tags: set[str] = field(default_factory=set)


@dataclass(slots=True)
class Room:
    room_id: str
    host_id: int
    topology: Topology
    capacity: int
    is_sealed: bool = False
    peer_ids: set[int] = field(default_factory=set)
    connected_ack: set[int] = field(default_factory=set)
    tags: list[str] = field(default_factory=list)
    last_activity: float = field(default_factory=lambda: time.time())

    def update_activity(self) -> None:
        self.last_activity = time.time()

    @property
    def is_full(self) -> bool:
        return self.capacity > 0 and len(self.peer_ids) >= self.capacity


class GameState:
    """Holds all state for a single game."""

    def __init__(self) -> None:
        self.rooms: dict[str, Room] = {}
        self.peers: dict[int, PeerSession] = {}
        self.lobby_subscriptions: dict[int, LobbySubscription] = {}
        self._next_peer_id: int = 1
        self._next_connection_id: int = 1

    def allocate_peer_id(self) -> int:
        peer_id: int = self._next_peer_id
        self._next_peer_id += 1
        return peer_id

    def allocate_connection_id(self) -> int:
        connection_id: int = self._next_connection_id
        self._next_connection_id += 1
        return connection_id


class Registry:
    def __init__(self) -> None:
        self.games: dict[str, GameState] = {}
        self.lock: asyncio.Lock = asyncio.Lock()

    def get_or_create_game(self, game_id: str) -> GameState:
        """Get or create a GameState for the given game_id."""
        if game_id not in self.games:
            self.games[game_id] = GameState()
        return self.games[game_id]


app = FastAPI(title="SimpleWebRTC Signaling Server", version="2.0.0")
registry = Registry()
ICE_SERVERS: list[dict[str, Any]] = _load_ice_servers()
START_TIME: float = time.time()


def _client_label(websocket: WebSocket) -> str:
    client = websocket.client
    if client is None:
        return "unknown"
    return f"{client.host}:{client.port}"


async def send_json(websocket: WebSocket, payload: dict[str, Any]) -> None:
    await websocket.send_json(payload)


async def send_error(websocket: WebSocket, message: str) -> None:
    logger.warning(
        "Sending protocol error to %s: %s", _client_label(websocket), message
    )
    await send_json(websocket, {"type": "error", "message": message})


async def broadcast_room(
    game_id: str,
    room: Room,
    payload: dict[str, Any],
    exclude_peer_id: int | None = None,
) -> None:
    send_tasks: list[asyncio.Task[Any]] = []
    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        for peer_id in room.peer_ids:
            if exclude_peer_id is not None and peer_id == exclude_peer_id:
                continue
            peer_session: PeerSession | None = game_state.peers.get(peer_id)
            if peer_session is None:
                continue
            send_tasks.append(
                asyncio.create_task(send_json(peer_session.websocket, payload))
            )

    if send_tasks:
        results = await asyncio.gather(*send_tasks, return_exceptions=True)
        for result in results:
            if isinstance(result, Exception):
                logger.debug("Broadcast send raised exception: %s", result)


def room_to_lobby(room: Room) -> dict[str, Any]:
    return {
        "room_id": room.room_id,
        "topology": room.topology,
        "players": len(room.peer_ids),
        "capacity": room.capacity,
        "tags": room.tags,
    }


def _normalize_filter_tags(raw_tags: Any) -> set[str]:
    if not isinstance(raw_tags, list):
        return set()
    return {str(item).strip() for item in raw_tags if str(item).strip()}


def _is_room_visible_to_filter(room: Room, filter_tags: set[str]) -> bool:
    if room.is_sealed or room.is_full:
        return False
    if filter_tags and not filter_tags.issubset(set(room.tags)):
        return False
    return True


def _build_lobby_snapshot(
    rooms: list[Room], filter_tags: set[str]
) -> list[dict[str, Any]]:
    return [
        room_to_lobby(room)
        for room in rooms
        if _is_room_visible_to_filter(room, filter_tags)
    ]


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/heartbeat")
async def heartbeat() -> dict[str, Any]:
    now: float = time.time()
    async with registry.lock:
        rooms_count: int = sum(len(gs.rooms) for gs in registry.games.values())
        peers_count: int = sum(len(gs.peers) for gs in registry.games.values())
        games_count: int = len(registry.games)

    return {
        "status": "ok",
        "service": "simple-webrtc-signaling",
        "uptime_seconds": round(now - START_TIME, 3),
        "timestamp_unix": now,
        "games": games_count,
        "rooms": rooms_count,
        "peers": peers_count,
    }


@app.get("/", response_class=HTMLResponse)
async def root_status() -> str:
    return """
        <html>
            <head><title>SimpleWebRTC Signaling</title></head>
            <body style=\"font-family: sans-serif; margin: 2rem;\">
                <h1>SimpleWebRTC Signaling Server</h1>
                <p>Server is running.</p>
                <ul>
                    <li><a href=\"/heartbeat\">/heartbeat</a></li>
                    <li><a href=\"/health\">/health</a></li>
                    <li><a href=\"/lobbies\">/lobbies</a></li>
                </ul>
                <p>WebSocket endpoint: <code>/ws</code></p>
            </body>
        </html>
        """


@app.websocket("/ws/{game_id}")
async def websocket_endpoint(websocket: WebSocket, game_id: str) -> None:
    await websocket.accept()
    logger.info(
        "WebSocket accepted from %s (game_id=%s)", _client_label(websocket), game_id
    )
    connection_id: int
    peer_id: int | None = None

    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        connection_id = game_state.allocate_connection_id()

    try:
        while True:
            message: dict[str, Any] | None = await receive_client_message(websocket)
            if message is None:
                continue
            message_type: str = str(message.get("type", ""))

            if message_type == "join":
                assigned_peer_id: int | None = await handle_join(
                    game_id, websocket, message
                )
                if assigned_peer_id is not None:
                    peer_id = assigned_peer_id
                continue

            if message_type == "list_lobbies":
                await handle_list_lobbies(game_id, websocket, message)
                continue

            if message_type == "subscribe_lobbies":
                await handle_subscribe_lobbies(
                    game_id, connection_id, websocket, message
                )
                continue

            if message_type == "unsubscribe_lobbies":
                await handle_unsubscribe_lobbies(game_id, connection_id)
                continue

            if peer_id is None:
                await send_error(websocket, "join_required")
                continue

            if message_type == "signal":
                await handle_signal(game_id, peer_id, message)
            elif message_type == "peer_connected":
                await handle_peer_connected(game_id, peer_id)
            else:
                await send_error(websocket, f"unknown_message_type:{message_type}")

    except WebSocketDisconnect:
        logger.info(
            "WebSocket disconnected from %s (game_id=%s, peer_id=%s)",
            _client_label(websocket),
            game_id,
            peer_id,
        )
        if peer_id is not None:
            await handle_disconnect(game_id, peer_id)
        await handle_unsubscribe_lobbies(game_id, connection_id)
    except Exception:
        logger.exception(
            "Unhandled exception in websocket loop for %s (game_id=%s, peer_id=%s)",
            _client_label(websocket),
            game_id,
            peer_id,
        )
        if peer_id is not None:
            await handle_disconnect(game_id, peer_id)
        await handle_unsubscribe_lobbies(game_id, connection_id)


async def receive_client_message(websocket: WebSocket) -> dict[str, Any] | None:
    raw_message: Any = await websocket.receive()
    message_type: str = str(raw_message.get("type", ""))

    if message_type == "websocket.disconnect":
        raise WebSocketDisconnect(code=int(raw_message.get("code", 1000)))

    payload_text: str | None = raw_message.get("text")
    payload_bytes: bytes | None = raw_message.get("bytes")

    if payload_text is None and payload_bytes is None:
        await send_error(websocket, "empty_payload")
        return None

    if payload_text is None and payload_bytes is not None:
        try:
            payload_text = payload_bytes.decode("utf-8")
        except UnicodeDecodeError:
            await send_error(websocket, "invalid_utf8_payload")
            return None

    if payload_text is None:
        await send_error(websocket, "empty_payload")
        return None

    try:
        parsed: Any = json.loads(payload_text)
    except json.JSONDecodeError:
        await send_error(websocket, "invalid_json")
        return None

    if not isinstance(parsed, dict):
        await send_error(websocket, "json_object_required")
        return None

    return parsed


async def handle_join(
    game_id: str, websocket: WebSocket, message: dict[str, Any]
) -> int | None:
    room_id: str = str(message.get("room_id", "")).strip()
    is_host_intent: bool = bool(message.get("is_host_intent", False))
    topology: Topology = (
        "server_authoritative"
        if str(message.get("topology", "mesh")) == "server_authoritative"
        else "mesh"
    )
    capacity: int = int(message.get("capacity", 2))
    capacity = max(2, capacity)
    tags_raw: Any = message.get("tags", [])
    tags: list[str] = (
        [str(item) for item in tags_raw] if isinstance(tags_raw, list) else []
    )

    if not room_id:
        await send_error(websocket, "room_id_required")
        return None

    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        peer_id: int = game_state.allocate_peer_id()
        room: Room | None = game_state.rooms.get(room_id)

        if room is None:
            if not is_host_intent:
                await send_error(websocket, "room_not_found")
                return None
            room = Room(
                room_id=room_id,
                host_id=peer_id,
                topology=topology,
                capacity=capacity,
                tags=tags,
            )
            game_state.rooms[room_id] = room
            logger.info(
                "Room created: room_id=%s host_id=%d topology=%s capacity=%d",
                room_id,
                peer_id,
                topology,
                capacity,
            )
        elif topology != room.topology:
            logger.warning(
                "Rejected join due to topology mismatch: room_id=%s requested=%s actual=%s",
                room_id,
                topology,
                room.topology,
            )
            await send_error(websocket, "topology_mismatch")
            return None

        if room.is_sealed or room.is_full:
            await send_error(websocket, "room_unavailable")
            return None

        if is_host_intent and room.host_id != peer_id:
            await send_error(websocket, "host_already_exists")
            return None

        room.peer_ids.add(peer_id)
        room.update_activity()
        if room.is_full:
            room.is_sealed = True

        game_state.peers[peer_id] = PeerSession(
            peer_id=peer_id, websocket=websocket, room_id=room_id
        )
        existing_peers: list[int] = [pid for pid in room.peer_ids if pid != peer_id]

        logger.info(
            "Peer joined: peer_id=%d room_id=%s host=%s players=%d/%d",
            peer_id,
            room_id,
            peer_id == room.host_id,
            len(room.peer_ids),
            room.capacity,
        )

    await notify_lobby_room_changed(game_id, room_id)

    await send_json(
        websocket,
        {
            "type": "id_assigned",
            "peer_id": peer_id,
            "host_id": room.host_id,
            "topology": room.topology,
            "capacity": room.capacity,
            "ice_servers": ICE_SERVERS,
        },
    )

    notify_peer_ids: list[int] = []
    if room.topology == "mesh":
        notify_peer_ids = existing_peers
    else:
        if room.host_id in existing_peers:
            notify_peer_ids = [room.host_id]

    for existing_peer_id in notify_peer_ids:
        existing_session: PeerSession | None = game_state.peers.get(existing_peer_id)
        if existing_session is None:
            continue
        await send_json(
            existing_session.websocket, {"type": "peer_joined", "peer_id": peer_id}
        )

    if room.is_full:
        await maybe_emit_match_ready(game_id, room_id)

    return peer_id


async def handle_list_lobbies(
    game_id: str, websocket: WebSocket, message: dict[str, Any]
) -> None:
    tags: set[str] = _normalize_filter_tags(message.get("filter_tags", []))

    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        lobbies: list[dict[str, Any]] = _build_lobby_snapshot(
            list(game_state.rooms.values()), tags
        )

    # Keep legacy lobby_list for compatibility and include new snapshot event.
    await send_json(websocket, {"type": "lobby_list", "lobbies": lobbies})
    await send_json(websocket, {"type": "lobby_snapshot", "lobbies": lobbies})


async def handle_subscribe_lobbies(
    game_id: str, connection_id: int, websocket: WebSocket, message: dict[str, Any]
) -> None:
    filter_tags: set[str] = _normalize_filter_tags(message.get("filter_tags", []))

    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        game_state.lobby_subscriptions[connection_id] = LobbySubscription(
            connection_id=connection_id,
            websocket=websocket,
            filter_tags=filter_tags,
        )
        lobbies: list[dict[str, Any]] = _build_lobby_snapshot(
            list(game_state.rooms.values()), filter_tags
        )

    await send_json(websocket, {"type": "lobby_snapshot", "lobbies": lobbies})


async def handle_unsubscribe_lobbies(game_id: str, connection_id: int) -> None:
    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        game_state.lobby_subscriptions.pop(connection_id, None)


async def notify_lobby_room_changed(game_id: str, room_id: str) -> None:
    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        room: Room | None = game_state.rooms.get(room_id)
        subscriptions: list[LobbySubscription] = list(
            game_state.lobby_subscriptions.values()
        )

    send_tasks: list[asyncio.Task[Any]] = []
    for subscription in subscriptions:
        if room is not None and _is_room_visible_to_filter(
            room, subscription.filter_tags
        ):
            payload: dict[str, Any] = {
                "type": "lobby_delta",
                "op": "upsert",
                "room_id": room.room_id,
                "lobby": room_to_lobby(room),
            }
        else:
            payload = {
                "type": "lobby_delta",
                "op": "remove",
                "room_id": room_id,
            }
        send_tasks.append(
            asyncio.create_task(send_json(subscription.websocket, payload))
        )

    if send_tasks:
        results = await asyncio.gather(*send_tasks, return_exceptions=True)
        for result in results:
            if isinstance(result, Exception):
                logger.debug("Lobby delta send raised exception: %s", result)


async def handle_signal(
    game_id: str, from_peer_id: int, message: dict[str, Any]
) -> None:
    target_id: int = int(message.get("target_id", 0))
    if target_id == 0:
        async with registry.lock:
            game_state = registry.get_or_create_game(game_id)
            source_session: PeerSession | None = game_state.peers.get(from_peer_id)
        if source_session is not None:
            await send_error(source_session.websocket, "target_id_required")
        return

    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        source_session = game_state.peers.get(from_peer_id)
        target_session = game_state.peers.get(target_id)
        if source_session is None or target_session is None:
            return

        if source_session.room_id != target_session.room_id:
            logger.warning(
                "Blocked cross-room signal: from_peer=%d(%s) to_peer=%d(%s)",
                from_peer_id,
                source_session.room_id,
                target_id,
                target_session.room_id,
            )
            await send_error(source_session.websocket, "cross_room_signal_blocked")
            return

        room: Room | None = game_state.rooms.get(source_session.room_id)
        if room is None:
            return
        room.update_activity()

        relay_payload: dict[str, Any] = {
            "type": "signal",
            "from_id": from_peer_id,
        }
        if "sdp" in message:
            relay_payload["sdp"] = message["sdp"]
        if "ice" in message:
            relay_payload["ice"] = message["ice"]

    await send_json(target_session.websocket, relay_payload)


async def handle_peer_connected(game_id: str, peer_id: int) -> None:
    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        session: PeerSession | None = game_state.peers.get(peer_id)
        if session is None:
            return
        room: Room | None = game_state.rooms.get(session.room_id)
        if room is None:
            return
        room.connected_ack.add(peer_id)
        room.update_activity()
        logger.info(
            "Peer connection ack: peer_id=%d room_id=%s acks=%d/%d",
            peer_id,
            session.room_id,
            len(room.connected_ack),
            len(room.peer_ids),
        )

    await maybe_emit_match_ready(game_id, session.room_id)


async def maybe_emit_match_ready(game_id: str, room_id: str) -> None:
    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        room: Room | None = game_state.rooms.get(room_id)
        if room is None:
            return

        if not room.is_full:
            return

        if len(room.connected_ack) < len(room.peer_ids):
            return

        payload: dict[str, Any] = {"type": "match_ready"}
        room.update_activity()

    logger.info("Match ready: room_id=%s players=%d", room_id, len(room.peer_ids))

    await broadcast_room(game_id, room, payload)


async def handle_disconnect(game_id: str, peer_id: int) -> None:
    async with registry.lock:
        game_state = registry.get_or_create_game(game_id)
        session: PeerSession | None = game_state.peers.pop(peer_id, None)
        if session is None:
            return
        room: Room | None = game_state.rooms.get(session.room_id)
        if room is None:
            return

        room.peer_ids.discard(peer_id)
        room.connected_ack.discard(peer_id)
        room.update_activity()

        host_disconnected: bool = peer_id == room.host_id
        is_empty: bool = len(room.peer_ids) == 0
        peers_left: list[int] = list(room.peer_ids)

        if host_disconnected or is_empty:
            game_state.rooms.pop(room.room_id, None)
        else:
            room.is_sealed = False

        logger.info(
            "Peer disconnected: peer_id=%d room_id=%s host_disconnected=%s remaining=%d",
            peer_id,
            room.room_id,
            host_disconnected,
            len(peers_left),
        )

    if host_disconnected:
        await broadcast_room(game_id, room, {"type": "room_closed"})
    elif peers_left:
        await broadcast_room(game_id, room, {"type": "peer_left", "peer_id": peer_id})

    await notify_lobby_room_changed(game_id, room.room_id)


@app.on_event("startup")
async def startup_event() -> None:
    app.state.prune_task = asyncio.create_task(prune_stale_rooms())
    logger.info("Server startup complete; stale room prune task started")


@app.on_event("shutdown")
async def shutdown_event() -> None:
    prune_task: asyncio.Task[Any] | None = getattr(app.state, "prune_task", None)
    if prune_task is not None:
        prune_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await prune_task
    logger.info("Server shutdown complete")


async def prune_stale_rooms() -> None:
    stale_after_seconds: float = 60.0
    while True:
        await asyncio.sleep(60.0)
        now: float = time.time()

        # Collect stale rooms across all games
        stale_rooms: list[tuple[str, str, Room]] = []  # (game_id, room_id, room)

        async with registry.lock:
            for game_id, game_state in registry.games.items():
                for room_id, room in list(game_state.rooms.items()):
                    if now - room.last_activity > stale_after_seconds:
                        stale_rooms.append((game_id, room_id, room))

        # Prune stale rooms and cleanup peers
        for game_id, room_id, room in stale_rooms:
            async with registry.lock:
                game_state = registry.games.get(game_id)
                if game_state is None:
                    continue
                removed_room = game_state.rooms.pop(room_id, None)
                if removed_room is None:
                    continue
                for peer_id in list(removed_room.peer_ids):
                    game_state.peers.pop(peer_id, None)
                logger.info(
                    "Pruned stale room: game_id=%s room_id=%s inactive_for=%.1fs removed_peers=%d",
                    game_id,
                    room_id,
                    now - removed_room.last_activity,
                    len(removed_room.peer_ids),
                )

            await notify_lobby_room_changed(game_id, room_id)
