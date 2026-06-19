import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Fixed port for the camera's embedded signaling server. The viewer dials
/// `http://<camera-address>:$kSignalPort/offer`.
const int kSignalPort = 8080;

/// Empty iceServers: LAN-only. Native libwebrtc gathers real host candidates and
/// connects directly on the same WiFi — no STUN/TURN, no third-party servers
/// contacted at all. (For cross-network use you'd add STUN/TURN or a relay here.)
const Map<String, dynamic> kRtcConfig = {
  'iceServers': <Map<String, dynamic>>[],
};

/// Builds an SDP answer for a received offer (camera side supplies this).
typedef AnswerBuilder = Future<RTCSessionDescription> Function(
    RTCSessionDescription offer);

/// Camera-side embedded signaling: a tiny `dart:io` HTTP server. The viewer
/// POSTs an SDP offer to `/offer`; we hand it to [onOffer] and return its SDP
/// answer. One request, one response — non-trickle, stateless, `curl`-able.
class CameraSignalingServer {
  CameraSignalingServer(this.onOffer);

  final AnswerBuilder onOffer;
  HttpServer? _server;

  Future<void> start({int port = kSignalPort}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.method == 'POST' && req.uri.path == '/offer') {
        final body = await utf8.decoder.bind(req).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final offer =
            RTCSessionDescription(json['sdp'] as String, json['type'] as String);
        final answer = await onOffer(offer);
        res
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'sdp': answer.sdp, 'type': answer.type}));
      } else if (req.method == 'GET' && req.uri.path == '/health') {
        res
          ..statusCode = HttpStatus.ok
          ..write('ok');
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      res
        ..statusCode = HttpStatus.internalServerError
        ..write('$e');
    } finally {
      await res.close();
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

/// Viewer-side: POST [offer] to the camera and return its SDP answer.
Future<RTCSessionDescription> postOffer(
  String host,
  int port,
  RTCSessionDescription offer,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .postUrl(Uri(scheme: 'http', host: host, port: port, path: '/offer'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'sdp': offer.sdp, 'type': offer.type}));
    final resp = await req.close();
    final body = await utf8.decoder.bind(resp).join();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('camera returned ${resp.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    return RTCSessionDescription(json['sdp'] as String, json['type'] as String);
  } finally {
    client.close(force: true);
  }
}

/// Non-loopback IPv4 addresses this device is reachable at — LAN (192.168.x /
/// 10.x) and, if the tun interface is visible, the Tailscale 100.x. Shown on the
/// camera for pairing so the parent knows what to type into the viewer.
Future<List<String>> localAddresses() async {
  final out = <String>[];
  for (final iface
      in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final addr in iface.addresses) {
      if (!addr.isLoopback) out.add(addr.address);
    }
  }
  return out;
}
