# SimpleWebRTC

SimpleWebRTC makes it easier to use WebRTC in your Godot game. It's a lightweight project that handles signaling and has a simple lobby system. 

The project has two parts:

- Godot addon: `godot/addons/simple-webrtc`
- Python server: `server/`

## Quick start

### 1) Install addon in your Godot project

Download the `simple-webrtc-addon-vX.X.X.zip` from releases and extract it in your Godot game project's root folder. 

Then enable the plugin in **Project > Project Settings > Plugins**.

### 2) Run signaling server

For development, it can be convenient to run the server locally. Clone this repository, ensure you have `uv` installed, and run

```bash
cd server
uv fastapi dev main.py
```

To actually allow your players to play together, you need to host the signaling server on a separate server exposed to the internet. You can use whatever, but e.g. Hetzner works well and is affordable. Your server doesn't need to be powerful since it only handles connecting clients and doesn't run any game logic itself.

A Docker image is provided with every release and is the easiest way to run the server. 

```bash
docker run --rm -p 8000:8000 --env-file server/.env ghcr.io/leopeltola/godot-simple-webrtc-server:latest
```

or however you prefer to run the Docker image. 

### 3) Point your game to signaling URL

`SimpleWebRTC.signaling_url = "wss://mygameserver.com"` or whatever your url is

## License

MIT