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

/// Runs a remote-control [action] (e.g. 'switchCamera', 'torch') on the camera
/// and returns its current state ({facingFront, torchOn, hasTorch}). A null
/// action just queries state. Camera side supplies this.
typedef ControlHandler = Future<Map<String, dynamic>> Function(
    String? action, bool? value);

/// Camera-side embedded signaling: a tiny `dart:io` HTTP server. The viewer
/// POSTs an SDP offer to `/offer`; we hand it to [onOffer] and return its SDP
/// answer. One request, one response — non-trickle, stateless, `curl`-able.
class CameraSignalingServer {
  CameraSignalingServer(this.onOffer, {this.onControl});

  final AnswerBuilder onOffer;
  final ControlHandler? onControl;
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
      } else if (req.method == 'POST' &&
          req.uri.path == '/control' &&
          onControl != null) {
        final body = await utf8.decoder.bind(req).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final state =
            await onControl!(json['action'] as String?, json['value'] as bool?);
        res
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(state));
      } else if (req.method == 'GET' &&
          req.uri.path == '/state' &&
          onControl != null) {
        final state = await onControl!(null, null);
        res
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(state));
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

/// Viewer-side: send a remote-control [action] to the camera (POST /control)
/// and return its reported state, or just query state (GET /state) when
/// [action] is null. Short timeout so it never hangs the UI.
Future<Map<String, dynamic>> sendControl(
  String host,
  int port,
  String? action, {
  bool? value,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final HttpClientRequest req;
    if (action == null) {
      req = await client
          .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/state'));
    } else {
      req = await client.postUrl(
          Uri(scheme: 'http', host: host, port: port, path: '/control'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'action': action, 'value': value}));
    }
    final resp = await req.close();
    final body = await utf8.decoder.bind(resp).join();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('camera returned ${resp.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

/// The WiFi LAN address(es) this device is reachable at, best first. The camera
/// shows this for pairing, so it must NOT surface cellular (carrier 10.x),
/// 464XLAT (192.0.0.x), or link-local (169.254.x) noise — those confuse the
/// parent into typing an address the viewer can't reach. Strategy: prefer the
/// WiFi interface (en0/wlan0) and the 192.168.x range; only fall back to other
/// private ranges if nothing better exists.
Future<List<String>> localAddresses() async {
  final seen = <String>{};
  final entries = <(String, String)>[]; // (interfaceName, ip)
  for (final iface
      in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final addr in iface.addresses) {
      final ip = addr.address;
      if (addr.isLoopback ||
          ip.startsWith('169.254.') || // link-local
          ip.startsWith('192.0.0.')) {
        continue; // 464XLAT/cellular clat
      }
      if (seen.add(ip)) entries.add((iface.name, ip));
    }
  }

  bool isWifi(String name) {
    final n = name.toLowerCase();
    return n.startsWith('en') || n.contains('wlan') || n.contains('wifi');
  }

  int rank((String, String) e) {
    final (name, ip) = e;
    final wifi = isWifi(name);
    if (ip.startsWith('192.168.')) return wifi ? 0 : 1; // home WiFi LAN
    if (wifi) return 2;
    if (_isPrivateLan(ip)) return 3; // other private (could be cellular 10.x)
    return 4;
  }

  entries.sort((a, b) => rank(a).compareTo(rank(b)));
  // If we found a genuine WiFi/192.168 address, show only those — hide the rest.
  final best = entries.where((e) => rank(e) <= 1).map((e) => e.$2).toList();
  return best.isNotEmpty ? best : entries.map((e) => e.$2).toList();
}

bool _isPrivateLan(String ip) {
  if (ip.startsWith('192.168.') || ip.startsWith('10.')) return true;
  if (ip.startsWith('172.')) {
    final second = int.tryParse(ip.split('.')[1]) ?? 0;
    return second >= 16 && second <= 31;
  }
  return false;
}
