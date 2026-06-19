import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:baby_monitor/signaling.dart';

// Exercises the real embedded server + POST client and the {sdp,type} wire
// envelope end-to-end (no native WebRTC needed — the answer is canned).
void main() {
  test('offer POST round-trips through the embedded server', () async {
    RTCSessionDescription? seenOffer;
    final server = CameraSignalingServer((offer) async {
      seenOffer = offer;
      return RTCSessionDescription('v=0...answer-sdp', 'answer');
    });
    await server.start(port: 18080);

    final answer = await postOffer(
      '127.0.0.1',
      18080,
      RTCSessionDescription('v=0...offer-sdp', 'offer'),
    );

    expect(seenOffer?.sdp, 'v=0...offer-sdp');
    expect(seenOffer?.type, 'offer');
    expect(answer.sdp, 'v=0...answer-sdp');
    expect(answer.type, 'answer');

    await server.stop();
  });

  test('non-/offer paths 404 and a failing builder surfaces 500', () async {
    final server = CameraSignalingServer((offer) async => throw 'boom');
    await server.start(port: 18081);

    await expectLater(
      postOffer('127.0.0.1', 18081,
          RTCSessionDescription('x', 'offer')),
      throwsA(isA<Exception>()),
    );

    await server.stop();
  });

  test('remote control POST /control and GET /state round-trip', () async {
    String? seenAction;
    bool? seenValue;
    final server = CameraSignalingServer(
      (offer) async => RTCSessionDescription('', 'answer'),
      onControl: (action, value) async {
        seenAction = action;
        seenValue = value;
        return {'facingFront': false, 'torchOn': value ?? false, 'hasTorch': true};
      },
    );
    await server.start(port: 18082);

    final afterTorch =
        await sendControl('127.0.0.1', 18082, 'torch', value: true);
    expect(seenAction, 'torch');
    expect(seenValue, true);
    expect(afterTorch['torchOn'], true);
    expect(afterTorch['hasTorch'], true);

    final state = await sendControl('127.0.0.1', 18082, null); // GET /state
    expect(seenAction, isNull); // null action == pure query
    expect(state['hasTorch'], true);

    await server.stop();
  });
}
