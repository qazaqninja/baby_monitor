import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ice.dart';
import 'signaling.dart';
import 'theme.dart';
import 'widgets.dart';

/// Viewer (monitor) role: connect to the camera, render its stream, and talk
/// back to the baby via push-to-talk. Auto-reconnects (a WiFi blip otherwise
/// kills it forever).
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final _remote = RTCVideoRenderer();
  final _addr = TextEditingController();
  RTCPeerConnection? _pc;
  MediaStream? _localStream; // our mic, for talk-back
  MediaStreamTrack? _micTrack;
  MediaStreamTrack? _audioTrack; // incoming camera audio
  Timer? _retry;
  bool _disposed = false;
  bool _watching = false; // user pressed Connect (controls auto-reconnect)
  bool _muted = false;
  bool _talking = false;
  bool _micAvailable = false;
  // Remote camera state, reported by the camera over /control and /state.
  bool _camFacingFront = false;
  bool _camTorchOn = false;
  bool _camHasTorch = false;
  int _backoff = 1;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _remote.initialize();
    // Ask for the mic up front so talk-back's mic track is ready before the
    // first offer (it can't be added after, with one-shot signaling).
    Permission.microphone.request();
    final prefs = await SharedPreferences.getInstance();
    _addr.text = prefs.getString('camera_addr') ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final host = _addr.text.trim();
    if (host.isEmpty) return;
    (await SharedPreferences.getInstance()).setString('camera_addr', host);
    setState(() => _watching = true);
    await _dial();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
    if (code == null || code.trim().isEmpty) return;
    _addr.text = code.trim();
    await _connect();
  }

  // Acquire the mic once (for talk-back) and keep it across reconnects. Starts
  // disabled — push-to-talk enables it only while the button is held.
  Future<MediaStreamTrack?> _ensureMic() async {
    if (_micTrack != null) return _micTrack;
    final status = await Permission.microphone.request();
    if (!status.isGranted) return null;
    try {
      _localStream = await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});
      _micTrack = _localStream!.getAudioTracks().first;
      _micTrack!.enabled = false;
      _micAvailable = true;
      return _micTrack;
    } catch (e) {
      debugPrint('[VIEW] mic error: $e');
      return null;
    }
  }

  Future<void> _dial() async {
    _retry?.cancel();
    await _teardownPc();
    // Never come up hot-miked after a reconnect.
    _talking = false;
    _micTrack?.enabled = false;
    if (mounted) setState(() => _status = 'Connecting…');
    try {
      final mic = await _ensureMic();
      final pc = await createPeerConnection(kRtcConfig);
      if (_disposed) {
        await pc.close();
        await pc.dispose();
        return;
      }
      _pc = pc;
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remote.srcObject = event.streams[0];
          final audio = event.streams[0].getAudioTracks();
          _audioTrack = audio.isEmpty ? null : audio.first;
          _applyMute();
          if (mounted) setState(() {});
        }
      };
      pc.onConnectionState = (s) {
        if (!mounted) return;
        setState(() => _status = _label(s));
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _backoff = 1;
          _fetchCamState(); // populate remote camera-control buttons
        } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _scheduleReconnect();
        }
      };

      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      // Audio is sendrecv when we have a mic (receive baby + send talk-back),
      // recv-only otherwise.
      if (mic != null) {
        await pc.addTransceiver(
          track: mic,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
        );
      } else {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }

      final gathered = waitForIceComplete(pc);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await gathered;

      final answer =
          await postOffer(_host, kSignalPort, (await pc.getLocalDescription())!);
      await pc.setRemoteDescription(answer);

      // Native plays remote audio without a user gesture — route to loudspeaker.
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

  void _applyMute() => _audioTrack?.enabled = !_muted && !_talking;

  // Push-to-talk: enable our mic and duck the incoming audio (half-duplex)
  // while held — prevents the parent hearing their own echo from the camera.
  Future<void> _setTalking(bool on) async {
    if (on && !_micAvailable) {
      // Mic not granted at connect time. Acquire it now, then reconnect so it
      // makes it into the offer (one-shot signaling can't add it live).
      final mic = await _ensureMic();
      if (mic == null) {
        _snack('Allow microphone access to talk to your baby');
        return;
      }
      await _dial();
      _snack('Microphone ready — hold the button to talk');
      return;
    }
    if (!_micAvailable) return; // release with no mic: nothing to do
    _talking = on;
    _micTrack?.enabled = on;
    _applyMute();
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _applyMute();
  }

  // ---- Remote camera control (drives the camera over HTTP) ----
  void _applyCamState(Map<String, dynamic> st) {
    _camFacingFront = st['facingFront'] == true;
    _camTorchOn = st['torchOn'] == true;
    _camHasTorch = st['hasTorch'] == true;
    if (mounted) setState(() {});
  }

  Future<void> _fetchCamState() async {
    try {
      _applyCamState(await sendControl(_host, kSignalPort, null));
    } catch (e) {
      debugPrint('[VIEW] state fetch failed: $e');
    }
  }

  Future<void> _remoteSwitchCamera() async {
    try {
      _applyCamState(await sendControl(_host, kSignalPort, 'switchCamera'));
    } catch (e) {
      _snack('Could not switch the camera');
    }
  }

  Future<void> _remoteTorch() async {
    try {
      _applyCamState(
          await sendControl(_host, kSignalPort, 'torch', value: !_camTorchOn));
    } catch (e) {
      _snack('Could not toggle the light');
    }
  }

  String get _host => _addr.text.trim();

  String _label(RTCPeerConnectionState s) => switch (s) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'Live',
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'Connecting…',
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          'Disconnected',
        RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          'Connection failed',
        RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'Closed',
        _ => 'New',
      };

  Future<void> _teardownPc() async {
    final pc = _pc;
    _pc = null;
    _audioTrack = null;
    _remote.srcObject = null;
    // close() then dispose() — close alone leaks the native PC + event channel,
    // which matters because we auto-reconnect on every WiFi blip.
    await pc?.close();
    await pc?.dispose();
  }

  Future<void> _stop() async {
    setState(() => _watching = false);
    _retry?.cancel();
    _talking = false;
    _micTrack?.enabled = false; // never leave the mic hot after stopping
    await _teardownPc();
    await WakelockPlus.disable();
    if (mounted) setState(() => _status = '');
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _teardownPc();
    _remote.dispose();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _addr.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _watching ? Colors.black : warmCream,
      body: _watching ? _liveView() : _setupView(),
    );
  }

  // ---- Setup (pre-connect): warm, friendly pairing screen ----
  Widget _setupView() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: const BoxDecoration(gradient: warmBackdrop),
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: warmBrown),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: warmSeed.withValues(alpha: 0.25),
                              blurRadius: 22,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(Icons.monitor_heart_rounded,
                            size: 48, color: scheme.primary),
                      ),
                      const SizedBox(height: 18),
                      const Text('Connect to camera',
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: warmBrown)),
                      const SizedBox(height: 6),
                      Text('Scan the QR shown on the camera phone',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14,
                              color: warmBrown.withValues(alpha: 0.7))),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _scan,
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('Scan QR on camera'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(children: [
                        Expanded(
                            child: Divider(
                                color: warmBrown.withValues(alpha: 0.2))),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or',
                              style: TextStyle(
                                  color: warmBrown.withValues(alpha: 0.5))),
                        ),
                        Expanded(
                            child: Divider(
                                color: warmBrown.withValues(alpha: 0.2))),
                      ]),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _addr,
                        style: const TextStyle(color: warmBrown),
                        decoration: InputDecoration(
                          labelText: 'Camera address',
                          hintText: 'e.g. 192.168.1.50',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _connect,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Connect'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Live (connected): full-bleed video + talk/mute/stop controls ----
  Widget _liveView() {
    final hasVideo = _remote.srcObject != null;
    final connected = _status == 'Live';
    return Stack(
      children: [
        Positioned.fill(
          child: hasVideo
              ? RTCVideoView(_remote,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: warmSeed)),
                      const SizedBox(height: 16),
                      Text(_status.isEmpty ? 'Connecting…' : _status,
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: StatusPill(
                text: '${connected ? "Live" : _status}  ·  $_host',
                color: connected ? const Color(0xFF7DD181) : warmSeed,
              ),
            ),
          ),
        ),
        if (_talking)
          const SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: 14),
                child: StatusPill(text: 'Talking…', color: Color(0xFFE6896B)),
              ),
            ),
          ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Remote camera controls — drive the camera phone from here.
                  if (connected)
                    ControlBar(
                      children: [
                        LiveControlButton(
                          icon: Icons.cameraswitch_rounded,
                          label: _camFacingFront ? 'Front cam' : 'Back cam',
                          onTap: _remoteSwitchCamera,
                        ),
                        LiveControlButton(
                          icon: _camTorchOn
                              ? Icons.flashlight_on_rounded
                              : Icons.flashlight_off_rounded,
                          label: 'Light',
                          active: _camTorchOn,
                          enabled: _camHasTorch,
                          onTap: _remoteTorch,
                        ),
                      ],
                    ),
                  if (connected) const SizedBox(height: 12),
                  ControlBar(
                    children: [
                      LiveControlButton(
                        icon: _muted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        label: _muted ? 'Muted' : 'Sound',
                        active: _muted,
                        enabled: hasVideo,
                        onTap: _toggleMute,
                      ),
                      LiveControlButton(
                        icon: Icons.mic_rounded,
                        label: _talking ? 'Talking' : 'Hold to talk',
                        active: _talking,
                        enabled: connected,
                        big: true,
                        onPressStart: () => _setTalking(true),
                        onPressEnd: () => _setTalking(false),
                      ),
                      LiveControlButton(
                        icon: Icons.stop_rounded,
                        label: 'Stop',
                        onTap: _stop,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen QR scanner. Pops back with the decoded string (the camera's
/// host address) on the first barcode it sees.
class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan camera QR'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              final code = capture.barcodes
                  .map((b) => b.rawValue)
                  .firstWhere((v) => v != null && v.isNotEmpty,
                      orElse: () => null);
              if (code == null) return;
              _handled = true;
              Navigator.of(context).pop(code);
            },
          ),
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: warmSeed, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const Positioned(
            bottom: 80,
            child: Text(
              'Point at the QR on the camera phone',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
