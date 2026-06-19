# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get                         # install deps
flutter analyze                         # lint/static analysis (keep clean)
flutter test                            # all tests
flutter test test/signaling_test.dart   # one file
flutter test --plain-name "offer POST"  # one test by name

flutter devices                         # list attached devices/sims/emulators
flutter run -d <device-id>              # run; role (camera/viewer) is chosen IN-APP, not via a build flag
flutter run -d <ios-device-id> --no-dds # iOS real-device runs: DDS attach fails intermittently; --no-dds avoids it

flutter build apk --release --split-per-abi   # camera install (arm64-v8a APK is the one for modern phones)
flutter build ios --no-codesign               # iOS compile check without signing
```

Notes: there is no emulator/simulator path for the **camera** role (no real camera); a simulator can run
the **viewer** only. First iOS device install needs the developer cert trusted on the phone
(Settings → General → VPN & Device Management) and a unique `PRODUCT_BUNDLE_IDENTIFIER`.

## Architecture

One Flutter app, **two roles chosen at runtime** (`lib/main.dart` RolePicker → `CameraPage` / `ViewerPage`,
last choice persisted via shared_preferences). **There is no backend** — the camera phone is the server.

**Signaling is embedded and one-shot.** The camera runs a `dart:io` `HttpServer` (`CameraSignalingServer`
in `lib/signaling.dart`). The viewer does a single `POST /offer` with its SDP offer and gets the SDP answer
back — **non-trickle ICE**, so all candidates are baked into the exchanged SDP. No WebSocket, no persistent
channel; reconnect = POST again (the viewer auto-retries with backoff on connection failure).

**WebRTC role split:** the viewer is the offerer (recv-only transceivers, HTTP client); the camera is the
answerer and `addTrack`s its capture onto each connection. The camera holds **one `RTCPeerConnection` per
viewer** (1→N mesh — fine for a handful of viewers, not an SFU).

**`waitForIceComplete` (`lib/ice.dart`) is load-bearing.** Because flutter_webrtc #1699 means
`RTCIceGatheringStateComplete` never fires on some Android devices, it resolves on whichever comes first:
gathering-complete, a null/empty end-of-candidates, OR a timeout. Its handlers must be registered **before**
`setLocalDescription` (which starts gathering) — see the usage block in that file.

**`kRtcConfig` has empty `iceServers` — LAN-only by design** (same WiFi; native host candidates connect
directly; nothing external is contacted). Enabling remote/cross-network starts by adding STUN/TURN here
(plus auth on the signaling server) — see README "Watching from outside the home".

**Always-on camera = Android.** The camera role starts an Android foreground service
(`flutter_foreground_task`, type `camera|microphone`) so capture survives screen-off; it must be started
while the app is foregrounded (Android 14+ rule). **iOS has no equivalent** — iOS stops camera capture the
moment the app backgrounds or the screen locks, so an iPhone camera must stay foregrounded + screen-on.
Use an **Android** phone as the camera; iPhone is fine as the viewer. Capture follows the live track, not
the on-screen renderer, so the camera can show a black "standby" UI while still streaming.

## Platform config that must stay in sync

- **Android** (`android/app/src/main/AndroidManifest.xml`): CAMERA/RECORD_AUDIO + the FGS permissions
  (`FOREGROUND_SERVICE`, `_CAMERA`, `_MICROPHONE`) and the `com.pravera.flutter_foreground_task...ForegroundService`
  declaration with `android:foregroundServiceType="camera|microphone"`. Do not rename the service.
- **iOS** (`ios/Runner/Info.plist`): `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSLocalNetworkUsageDescription` (the last is required for the viewer to reach the camera's LAN server).
