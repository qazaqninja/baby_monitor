import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ice.dart';
import 'signaling.dart';

/// Camera role: capture camera+mic once, run the embedded signaling server, and
/// answer every viewer with its own peer connection (1 camera -> N viewers mesh).
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
  List<String> _addresses = [];
  String _status = 'Starting…';
  bool _standby = false; // black screen to avoid OLED burn-in

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
          'width': 640,
          'height': 480,
          'frameRate': 15,
        },
      });
      _preview.srcObject = _stream;

      _server = CameraSignalingServer(_answerOffer);
      await _server!.start();
      _addresses = await localAddresses();
      setState(() => _status = 'Live — waiting for viewers');
    } catch (e) {
      setState(() => _status = 'Camera/server error: $e');
    }
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

  // Camera side of the WebRTC handshake: the viewer offered recv-only A/V, so
  // adding our tracks makes this connection send-only automatically.
  Future<RTCSessionDescription> _answerOffer(RTCSessionDescription offer) async {
    final pc = await createPeerConnection(kRtcConfig);
    _peers.add(pc);
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _peers.remove(pc);
        pc.close();
        _refreshStatus();
      }
    };

    await pc.setRemoteDescription(offer);
    for (final track in _stream!.getTracks()) {
      await pc.addTrack(track, _stream!);
    }

    final gathered = waitForIceComplete(pc);
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await gathered;

    _refreshStatus();
    return (await pc.getLocalDescription())!;
  }

  void _refreshStatus() {
    if (!mounted) return;
    final n = _peers.length;
    setState(() => _status = n == 0 ? 'Live — waiting for viewers' : 'Live — $n viewer(s)');
  }

  @override
  void dispose() {
    for (final pc in _peers) {
      pc.close();
    }
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
      // on-screen renderer). Tap anywhere to bring the status back.
      return GestureDetector(
        onTap: () => setState(() => _standby = false),
        child: const ColoredBox(color: Colors.black, child: SizedBox.expand()),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: RTCVideoView(_preview, mirror: false)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status,
                      style: const TextStyle(color: Colors.white, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    _addresses.isEmpty
                        ? 'No network address yet'
                        : 'Viewer connects to:  ${_addresses.join('  /  ')}   :$kSignalPort',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => setState(() => _standby = true),
                    icon: const Icon(Icons.dark_mode),
                    label: const Text('Standby (black screen)'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
