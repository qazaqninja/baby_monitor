import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Wait until ICE gathering finishes, so we can ship ONE complete SDP
/// (non-trickle signaling — see [signaling.dart]).
///
/// Register the handlers BEFORE calling setLocalDescription, then await:
/// ```
/// final gathered = waitForIceComplete(pc);
/// await pc.setLocalDescription(desc);
/// await gathered;
/// final local = await pc.getLocalDescription();
/// ```
///
/// flutter_webrtc #1699: RTCIceGatheringStateComplete never fires on some
/// Android devices, and the null end-of-candidates sentinel is not always
/// delivered either. So resolve on whichever happens first: gathering-state
/// complete, an empty/null candidate, or a timeout backstop.
Future<void> waitForIceComplete(
  RTCPeerConnection pc, {
  Duration timeout = const Duration(seconds: 3),
}) {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  pc.onIceGatheringState = (state) {
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) finish();
  };
  pc.onIceCandidate = (candidate) {
    final c = candidate.candidate;
    if (c == null || c.isEmpty) finish(); // end-of-candidates sentinel
  };
  Timer(timeout, finish);

  return done.future;
}
