import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ice.dart';
import 'signaling.dart';

/// Viewer role: enter the camera's address, POST an offer, and render the
/// returned stream. Auto-reconnects (a WiFi blip otherwise kills it forever).
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final _remote = RTCVideoRenderer();
  final _addr = TextEditingController();
  RTCPeerConnection? _pc;
  MediaStreamTrack? _audioTrack;
  Timer? _retry;
  bool _disposed = false;
  bool _watching = false; // user pressed Connect (controls auto-reconnect)
  bool _muted = false;
  int _backoff = 1;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _remote.initialize();
    final prefs = await SharedPreferences.getInstance();
    _addr.text = prefs.getString('camera_addr') ?? '';
    setState(() {});
  }

  Future<void> _connect() async {
    final host = _addr.text.trim();
    if (host.isEmpty) return;
    (await SharedPreferences.getInstance()).setString('camera_addr', host);
    _watching = true;
    await _dial();
  }

  Future<void> _dial() async {
    _retry?.cancel();
    await _teardownPc();
    setState(() => _status = 'Connecting…');
    try {
      final pc = await createPeerConnection(kRtcConfig);
      _pc = pc;
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remote.srcObject = event.streams[0];
          _audioTrack = event.streams[0]
              .getAudioTracks()
              .cast<MediaStreamTrack?>()
              .firstWhere((_) => true, orElse: () => null);
          _applyMute();
          if (mounted) setState(() {});
        }
      };
      pc.onConnectionState = (s) {
        if (!mounted) return;
        setState(() => _status = _label(s));
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _backoff = 1;
        } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _scheduleReconnect();
        }
      };

      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final gathered = waitForIceComplete(pc);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await gathered;

      final answer =
          await postOffer(_host, kSignalPort, (await pc.getLocalDescription())!);
      await pc.setRemoteDescription(answer);

      // Native plays remote audio without a user gesture (the browser autoplay
      // rule doesn't apply here) — route it to the loudspeaker.
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
      await WakelockPlus.enable();
    } catch (e) {
      setState(() => _status = 'Failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !_watching) return;
    _retry?.cancel();
    final wait = _backoff;
    _backoff = (_backoff * 2).clamp(1, 30);
    _retry = Timer(Duration(seconds: wait), () {
      if (!_disposed && _watching) _dial();
    });
    if (mounted) setState(() => _status = 'Reconnecting in ${wait}s…');
  }

  void _applyMute() => _audioTrack?.enabled = !_muted;

  String get _host => _addr.text.trim();

  String _label(RTCPeerConnectionState s) => switch (s) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'Live',
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'Connecting…',
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'Disconnected',
        RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'Connection failed',
        RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'Closed',
        _ => 'New',
      };

  Future<void> _teardownPc() async {
    await _pc?.close();
    _pc = null;
    _audioTrack = null;
    _remote.srcObject = null;
  }

  Future<void> _stop() async {
    _watching = false;
    _retry?.cancel();
    await _teardownPc();
    await WakelockPlus.disable();
    if (mounted) setState(() => _status = 'Stopped');
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _teardownPc();
    _remote.dispose();
    _addr.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasVideo = _remote.srcObject != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: hasVideo
                  ? RTCVideoView(_remote,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                  : Center(
                      child: Text(_status.isEmpty ? 'Not connected' : _status,
                          style: const TextStyle(color: Colors.white70)),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TextField(
                    controller: _addr,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Camera address (LAN IP or Tailscale name)',
                      labelStyle: TextStyle(color: Colors.white70),
                      hintText: 'e.g. 192.168.1.50',
                      hintStyle: TextStyle(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _watching ? _stop : _connect,
                          icon: Icon(_watching ? Icons.stop : Icons.play_arrow),
                          label: Text(_watching ? 'Stop' : 'Connect'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: hasVideo
                            ? () => setState(() {
                                  _muted = !_muted;
                                  _applyMute();
                                })
                            : null,
                        icon: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                            color: Colors.white),
                      ),
                    ],
                  ),
                  if (_watching && _status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('$_status  ·  $_host',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
