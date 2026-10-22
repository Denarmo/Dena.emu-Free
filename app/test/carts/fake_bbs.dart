// A BbsClient backed by the synthetic listing fixture; never touches the
// network. Spec: docs/specs/pico8-cart-browser.md (Acceptance tests)
import 'dart:io';
import 'dart:typed_data';

import 'package:dena_emu/src/carts/bbs.dart';

/// The fixture's carts (our own invented entries).
List<BbsCart> fixtureCarts() => parseBbsListing(
  File('test/carts/fixtures/listing.html').readAsStringSync(),
);

class FakeBbsClient implements BbsClient {
  FakeBbsClient({List<BbsCart>? carts}) : carts = carts ?? fixtureCarts();

  final List<BbsCart> carts;

  /// When set, every list call fails with this message.
  String? failWith;
  final requests = <(BbsQuery, int)>[];
  final downloads = <String>[];

  @override
  Future<BbsPage> list(BbsQuery query, {int page = 1}) async {
    requests.add((query, page));
    if (failWith case final message?) throw BbsException(message);
    final result = switch (query) {
      FeaturedCarts() => carts,
      NewCarts() => carts.reversed.toList(),
      SearchCarts(:final text) =>
        carts
            .where((c) => c.title.toLowerCase().contains(text.toLowerCase()))
            .toList(),
      AuthorCarts(:final authorId) =>
        carts.where((c) => c.authorId == authorId).toList(),
    };
    return BbsPage(page == 1 ? result : const [], hasMore: false);
  }

  @override
  Future<Uint8List> download(BbsCart cart) async {
    if (cart.cartId == null) {
      throw const BbsException('That cart could not be downloaded.');
    }
    downloads.add(cart.postId);
    // A PNG signature followed by the post id, so each cart hashes differently.
    return Uint8List.fromList([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
      ...cart.postId.codeUnits,
    ]);
  }

  @override
  Future<Uint8List?> thumbnail(BbsCart cart) async => null;
}
