# Baby Monitor

Self-hosted baby monitor. One Flutter app, two roles:

- **Camera** — a spare phone on a tripod, plugged in. Captures camera+mic and serves the stream.
- **Viewer** — the parent's phone. Watches live video + audio.

Real-time transport is **WebRTC** (sub-second latency). The camera phone runs an embedded HTTP
signaling server — **there is no backend to deploy, and nothing third-party is contacted**. Current
scope is **same-WiFi (LAN)**; see "Watching from outside the home" below for the remote options.

## How it works

```
Viewer  ──POST /offer (SDP)──►  Camera (embedded dart:io HTTP server)
        ◄──── SDP answer ─────
        ════ WebRTC media (video+audio) ════►   (direct on LAN, or over Tailscale)
```

Signaling is one HTTP request/response (non-trickle ICE — candidates are baked into the SDP).
The camera answers each viewer with its own peer connection (1 camera → a few viewers).

## Run it (same WiFi — start here)

1. Two phones on the same WiFi.
2. `flutter run` on each (or install the built app).
3. **Camera phone**: tap **Camera**, grant camera/mic. It shows its address, e.g. `192.168.1.50  :8080`.
4. **Viewer phone**: tap **Viewer**, type that address, tap **Connect**. Live video + audio.

Sanity-check signaling without the app: `curl` a POST to `http://<camera-ip>:8080/offer` (an SDP
offer JSON body) and you get an SDP answer back.

## Watching from outside the home (not set up)

Current scope is LAN-only. Two phones on different networks are both behind NAT, so remote viewing
needs a reachable "meeting point." Without a third-party app (e.g. Tailscale), the options are:

- **Router port-forward + password** — viable when the home has a real public IPv4 (not carrier-NAT).
  Forward the signaling port to the camera's LAN IP; STUN handles the (encrypted) media. Requires
  adding auth to the signaling server first, since it exposes a port to the internet.
- **Self-hosted relay on a VPS** — a small server you run (coturn, or self-hosted WireGuard/Headscale)
  brokers the connection; nothing is exposed at home. More robust, but you run a server.

`kRtcConfig` in `lib/signaling.dart` has empty `iceServers` for LAN; adding STUN/TURN there is the
first step when enabling remote.

## Camera phone: Android vs iPhone (important)

- **Android (recommended for the camera):** runs a `camera|microphone` foreground service, so it keeps
  streaming with the **screen off** (less heat, no OLED burn-in) and survives backgrounding.
- **iPhone (works, but limited):** iOS **stops the camera** the moment the app backgrounds or the screen
  locks. An iPhone camera must stay **foregrounded with the screen on**, plugged in. Use the
  **Standby (black screen)** button to dim the UI; keep the app in front. Fine for testing and
  attended use — not ideal for unattended overnight. (iPhone is perfect as the **viewer**.)

## Config
- Signaling port: `kSignalPort` in `lib/signaling.dart` (default 8080).
- Capture resolution/fps: `getUserMedia` constraints in `lib/camera_page.dart` (default 640×480@15).

## Tests
`flutter test` — exercises the signaling HTTP round-trip and error paths end-to-end.
