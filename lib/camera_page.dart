import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ice.dart';
import 'signaling.dart';
import 'theme.dart';
import 'widgets.dart';

/// Camera role: capture camera+mic once, run the embedded signaling server, and
/// answer every viewer with its own peer connection (1 camera -> N viewers mesh).
/// Audio is two-way: the camera also plays talk-back audio sent by a viewer.
class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  final _preview = RTCVideoRenderer();
  final List<RTCPeerConnection> _peers = [];
  MediaStream? _stream;
  CameraSignalingServer? _server;
  BonsoirBroadcast? _broadcast;
  List<String> _addresses = [];
  String _status = 'Starting…';
  bool _standby = false; // black screen to avoid OLED burn-in
  bool _facingFront = false; // we start on the back camera
  bool _torchOn = false;
  bool _hasTorch = false;
  bool _showQr = true; // hide once a viewer has paired

  MediaStreamTrack? get _videoTrack {
    final v = _stream?.getVideoTracks();
    return (v == null || v.isEmpty) ? null : v.first;
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _preview.initialize();
    await [Permission.camera, Permission.microphone, Permission.notification]
        .request();
    await WakelockPlus.enable();
    if (Platform.isAndroid) await _startForegroundService();

    try {
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'facingMode': 'environment',
          // ponytail: 720p30 LAN default — good quality, still fine on a spare
          // phone. Drop to 480p if very old hardware struggles.
          'width': 1280,
          'height': 720,
          'frameRate': 30,
        },
      });
      _preview.srcObject = _stream;
      // Route any talk-back audio from a viewer to the loudspeaker so it's
      // audible to the baby.
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
      _hasTorch = await _videoTrack?.hasTorch() ?? false;

      _server = CameraSignalingServer(_answerOffer, onControl: _handleControl);
      await _server!.start();

      await _triggerLocalNetwork();
      await _startBonjour();

      _addresses = await localAddresses();
      debugPrint('[CAM] server up on $_addresses :$kSignalPort');
      if (mounted) setState(() => _status = 'Waiting for viewers');
    } catch (e) {
      if (mounted) setState(() => _status = 'Camera/server error: $e');
    }
  }

  // Remote control from a viewer (POST /control). Returns current state so the
  // viewer's buttons can reflect what the camera actually did.
  Future<Map<String, dynamic>> _handleControl(String? action, bool? value) async {
    switch (action) {
      case 'switchCamera':
        await _switchCamera();
        break;
      case 'torch':
        await _setTorch(value ?? !_torchOn);
        break;
    }
    return {
      'facingFront': _facingFront,
      'torchOn': _torchOn,
      'hasTorch': _hasTorch,
    };
  }

  Future<void> _startForegroundService() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'baby_monitor',
        channelName: 'Baby Monitor Camera',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      // No repeating Dart task — we only need the service to keep the process
      // (camera capture + HTTP server) alive while backgrounded / screen-off.
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: [
        ForegroundServiceTypes.camera,
        ForegroundServiceTypes.microphone,
      ],
      notificationTitle: 'Baby Monitor',
      notificationText: 'Camera is live',
    );
  }

  // Two independent ways to surface the iOS "Local Network" permission prompt
  // (libwebrtc needs it granted to send media to the viewer's LAN address):
  // a Bonjour advertisement, and a direct outbound UDP broadcast. Whichever
  // fires the prompt first wins; both are logged so we can see what happened.
  Future<void> _startBonjour() async {
    try {
      _broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: 'Baby Monitor',
          type: '_babymonitor._tcp',
          port: kSignalPort,
        ),
      );
      await _broadcast!.initialize();
      await _broadcast!.start();
      debugPrint('[CAM] bonjour broadcast started');
    } catch (e) {
      debugPrint('[CAM] bonjour error: $e');
    }
  }

  Future<void> _triggerLocalNetwork() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      s.send(const [0], InternetAddress('255.255.255.255'), 9999);
      s.close();
      debugPrint('[CAM] local-network UDP trigger sent');
    } catch (e) {
      debugPrint('[CAM] local-network trigger error: $e');
    }
  }

  // Camera side of the WebRTC handshake: the viewer offers recv-only video and
  // sendrecv audio. Adding our tracks makes video send-only and audio two-way
  // (we send the baby's audio and receive the parent's talk-back).
  Future<RTCSessionDescription> _answerOffer(RTCSessionDescription offer) async {
    debugPrint('[CAM] offer received from a viewer');
    final pc = await createPeerConnection(kRtcConfig);
    _peers.add(pc);
    pc.onIceConnectionState = (s) => debugPrint('[CAM] ICE: $s');
    // Talk-back: the viewer's mic track arrives here; native auto-plays it.
    pc.onTrack = (e) => debugPrint('[CAM] remote track: ${e.track.kind}');
    pc.onConnectionState = (s) {
      debugPrint('[CAM] conn: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (mounted) setState(() => _showQr = false);
      }
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        if (!_peers.remove(pc)) return; // already handled (close drives events)
        pc.close().then((_) => pc.dispose()); // free native PC + event channel
        if (_peers.isEmpty && mounted) _showQr = true; // re-offer pairing
        _refreshStatus();
      }
    };

    await pc.setRemoteDescription(offer);
    for (final track in _stream!.getTracks()) {
      await pc.addTrack(track, _stream!);
    }
    await _bumpVideoBitrate(pc);

    final gathered = waitForIceComplete(pc);
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await gathered;

    _refreshStatus();
    return (await pc.getLocalDescription())!;
  }

  // Raise the encoder ceiling so 720p looks crisp on a LAN (default caps are
  // tuned for the open internet). Best-effort: ignored if the platform balks.
  Future<void> _bumpVideoBitrate(RTCPeerConnection pc) async {
    try {
      final senders = await pc.getSenders();
      for (final s in senders) {
        if (s.track?.kind != 'video') continue;
        final params = s.parameters;
        final encs = params.encodings;
        if (encs == null || encs.isEmpty) {
          params.encodings = [RTCRtpEncoding(maxBitrate: 3000000, maxFramerate: 30)];
        } else {
          for (final e in encs) {
            e.maxBitrate = 3000000;
            e.maxFramerate = 30;
          }
        }
        await s.setParameters(params);
      }
    } catch (e) {
      debugPrint('[CAM] bitrate bump skipped: $e');
    }
  }

  Future<void> _switchCamera() async {
    final track = _videoTrack;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
      _facingFront = !_facingFront;
      _torchOn = false; // torch belongs to the back camera; reset on switch
      _hasTorch = await track.hasTorch();
    } catch (e) {
      debugPrint('[CAM] switch camera error: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _setTorch(bool on) async {
    final track = _videoTrack;
    if (track == null || !_hasTorch) return; // no flash on this camera
    try {
      await track.setTorch(on);
      _torchOn = on;
    } catch (e) {
      debugPrint('[CAM] torch error: $e');
      _torchOn = false;
    }
    if (mounted) setState(() {});
  }

  Widget _qrCard(String host) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          QrImageView(data: host, size: 88, padding: EdgeInsets.zero),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Scan to connect',
                    style: TextStyle(
                        color: warmBrown,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('On the viewer phone, tap “Scan QR”.',
                    style: TextStyle(
                        color: warmBrown.withValues(alpha: 0.7), fontSize: 13)),
                const SizedBox(height: 8),
                Text('or type:  $host : $kSignalPort',
                    style: TextStyle(
                        color: warmBrown.withValues(alpha: 0.55), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _refreshStatus() {
    if (!mounted) return;
    final n = _peers.length;
    setState(() => _status = n == 0 ? 'Waiting for viewers' : 'Live · $n watching');
  }

  @override
  void dispose() {
    for (final pc in _peers) {
      pc.close().then((_) => pc.dispose());
    }
    _broadcast?.stop();
    _server?.stop();
    _stream?.getTracks().forEach((t) => t.stop());
    _stream?.dispose();
    _preview.dispose();
    WakelockPlus.disable();
    if (Platform.isAndroid) FlutterForegroundTask.stopService();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_standby) {
      // Black standby: capture keeps running (it follows the track, not the
      // on-screen renderer). Tap anywhere to bring the controls back.
      return GestureDetector(
        onTap: () => setState(() => _standby = false),
        child: const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Text('Tap to wake',
                style: TextStyle(color: Colors.white24, fontSize: 16)),
          ),
        ),
      );
    }

    final live = _peers.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(
              _preview,
              mirror: _facingFront,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
          // Top: status pill.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topLeft,
                child: StatusPill(
                  text: _status,
                  color: live ? const Color(0xFF7DD181) : warmSeed,
                ),
              ),
            ),
          ),
          // Pairing QR floats above the controls until someone connects.
          if (_showQr && _addresses.isNotEmpty)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 70, 16, 0),
                  child: _qrCard(_addresses.first),
                ),
              ),
            ),
          // Bottom: control bar.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ControlBar(
                  children: [
                    LiveControlButton(
                      icon: Icons.cameraswitch_rounded,
                      label: _facingFront ? 'Front' : 'Back',
                      onTap: _switchCamera,
                    ),
                    LiveControlButton(
                      icon: _torchOn
                          ? Icons.flashlight_on_rounded
                          : Icons.flashlight_off_rounded,
                      label: 'Light',
                      active: _torchOn,
                      enabled: _hasTorch,
                      onTap: () => _setTorch(!_torchOn),
                    ),
                    LiveControlButton(
                      icon: _showQr
                          ? Icons.qr_code_2_rounded
                          : Icons.qr_code_scanner_rounded,
                      label: 'Pair',
                      active: _showQr,
                      onTap: () => setState(() => _showQr = !_showQr),
                    ),
                    LiveControlButton(
                      icon: Icons.dark_mode_rounded,
                      label: 'Standby',
                      onTap: () => setState(() => _standby = true),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
