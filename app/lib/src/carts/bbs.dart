// SPDX-License-Identifier: GPL-3.0-or-later
// Lexaloffle BBS listing client and parser.
// Spec: docs/specs/pico8-cart-browser.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const bbsHost = 'https://www.lexaloffle.com';

/// One cart post on the BBS.
class BbsCart {
  const BbsCart({
    required this.postId,
    required this.threadId,
    required this.title,
    required this.author,
    required this.authorId,
    required this.cartId,
    required this.thumbPath,
    required this.updated,
  });

  final String postId;
  final int threadId;
  final String title;
  final String author;
  final int authorId;

  /// From the thumb file name; null when it can't be derived (no download then).
  final String? cartId;

  final String thumbPath; // e.g. /bbs/thumbs/pico8_foo-3.png
  final String updated; // e.g. 2026-10-09 13:46:47

  Uri get threadUrl => Uri.parse('$bbsHost/bbs/?tid=$threadId');
  Uri get thumbUrl => Uri.parse('$bbsHost$thumbPath');
  Uri? get cartUrl => cartId == null ? null : bbsCartUrl(cartId!);

  @override
  bool operator ==(Object other) => other is BbsCart && other.postId == postId;

  @override
  int get hashCode => postId.hashCode;
}

/// A listing request: one of the four BBS tabs.
sealed class BbsQuery {
  const BbsQuery();
}

/// Featured carts, newest first.
class FeaturedCarts extends BbsQuery {
  const FeaturedCarts();

  @override
  bool operator ==(Object other) => other is FeaturedCarts;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Most recently posted carts.
class NewCarts extends BbsQuery {
  const NewCarts();

  @override
  bool operator ==(Object other) => other is NewCarts;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// A title/author search.
class SearchCarts extends BbsQuery {
  const SearchCarts(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is SearchCarts && other.text == text;

  @override
  int get hashCode => Object.hash(SearchCarts, text);
}

/// Carts posted by one author.
class AuthorCarts extends BbsQuery {
  const AuthorCarts(this.authorId, this.author);

  final int authorId;
  final String author;

  @override
  bool operator ==(Object other) =>
      other is AuthorCarts &&
      other.authorId == authorId &&
      other.author == author;

  @override
  int get hashCode => Object.hash(AuthorCarts, authorId, author);
}

/// One page of a listing.
class BbsPage {
  const BbsPage(this.carts, {required this.hasMore});

  final List<BbsCart> carts;
  final bool hasMore;
}

/// A short, user-facing BBS failure.
class BbsException implements Exception {
  const BbsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Listing URL for [query], [page] starting at 1 (see the spec table).
///
/// Query parameters are emitted in the BBS's order: `cat`, `sub`, the
/// query-specific key, then `page`.
Uri bbsListingUrl(BbsQuery query, {int page = 1}) {
  final params = <String, String>{'cat': '7', 'sub': '2'};
  switch (query) {
    case FeaturedCarts():
      params['orderby'] = 'featured';
    case NewCarts():
      params['orderby'] = 'ts';
    case SearchCarts(:final text):
      params['search'] = text;
    case AuthorCarts(:final authorId):
      params['uid'] = '$authorId';
      params['mode'] = 'carts';
  }
  params['page'] = '$page';
  return Uri.parse('$bbsHost/bbs/').replace(queryParameters: params);
}

/// Cart file URL per spec: a string id goes under its first two characters,
/// an all-digit id `n` under `n ~/ 10000`.
Uri bbsCartUrl(String cartId) {
  final n = int.tryParse(cartId);
  if (n != null) {
    return Uri.parse('$bbsHost/bbs/cposts/${n ~/ 10000}/$n.p8.png');
  }
  final head = cartId.substring(0, cartId.length < 2 ? cartId.length : 2);
  return Uri.parse('$bbsHost/bbs/cposts/$head/$cartId.p8.png');
}

/// Cart id from a thumb path: basename, strip leading `pico8_` and trailing
/// `.png`; null if the basename doesn't match `pico8_<id>.png`.
String? cartIdFromThumb(String thumbPath) {
  final base = thumbPath.split('/').last;
  final match = RegExp(r'^pico8_(.+)\.png$').firstMatch(base);
  return match?[1];
}

/// Decodes `&amp;` `&lt;` `&gt;` `&quot;` `&#39;` and numeric `&#NN;` entities.
String decodeEntities(String s) => s.replaceAllMapped(
  RegExp(r'&(#\d+|amp|lt|gt|quot);'),
  (match) => switch (match[1]) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    final numeric => String.fromCharCode(int.parse(numeric!.substring(1))),
  },
);

/// Matches one listing row, capturing the fields the browser uses. Thumb
/// sizes may be fractional (author pages).
///
/// Groups: 1 post id, 2 thread id, 3 title, 4 thumb path, 5 created,
/// 6 author id, 7 author name, 8 updated.
final _rowPattern = RegExp(
  r'^\s*\[\x27([^\x27]*)\x27,\s*(\d+),\s*`((?:[^`\\]|\\.)*)`\s*,\s*'
  r'"((?:[^"\\]|\\.)*)"\s*,\s*[\d.]+\s*,\s*[\d.]+\s*,\s*'
  r'"((?:[^"\\]|\\.)*)"\s*,\s*(\d+)\s*,\s*'
  r'"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"',
);

/// Removes backslash escapes from a listing string field.
String _unescape(String s) =>
    s.replaceAllMapped(RegExp(r'\\(.)'), (match) => match[1]!);

/// Parses every row of the listing script array; bad rows are skipped.
List<BbsCart> parseBbsListing(String html) {
  final carts = <BbsCart>[];
  for (final line in const LineSplitter().convert(html)) {
    final match = _rowPattern.firstMatch(line);
    if (match == null) continue;
    final thumbPath = match[4]!;
    carts.add(
      BbsCart(
        postId: match[1]!,
        threadId: int.parse(match[2]!),
        title: decodeEntities(_unescape(match[3]!)),
        author: decodeEntities(_unescape(match[7]!)),
        authorId: int.parse(match[6]!),
        cartId: cartIdFromThumb(thumbPath),
        thumbPath: thumbPath,
        updated: match[8]!,
      ),
    );
  }
  return carts;
}

const bbsPageSize = 30;

/// Reads BBS listings, carts and thumbnails. Tests inject a fake fetch.
abstract interface class BbsClient {
  /// One page of [query]; throws [BbsException].
  Future<BbsPage> list(BbsQuery query, {int page = 1});

  /// The cart's `.p8.png` bytes; throws [BbsException] (also when [BbsCart.cartId]
  /// is null or the bytes don't start with the PNG signature).
  Future<Uint8List> download(BbsCart cart);

  /// Thumbnail bytes or null on any failure (never throws).
  Future<Uint8List?> thumbnail(BbsCart cart);
}

/// Fetches bytes for a URL. Returns null on a non-200 status. Throws on
/// network errors.
typedef BbsFetch = Future<Uint8List?> Function(Uri url);

/// [BbsClient] over `HttpClient`; a fake [fetch] can replace the network.
class HttpBbsClient implements BbsClient {
  HttpBbsClient({BbsFetch? fetch}) : _fetch = fetch ?? _httpGet;

  final BbsFetch _fetch;
  final _thumbCache = <String, Uint8List?>{};

  @override
  Future<BbsPage> list(BbsQuery query, {int page = 1}) async {
    final Uint8List? bytes;
    try {
      bytes = await _fetch(bbsListingUrl(query, page: page));
    } on Object {
      throw const BbsException('No connection to the BBS.');
    }
    if (bytes == null) {
      throw const BbsException('The BBS did not answer. Try again later.');
    }
    final carts = parseBbsListing(utf8.decode(bytes, allowMalformed: true));
    return BbsPage(carts, hasMore: carts.length >= bbsPageSize);
  }

  @override
  Future<Uint8List> download(BbsCart cart) async {
    final url = cart.cartUrl;
    if (url == null) {
      throw const BbsException('That cart could not be downloaded.');
    }
    final Uint8List? bytes;
    try {
      bytes = await _fetch(url);
    } on Object {
      throw const BbsException('No connection to the BBS.');
    }
    if (bytes == null) {
      throw const BbsException('The BBS did not answer. Try again later.');
    }
    if (!_isPng(bytes)) {
      throw const BbsException('That cart could not be downloaded.');
    }
    return bytes;
  }

  @override
  Future<Uint8List?> thumbnail(BbsCart cart) async {
    if (_thumbCache.containsKey(cart.postId)) {
      return _thumbCache[cart.postId];
    }
    Uint8List? bytes;
    try {
      bytes = await _fetch(cart.thumbUrl);
    } on Object {
      bytes = null;
    }
    return _thumbCache[cart.postId] = bytes;
  }
}

/// The PNG magic number: `0x89` `P` `N` `G`.
bool _isPng(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

/// `HttpClient` GET with a 10 s connection timeout; null when not 200.
Future<Uint8List?> _httpGet(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'Dena.emu');
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}
