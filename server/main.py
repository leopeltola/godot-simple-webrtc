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

__version__ = "0.0.0"

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


class Registry:
    def __init__(self) -> None:
        self.rooms: dict[str, Room] = {}
        self.peers: dict[int, PeerSession] = {}
        self.lobby_subscriptions: dict[int, LobbySubscription] = {}
        self._next_peer_id: int = 1
        self._next_connection_id: int = 1
        self.lock: asyncio.Lock = asyncio.Lock()

    def allocate_peer_id(self) -> int:
        peer_id: int = self._next_peer_id
        self._next_peer_id += 1
        return peer_id

    def allocate_connection_id(self) -> int:
        connection_id: int = self._next_connection_id
        self._next_connection_id += 1
        return connection_id


app = FastAPI(title="SimpleWebRTC Signaling Server", version=__version__)
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
    room: Room, payload: dict[str, Any], exclude_peer_id: int | None = None
) -> None:
    send_tasks: list[asyncio.Task[Any]] = []
    for peer_id in room.peer_ids:
        if exclude_peer_id is not None and peer_id == exclude_peer_id:
            continue
        peer_session: PeerSession | None = registry.peers.get(peer_id)
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
        rooms_count: int = len(registry.rooms)
        peers_count: int = len(registry.peers)

    return {
        "status": "ok",
        "service": "simple-webrtc-signaling",
        "uptime_seconds": round(now - START_TIME, 3),
        "timestamp_unix": now,
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


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    logger.info("WebSocket accepted from %s", _client_label(websocket))
    connection_id: int = registry.allocate_connection_id()
    peer_id: int | None = None

    try:
        while True:
            message: dict[str, Any] | None = await receive_client_message(websocket)
            if message is None:
                continue
            message_type: str = str(message.get("type", ""))

            if message_type == "join":
                assigned_peer_id: int | None = await handle_join(websocket, message)
                if assigned_peer_id is not None:
                    peer_id = assigned_peer_id
                continue

            if message_type == "list_lobbies":
                await handle_list_lobbies(websocket, message)
                continue

            if message_type == "subscribe_lobbies":
                await handle_subscribe_lobbies(connection_id, websocket, message)
                continue

            if message_type == "unsubscribe_lobbies":
                await handle_unsubscribe_lobbies(connection_id)
                continue

            if peer_id is None:
                await send_error(websocket, "join_required")
                continue

            if message_type == "signal":
                await handle_signal(peer_id, message)
            elif message_type == "peer_connected":
                await handle_peer_connected(peer_id)
            else:
                await send_error(websocket, f"unknown_message_type:{message_type}")

    except WebSocketDisconnect:
        logger.info(
            "WebSocket disconnected from %s (peer_id=%s)",
            _client_label(websocket),
            peer_id,
        )
        if peer_id is not None:
            await handle_disconnect(peer_id)
        await handle_unsubscribe_lobbies(connection_id)
    except Exception:
        logger.exception(
            "Unhandled exception in websocket loop for %s (peer_id=%s)",
            _client_label(websocket),
            peer_id,
        )
        if peer_id is not None:
            await handle_disconnect(peer_id)
        await handle_unsubscribe_lobbies(connection_id)


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


async def handle_join(websocket: WebSocket, message: dict[str, Any]) -> int | None:
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
        peer_id: int = registry.allocate_peer_id()
        room: Room | None = registry.rooms.get(room_id)

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
            registry.rooms[room_id] = room
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

        registry.peers[peer_id] = PeerSession(
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

    await notify_lobby_room_changed(room_id)

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
        existing_session: PeerSession | None = registry.peers.get(existing_peer_id)
        if existing_session is None:
            continue
        await send_json(
            existing_session.websocket, {"type": "peer_joined", "peer_id": peer_id}
        )

    if room.is_full:
        await maybe_emit_match_ready(room_id)

    return peer_id


async def handle_list_lobbies(websocket: WebSocket, message: dict[str, Any]) -> None:
    tags: set[str] = _normalize_filter_tags(message.get("filter_tags", []))

    async with registry.lock:
        lobbies: list[dict[str, Any]] = _build_lobby_snapshot(
            list(registry.rooms.values()), tags
        )

    # Keep legacy lobby_list for compatibility and include new snapshot event.
    await send_json(websocket, {"type": "lobby_list", "lobbies": lobbies})
    await send_json(websocket, {"type": "lobby_snapshot", "lobbies": lobbies})


async def handle_subscribe_lobbies(
    connection_id: int, websocket: WebSocket, message: dict[str, Any]
) -> None:
    filter_tags: set[str] = _normalize_filter_tags(message.get("filter_tags", []))

    async with registry.lock:
        registry.lobby_subscriptions[connection_id] = LobbySubscription(
            connection_id=connection_id,
            websocket=websocket,
            filter_tags=filter_tags,
        )
        lobbies: list[dict[str, Any]] = _build_lobby_snapshot(
            list(registry.rooms.values()), filter_tags
        )

    await send_json(websocket, {"type": "lobby_snapshot", "lobbies": lobbies})


async def handle_unsubscribe_lobbies(connection_id: int) -> None:
    async with registry.lock:
        registry.lobby_subscriptions.pop(connection_id, None)


async def notify_lobby_room_changed(room_id: str) -> None:
    async with registry.lock:
        room: Room | None = registry.rooms.get(room_id)
        subscriptions: list[LobbySubscription] = list(
            registry.lobby_subscriptions.values()
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


async def handle_signal(from_peer_id: int, message: dict[str, Any]) -> None:
    target_id: int = int(message.get("target_id", 0))
    if target_id == 0:
        source_session: PeerSession | None = registry.peers.get(from_peer_id)
        if source_session is not None:
            await send_error(source_session.websocket, "target_id_required")
        return

    async with registry.lock:
        source_session = registry.peers.get(from_peer_id)
        target_session = registry.peers.get(target_id)
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

        room: Room | None = registry.rooms.get(source_session.room_id)
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


async def handle_peer_connected(peer_id: int) -> None:
    async with registry.lock:
        session: PeerSession | None = registry.peers.get(peer_id)
        if session is None:
            return
        room: Room | None = registry.rooms.get(session.room_id)
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

    await maybe_emit_match_ready(session.room_id)


async def maybe_emit_match_ready(room_id: str) -> None:
    async with registry.lock:
        room: Room | None = registry.rooms.get(room_id)
        if room is None:
            return

        if not room.is_full:
            return

        if len(room.connected_ack) < len(room.peer_ids):
            return

        payload: dict[str, Any] = {"type": "match_ready"}
        room.update_activity()

    logger.info("Match ready: room_id=%s players=%d", room_id, len(room.peer_ids))

    await broadcast_room(room, payload)


async def handle_disconnect(peer_id: int) -> None:
    async with registry.lock:
        session: PeerSession | None = registry.peers.pop(peer_id, None)
        if session is None:
            return
        room: Room | None = registry.rooms.get(session.room_id)
        if room is None:
            return

        room.peer_ids.discard(peer_id)
        room.connected_ack.discard(peer_id)
        room.update_activity()

        host_disconnected: bool = peer_id == room.host_id
        is_empty: bool = len(room.peer_ids) == 0
        peers_left: list[int] = list(room.peer_ids)

        if host_disconnected or is_empty:
            registry.rooms.pop(room.room_id, None)
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
        await broadcast_room(room, {"type": "room_closed"})
    elif peers_left:
        await broadcast_room(room, {"type": "peer_left", "peer_id": peer_id})

    await notify_lobby_room_changed(room.room_id)


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

        async with registry.lock:
            stale_room_ids: list[str] = [
                room_id
                for room_id, room in registry.rooms.items()
                if now - room.last_activity > stale_after_seconds
            ]

            for room_id in stale_room_ids:
                room: Room = registry.rooms.pop(room_id)
                for peer_id in list(room.peer_ids):
                    registry.peers.pop(peer_id, None)
                logger.info(
                    "Pruned stale room: room_id=%s inactive_for=%.1fs removed_peers=%d",
                    room_id,
                    now - room.last_activity,
                    len(room.peer_ids),
                )

        for room_id in stale_room_ids:
            await notify_lobby_room_changed(room_id)
