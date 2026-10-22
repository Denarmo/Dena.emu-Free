import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dena_emu/src/carts/bbs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final listing = File('test/carts/fixtures/listing.html').readAsStringSync();
  final png = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]);

  group('parseBbsListing', () {
    final carts = parseBbsListing(listing);

    test('reads every well-formed row and skips bad ones', () {
      expect(carts, hasLength(4));
      expect(carts.map((c) => c.postId), ['1001', '1002', '1003', '1004']);
    });

    test('fills the fields and decodes entities', () {
      final moon = carts[0];
      expect(moon.postId, '1001');
      expect(moon.threadId, 501);
      expect(moon.title, 'Moon Hopper');
      expect(moon.author, 'ada');
      expect(moon.authorId, 11);
      expect(moon.cartId, 'moon_hopper-2');
      expect(moon.thumbPath, '/bbs/thumbs/pico8_moon_hopper-2.png');
      expect(moon.updated, '2026-10-09 13:46:47');

      final tj = carts[1];
      expect(tj.title, "Tom & Jerry's Cave");
      expect(tj.author, 'bo"b');
      expect(tj.authorId, 12);
      expect(tj.cartId, 'tjcave-0');

      expect(carts[2].cartId, '45678');
      expect(carts[3].cartId, isNull);
    });

    test('empty input yields no carts', () {
      expect(parseBbsListing('<html></html>'), isEmpty);
    });
  });

  test('bbsCartUrl shapes string and numeric ids', () {
    expect(
      bbsCartUrl('moon_hopper-2').toString(),
      'https://www.lexaloffle.com/bbs/cposts/mo/moon_hopper-2.p8.png',
    );
    expect(
      bbsCartUrl('45678').toString(),
      'https://www.lexaloffle.com/bbs/cposts/4/45678.p8.png',
    );
  });

  test('cartIdFromThumb strips the prefix and suffix', () {
    expect(cartIdFromThumb('/bbs/thumbs/pico8_foo-3.png'), 'foo-3');
    expect(cartIdFromThumb('/bbs/thumbs/other.png'), isNull);
    expect(cartIdFromThumb('pico8_x.png'), 'x');
  });

  test('bbsListingUrl matches the spec table for every query', () {
    var uri = bbsListingUrl(const FeaturedCarts());
    expect(uri.path, '/bbs/');
    expect(uri.query, startsWith('cat=7&sub=2'));
    expect(uri.queryParameters, {
      'cat': '7',
      'sub': '2',
      'orderby': 'featured',
      'page': '1',
    });

    expect(bbsListingUrl(const FeaturedCarts(), page: 2).queryParameters, {
      'cat': '7',
      'sub': '2',
      'orderby': 'featured',
      'page': '2',
    });

    expect(bbsListingUrl(const NewCarts()).queryParameters, {
      'cat': '7',
      'sub': '2',
      'orderby': 'ts',
      'page': '1',
    });

    expect(bbsListingUrl(const SearchCarts('moon hopper')).queryParameters, {
      'cat': '7',
      'sub': '2',
      'search': 'moon hopper',
      'page': '1',
    });

    expect(bbsListingUrl(const AuthorCarts(11, 'ada')).queryParameters, {
      'cat': '7',
      'sub': '2',
      'uid': '11',
      'mode': 'carts',
      'page': '1',
    });
  });

  test('queries compare by value', () {
    expect(const FeaturedCarts(), const FeaturedCarts());
    expect(const NewCarts(), isNot(const FeaturedCarts()));
    expect(const SearchCarts('a'), const SearchCarts('a'));
    expect(const SearchCarts('a'), isNot(const SearchCarts('b')));
    expect(const AuthorCarts(1, 'a'), const AuthorCarts(1, 'a'));
    expect(const AuthorCarts(1, 'a'), isNot(const AuthorCarts(2, 'a')));
  });

  test('cart links point at the thread, thumb and cart', () {
    final cart = parseBbsListing(listing).first;
    expect(
      cart.threadUrl.toString(),
      'https://www.lexaloffle.com/bbs/?tid=501',
    );
    expect(
      cart.thumbUrl.toString(),
      'https://www.lexaloffle.com/bbs/thumbs/pico8_moon_hopper-2.png',
    );
    expect(cart.cartUrl, bbsCartUrl('moon_hopper-2'));

    final noArt = parseBbsListing(listing)[3];
    expect(noArt.cartUrl, isNull);
  });

  group('HttpBbsClient', () {
    final carts = parseBbsListing(listing);
    final cart = carts.first;

    test('list parses a page and asks for the listing URL', () async {
      final requested = <Uri>[];
      final client = HttpBbsClient(
        fetch: (url) async {
          requested.add(url);
          return Uint8List.fromList(utf8.encode(listing));
        },
      );

      final page = await client.list(const SearchCarts('moon hopper'), page: 2);
      expect(page.carts, hasLength(4));
      expect(page.carts.first.postId, '1001');
      expect(page.hasMore, isFalse);
      expect(
        requested.single,
        bbsListingUrl(const SearchCarts('moon hopper'), page: 2),
      );
    });

    test('a null reply is reported as no answer', () async {
      final client = HttpBbsClient(fetch: (_) async => null);
      await expectLater(
        client.list(const FeaturedCarts()),
        throwsA(isA<BbsException>()),
      );
    });

    test('a socket error is reported as no connection', () async {
      final client = HttpBbsClient(
        fetch: (_) async => throw const SocketException('down'),
      );
      await expectLater(
        client.list(const FeaturedCarts()),
        throwsA(isA<BbsException>()),
      );
    });

    test('a download that is not a PNG is rejected', () async {
      final client = HttpBbsClient(
        fetch: (_) async => Uint8List.fromList(const [1, 2, 3, 4]),
      );
      await expectLater(client.download(cart), throwsA(isA<BbsException>()));
    });

    test(
      'a download with a null cart id is rejected without fetching',
      () async {
        var calls = 0;
        final client = HttpBbsClient(
          fetch: (_) async {
            calls++;
            return png;
          },
        );
        await expectLater(
          client.download(carts[3]),
          throwsA(isA<BbsException>()),
        );
        expect(calls, 0);
      },
    );

    test('a PNG download is returned and asks for the cart URL', () async {
      Uri? requested;
      final client = HttpBbsClient(
        fetch: (url) async {
          requested = url;
          return png;
        },
      );
      expect(await client.download(cart), png);
      expect(requested, cart.cartUrl);
    });

    test('a download error is reported as no connection', () async {
      final client = HttpBbsClient(
        fetch: (_) async => throw const SocketException('down'),
      );
      await expectLater(client.download(cart), throwsA(isA<BbsException>()));
    });

    test('thumbnail swallows errors and caches the result', () async {
      var calls = 0;
      final client = HttpBbsClient(
        fetch: (_) async {
          calls++;
          throw const SocketException('down');
        },
      );
      expect(await client.thumbnail(cart), isNull);
      expect(await client.thumbnail(cart), isNull);
      expect(calls, 1);
    });

    test('thumbnail returns the fetched bytes', () async {
      Uri? requested;
      final client = HttpBbsClient(
        fetch: (url) async {
          requested = url;
          return png;
        },
      );
      expect(await client.thumbnail(cart), png);
      expect(requested, cart.thumbUrl);
    });
  });
}
