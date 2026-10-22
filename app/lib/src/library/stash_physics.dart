// SPDX-License-Identifier: GPL-3.0-or-later
// A tiny top-down 2D physics world for the library stash view.
// Spec: docs/specs/library-stash.md (Physics)
import 'dart:math' as math;
import 'dart:ui';

/// One box on the table, collided as a circle of [radius].
class StashBody {
  StashBody({
    required this.id,
    required this.position,
    required this.radius,
    this.angle = 0,
  });

  final int id;
  Offset position;
  Offset velocity = Offset.zero;
  double angle;
  double spin = 0;

  /// Set from the box widget's size, so it may change on resize.
  double radius;

  /// Height above the table in px while dropping in; 0 when lying on it.
  double height = 0;

  /// Vertical speed in px/s, positive upwards.
  double lift = 0;

  /// Held by a finger: moved by the drag, infinite mass in collisions.
  bool held = false;

  bool get airborne => height > 0 || lift != 0;

  bool get moving => velocity != Offset.zero || spin != 0 || airborne;
}

class StashWorld {
  StashWorld(this.size);

  static const step = 1 / 120;
  static const friction = 2.2;
  static const spinFriction = 3.0;
  static const wallBounce = 0.55;
  static const boxBounce = 0.6;
  static const restSpeed = 4.0;
  static const maxFling = 2500.0;

  /// Drop-in: gravity on [StashBody.height], bounce off the table, and the
  /// height band in which two boxes still hit each other.
  static const gravity = 2600.0;
  static const dropBounce = 0.32;
  static const landSpeed = 140.0;
  static const thickness = 22.0;
  static const dropFrom = 480.0;
  static const dropSpread = 620.0;

  Size size;
  final bodies = <StashBody>[];
  double _carry = 0;

  bool get active => bodies.any((b) => b.held || b.moving);

  /// Advances by [dt] seconds in fixed substeps.
  void advance(double dt) {
    _carry += math.min(dt, 0.1);
    while (_carry >= step) {
      _carry -= step;
      _substep(step);
    }
  }

  void _substep(double dt) {
    final damp = math.exp(-friction * dt);
    final spinDamp = math.exp(-spinFriction * dt);
    for (final b in bodies) {
      if (b.held) continue;
      if (b.airborne) _fall(b, dt);
      b.position += b.velocity * dt;
      b.angle += b.spin * dt;
      b.velocity *= damp;
      b.spin *= spinDamp;
      if (b.velocity.distance < restSpeed) b.velocity = Offset.zero;
      if (b.spin.abs() < 0.02) b.spin = 0;
    }
    for (var i = 0; i < bodies.length; i++) {
      for (var j = i + 1; j < bodies.length; j++) {
        _collide(bodies[i], bodies[j]);
      }
    }
    for (final b in bodies) {
      _walls(b);
    }
  }

  void _fall(StashBody b, double dt) {
    b.lift -= gravity * dt;
    b.height += b.lift * dt;
    if (b.height > 0) return;
    b.height = 0;
    if (b.lift < -landSpeed) {
      // Bounce, and the impact knocks the box askew a little.
      final kick = math.sin(b.id * 12.9898 + b.lift) * 0.5;
      b.lift = -b.lift * dropBounce;
      b.spin += kick * 3;
      b.velocity += Offset(math.cos(kick * 9), math.sin(kick * 9)) * 40;
    } else {
      b.lift = 0;
    }
  }

  void _collide(StashBody a, StashBody b) {
    if (a.held && b.held) return;
    // A box still high in the air passes over the ones below it.
    if ((a.height - b.height).abs() > thickness) return;
    var delta = b.position - a.position;
    var dist = delta.distance;
    final minDist = a.radius + b.radius;
    if (dist >= minDist) return;
    if (dist < 1e-6) {
      delta = Offset(math.cos(a.id + b.id * 1.7), math.sin(a.id + b.id * 1.7));
      dist = 1e-6;
    }
    final n = delta / dist;
    final overlap = minDist - dist;
    final ia = a.held ? 0.0 : 1.0, ib = b.held ? 0.0 : 1.0;
    final total = ia + ib;
    a.position -= n * (overlap * ia / total);
    b.position += n * (overlap * ib / total);
    final rel = b.velocity - a.velocity;
    final vn = rel.dx * n.dx + rel.dy * n.dy;
    if (vn >= 0) return;
    final j = -(1 + boxBounce) * vn / total;
    a.velocity -= n * (j * ia);
    b.velocity += n * (j * ib);
    // Glancing hits spin the boxes a little.
    final vt = rel.dx * -n.dy + rel.dy * n.dx;
    a.spin -= vt * 0.004 * ia;
    b.spin += vt * 0.004 * ib;
  }

  void _walls(StashBody b) {
    final r = b.radius;
    var p = b.position, v = b.velocity;
    if (p.dx < r) {
      p = Offset(r, p.dy);
      if (v.dx < 0) {
        v = Offset(-v.dx * wallBounce, v.dy);
        b.spin += v.dy * 0.003;
      }
    } else if (p.dx > size.width - r) {
      p = Offset(math.max(r, size.width - r), p.dy);
      if (v.dx > 0) {
        v = Offset(-v.dx * wallBounce, v.dy);
        b.spin -= v.dy * 0.003;
      }
    }
    if (p.dy < r) {
      p = Offset(p.dx, r);
      if (v.dy < 0) {
        v = Offset(v.dx, -v.dy * wallBounce);
        b.spin -= v.dx * 0.003;
      }
    } else if (p.dy > size.height - r) {
      p = Offset(p.dx, math.max(r, size.height - r));
      if (v.dy > 0) {
        v = Offset(v.dx, -v.dy * wallBounce);
        b.spin += v.dx * 0.003;
      }
    }
    b.position = p;
    b.velocity = v;
  }

  /// Keeps every body inside the area, e.g. after a resize.
  void clamp() {
    for (final b in bodies) {
      _walls(b);
    }
  }

  /// Releases [b] with a fling [velocity], clamped to [maxFling].
  void fling(StashBody b, Offset velocity) {
    b.held = false;
    b.height = 0;
    b.lift = 0;
    final speed = velocity.distance;
    b.velocity = speed > maxFling ? velocity * (maxFling / speed) : velocity;
    b.spin += (velocity.dx - velocity.dy) * 0.002;
  }

  /// Gives every body a random push and spin.
  void shake(math.Random random) {
    for (final b in bodies) {
      if (b.held) continue;
      final a = random.nextDouble() * 2 * math.pi;
      final s = 700 + random.nextDouble() * 900;
      b.velocity += Offset(math.cos(a), math.sin(a)) * s;
      b.spin += (random.nextDouble() - 0.5) * 8;
    }
  }

  /// Lifts [only] (all bodies by default) above the table so they fall in
  /// with gravity, the first one landing first. Spin makes them tumble.
  void drop(math.Random random, [Iterable<StashBody>? only]) {
    final list = [...(only ?? bodies)];
    for (var i = 0; i < list.length; i++) {
      final b = list[i];
      if (b.held) continue;
      final t = list.length == 1 ? 0.0 : i / (list.length - 1);
      b.height = dropFrom + t * dropSpread + random.nextDouble() * 40;
      b.lift = 0;
      b.velocity = Offset(
        (random.nextDouble() - 0.5) * 120,
        (random.nextDouble() - 0.5) * 120,
      );
      b.spin = (random.nextDouble() - 0.5) * 2.4;
    }
  }

  /// A random point where a body of [radius] fits inside the area.
  Offset randomSpot(math.Random random, double radius) {
    double pick(double extent) {
      final room = extent - 2 * radius;
      return room <= 0 ? extent / 2 : radius + random.nextDouble() * room;
    }

    return Offset(pick(size.width), pick(size.height));
  }
}
