## SimpleWebRTC v2 Signaling Server

FastAPI signaling relay for the Godot addon.

### Features

- Room registry with `room_id`, `host_id`, `peer_ids`, sealed/full state.
- Validated `signal` relay only for peers in the same room.
- Lobby listing via WebSocket (`list_lobbies`) and HTTP (`GET /lobbies`).
- Host disconnect handling (`room_closed` broadcast + room cleanup).
- Stale room pruning every 60 seconds.

### Run

```bash
uv run uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### Run with Docker

Build:

```bash
docker build -t simple-webrtc-server:local server
```

Run:

```bash
docker run --rm -p 8000:8000 --env-file server/.env simple-webrtc-server:local
```

### .env support (debug-friendly)

The server automatically loads environment variables from `.env` using `python-dotenv`.

1. Copy `.env.example` to `.env`.
2. Edit values (for example `ICE_SERVERS_JSON`, `LOG_LEVEL`).
3. Start/restart the server.

### Optional env vars

- `ICE_SERVERS_JSON`: JSON array returned in `id_assigned`.
- `LOG_LEVEL`: logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`).

Example:

```json
[
	{"urls": ["stun:stun.l.google.com:19302"]},
	{"urls": ["turn:turn.example.com"], "username": "user", "credential": "password"}
]
```

### Protocol Messages

- `list_lobbies` (C→S)
- `join` (C→S)
- `id_assigned` (S→C)
- `peer_joined` (S→C)
- `signal` (C↔S)
- `match_ready` (S→C)
- `room_closed` (S→C)

### Automated releases

Pushing a SemVer tag (`vX.Y.Z`) triggers GitHub Actions to:

- build a Godot addon zip and attach it to a GitHub Release,
- build and push a Docker image to GHCR.
