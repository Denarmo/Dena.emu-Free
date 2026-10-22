// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for the tiny top-down physics world behind the library stash view.
// Spec: docs/specs/library-stash.md (Physics)
import 'dart:math' as math;
import 'dart:ui';

import 'package:dena_emu/src/library/stash_physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StashWorld', () {
    test('a flung body comes to rest within ten simulated seconds', () {
      final world = StashWorld(const Size(400, 600));
      final body = StashBody(
        id: 0,
        position: const Offset(200, 300),
        radius: 20,
      );
      world.bodies.add(body);
      world.fling(body, const Offset(1500, 800));

      for (var frame = 0; frame < 600; frame++) {
        world.advance(1 / 60);
      }

      expect(body.velocity, Offset.zero);
      expect(world.active, isFalse);
    });

    test('bodies shaken repeatedly stay inside the world', () {
      final world = StashWorld(const Size(400, 600));
      final spawn = math.Random(3);
      for (var i = 0; i < 8; i++) {
        final radius = 10.0 + i;
        world.bodies.add(
          StashBody(
            id: i,
            position: world.randomSpot(spawn, radius),
            radius: radius,
          ),
        );
      }

      // Five simulated seconds, shaking from scratch partway through.
      for (var frame = 0; frame < 300; frame++) {
        if (frame % 30 == 0) world.shake(math.Random(3));
        world.advance(1 / 60);
      }

      for (final body in world.bodies) {
        expect(
          body.position.dx,
          greaterThanOrEqualTo(body.radius - 0.001),
          reason: 'body ${body.id} left the world on x',
        );
        expect(
          body.position.dx,
          lessThanOrEqualTo(world.size.width - body.radius + 0.001),
          reason: 'body ${body.id} left the world on x',
        );
        expect(
          body.position.dy,
          greaterThanOrEqualTo(body.radius - 0.001),
          reason: 'body ${body.id} left the world on y',
        );
        expect(
          body.position.dy,
          lessThanOrEqualTo(world.size.height - body.radius + 0.001),
          reason: 'body ${body.id} left the world on y',
        );
      }
    });

    test('two overlapping bodies separate', () {
      final world = StashWorld(const Size(400, 600));
      final a = StashBody(id: 0, position: const Offset(100, 100), radius: 10);
      final b = StashBody(id: 1, position: const Offset(101, 100), radius: 10);
      world.bodies.addAll([a, b]);

      world.advance(0.05);

      expect(
        (a.position - b.position).distance,
        greaterThanOrEqualTo(a.radius + b.radius - 0.01),
      );
    });

    test('shake gives every non-held body velocity', () {
      final world = StashWorld(const Size(400, 600));
      final held = StashBody(
        id: 0,
        position: const Offset(100, 100),
        radius: 10,
      )..held = true;
      world.bodies.add(held);
      for (var i = 1; i < 5; i++) {
        world.bodies.add(
          StashBody(id: i, position: Offset(100.0 + i * 30, 300), radius: 10),
        );
      }

      world.shake(math.Random(1));

      for (final body in world.bodies) {
        if (body.held) continue;
        expect(body.velocity, isNot(Offset.zero), reason: 'body ${body.id}');
      }
      // A held body is left untouched by a shake.
      expect(held.velocity, Offset.zero);
    });

    test('a held body is not moved by a fast collision', () {
      final world = StashWorld(const Size(400, 600));
      final held = StashBody(
        id: 0,
        position: const Offset(200, 300),
        radius: 20,
      )..held = true;
      final fast = StashBody(
        id: 1,
        position: const Offset(100, 300),
        radius: 20,
      );
      world.bodies.addAll([held, fast]);

      world.fling(fast, const Offset(2000, 0));

      for (var frame = 0; frame < 60; frame++) {
        world.advance(1 / 60);
      }

      expect(held.position, const Offset(200, 300));
    });

    test('dropped bodies fall, bounce and settle on the table', () {
      final world = StashWorld(const Size(400, 600));
      for (var i = 0; i < 6; i++) {
        world.bodies.add(
          StashBody(
            id: i,
            position: Offset(100 + 40.0 * (i % 3), 200 + 60.0 * (i ~/ 3)),
            radius: 30,
          ),
        );
      }
      world.drop(math.Random(1));
      expect(world.bodies.every((b) => b.height >= StashWorld.dropFrom), true);
      // Staggered: the first lands before the last.
      expect(world.bodies.first.height, lessThan(world.bodies.last.height));

      var bounced = false;
      for (var frame = 0; frame < 600; frame++) {
        world.advance(1 / 60);
        if (world.bodies.any((b) => b.lift > 0)) {
          bounced = true;
        }
        for (final b in world.bodies) {
          expect(b.height, greaterThanOrEqualTo(0));
          expect(b.position.dx, inInclusiveRange(30, 370));
          expect(b.position.dy, inInclusiveRange(30, 570));
        }
      }

      expect(bounced, isTrue);
      expect(world.active, isFalse);
      expect(world.bodies.every((b) => b.height == 0 && !b.airborne), true);
      // Landing on each other pushed the stacked boxes apart.
      for (var i = 0; i < world.bodies.length; i++) {
        for (var j = i + 1; j < world.bodies.length; j++) {
          final a = world.bodies[i], b = world.bodies[j];
          expect(
            (a.position - b.position).distance,
            greaterThan(a.radius + b.radius - 1),
          );
        }
      }
    });

    test('a high box passes over one lying on the table', () {
      final world = StashWorld(const Size(400, 600));
      final low = StashBody(
        id: 0,
        position: const Offset(200, 300),
        radius: 30,
      );
      final high = StashBody(
        id: 1,
        position: const Offset(200, 300),
        radius: 30,
      )..height = 300;
      world.bodies.addAll([low, high]);

      world.advance(1 / 60);

      expect(low.position, const Offset(200, 300));
    });

    test('drop with a subset leaves the other bodies on the table', () {
      final world = StashWorld(const Size(400, 600));
      final a = StashBody(id: 0, position: const Offset(100, 100), radius: 20);
      final b = StashBody(id: 1, position: const Offset(300, 400), radius: 20);
      world.bodies.addAll([a, b]);

      world.drop(math.Random(2), [b]);

      expect(a.airborne, isFalse);
      expect(b.airborne, isTrue);
    });

    test('flinging a falling body puts it on the table', () {
      final world = StashWorld(const Size(400, 600));
      final b = StashBody(id: 0, position: const Offset(200, 300), radius: 20);
      world.bodies.add(b);
      world.drop(math.Random(3));

      world.fling(b, const Offset(100, 0));

      expect(b.airborne, isFalse);
    });
  });
}
