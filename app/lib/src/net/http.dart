// SPDX-License-Identifier: GPL-3.0-or-later
// Small HTTP helpers shared by the online clients (RomM).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class HttpReply {
  const HttpReply(this.status, this.body, [this.headers = const {}]);

  final int status;
  final Uint8List body;

  /// Lower-cased header names.
  final Map<String, String> headers;

  String get text => utf8.decode(body, allowMalformed: true);
  Object? get json => jsonDecode(text);
}

/// One buffered HTTP request; a fake server replaces it in tests.
typedef HttpSend = Future<HttpReply> Function(
  String method,
  Uri url,
  Map<String, String> headers, [
  List<int>? body,
]);

/// A reply whose body arrives as a stream (game downloads).
class HttpStreamReply {
  const HttpStreamReply(this.status, this.body, [this.headers = const {}]);

  final int status;
  final Stream<List<int>> body;
  final Map<String, String> headers;

  Future<HttpReply> buffer() async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in body) {
      b.add(chunk);
    }
    return HttpReply(status, b.takeBytes(), headers);
  }
}

/// One HTTP request with a streamed body each way. [length] is the body's
/// size when known.
typedef HttpStreamSend = Future<HttpStreamReply> Function(
  String method,
  Uri url,
  Map<String, String> headers,
  Stream<List<int>>? body,
  int? length,
);

/// Streams over a buffered [HttpSend] (tests).
HttpStreamSend streamOver(HttpSend send) =>
    (method, url, headers, body, length) async {
      List<int>? bytes;
      if (body != null) {
        final b = BytesBuilder(copy: false);
        await for (final chunk in body) {
          b.add(chunk);
        }
        bytes = b.takeBytes();
      }
      final r = await send(method, url, headers, bytes);
      return HttpStreamReply(r.status, Stream.value(r.body), r.headers);
    };

/// One shared client, so connections (and their TLS handshakes) are reused
/// across many small requests.
final _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..maxConnectionsPerHost = 8;

/// [HttpStreamSend] over `dart:io`, with a connection timeout and an idle
/// timeout on each chunk (a long transfer is fine while data flows).
Future<HttpStreamReply> ioHttpStreamSend(
  String method,
  Uri url,
  Map<String, String> headers,
  Stream<List<int>>? body,
  int? length,
) async {
  final req = await _client.openUrl(method, url);
  headers.forEach(req.headers.set);
  if (body != null) {
    if (length != null) req.contentLength = length;
    await req.addStream(body.timeout(const Duration(minutes: 1)));
  } else if (method != 'GET' && method != 'DELETE') {
    req.contentLength = 0;
  }
  final res = await req.close().timeout(const Duration(minutes: 2));
  final out = <String, String>{};
  res.headers.forEach((k, v) => out[k.toLowerCase()] = v.join(','));
  return HttpStreamReply(
    res.statusCode,
    res.timeout(const Duration(minutes: 1)),
    out,
  );
}
