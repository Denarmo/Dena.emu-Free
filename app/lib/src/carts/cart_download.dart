// SPDX-License-Identifier: GPL-3.0-or-later
// One-tap cart download into the library, with the author's credit.
// Spec: docs/specs/pico8-cart-browser.md (Download)
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart';
import '../library/importer.dart';
import 'bbs.dart';

/// Who made a downloaded cart and where it came from.
class CartCredit {
  const CartCredit({
    required this.postId,
    required this.threadId,
    required this.title,
    required this.author,
    required this.authorId,
    this.cartId,
  });

  factory CartCredit.of(BbsCart cart) => CartCredit(
    postId: cart.postId,
    threadId: cart.threadId,
    title: cart.title,
    author: cart.author,
    authorId: cart.authorId,
    cartId: cart.cartId,
  );

  factory CartCredit.fromJson(Map<String, Object?> json) => CartCredit(
    postId: json['postId'] as String,
    threadId: json['threadId'] as int,
    title: json['title'] as String,
    author: json['author'] as String,
    authorId: json['authorId'] as int,
    cartId: json['cartId'] as String?,
  );

  final String postId, title, author;
  final int threadId, authorId;
  final String? cartId;

  Map<String, Object?> toJson() => {
    'postId': postId,
    'threadId': threadId,
    'title': title,
    'author': author,
    'authorId': authorId,
    'cartId': cartId,
  };
}

/// Credits of downloaded carts by SHA-1, kept in `<dataDir>/carts/credits.json`.
class CartCredits {
  CartCredits(String dataDir)
    : file = File(p.join(dataDir, 'carts', 'credits.json'));

  final File file;
  Map<String, CartCredit>? _bySha1;

  Future<Map<String, CartCredit>> load() async {
    if (_bySha1 case final loaded?) return loaded;
    var map = <String, CartCredit>{};
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      map = {
        for (final e in json.entries)
          e.key as String: CartCredit.fromJson(
            (e.value as Map).cast<String, Object?>(),
          ),
      };
    } on Object {
      // Missing or unreadable: start empty.
    }
    return _bySha1 = map;
  }

  /// The SHA-1 of the file downloaded from post [postId], if any.
  Future<String?> sha1ForPost(String postId) async {
    for (final e in (await load()).entries) {
      if (e.value.postId == postId) return e.key;
    }
    return null;
  }

  Future<void> put(String sha1, CartCredit credit) async {
    final map = await load();
    map[sha1] = credit;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({for (final e in map.entries) e.key: e.value.toJson()}),
    );
  }
}

/// What a download did.
enum DownloadResult { added, alreadyInLibrary }

/// Downloads [cart] and imports it like a picked `.p8.png` file. Throws
/// [BbsException] when the download or import fails.
Future<DownloadResult> downloadCart({
  required BbsClient client,
  required BbsCart cart,
  required Importer importer,
  required CartCredits credits,
}) async {
  final bytes = await client.download(cart);
  final tmp = await Directory.systemTemp.createTemp('dena_cart');
  try {
    final file = File(p.join(tmp.path, '${cartFileStem(cart.title)}.p8.png'));
    await file.writeAsBytes(bytes);
    final outcome = await importer.importOne(file);
    final sha1Hex = sha1.convert(bytes).toString();
    switch (outcome) {
      case Imported():
        await credits.put(sha1Hex, CartCredit.of(cart));
        return DownloadResult.added;
      case Duplicate():
        await credits.put(sha1Hex, CartCredit.of(cart));
        return DownloadResult.alreadyInLibrary;
      case Rejected():
        throw const BbsException('That cart could not be added.');
    }
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// A file name from a cart title: letters, digits, spaces, `-` and `_` only.
String cartFileStem(String title) {
  final s = title.replaceAll(RegExp(r'[^A-Za-z0-9 _\-]'), '').trim();
  return s.isEmpty ? 'cart' : s;
}

/// Whether the cart from post [postId] is still in [db].
Future<bool> cartInLibrary(
  LibraryDatabase db,
  CartCredits credits,
  String postId,
) async {
  final sha1 = await credits.sha1ForPost(postId);
  return sha1 != null && await db.gameBySha1(sha1) != null;
}
