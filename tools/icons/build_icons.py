#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds Dena Icons: the app's own icon font and its Dart constants.

Two drawing styles share one set of glyph names and codepoints:

  pixel (default)  Every glyph is a 9x9 bitmap of square cells, written below as
                   9-line strings of '#' and '.': one-cell strokes, stair-step
                   curves and diagonals, no anti-aliased shapes. Literal and a
                   little crude, like an old system font: the Brutalist look
                   (docs/specs/brutalist-ui.md, section 2.5). Cells are unioned
                   into clean outlines and the grid fills the same em box.
  moulded          The earlier set (--style moulded): rounded primitives on a
                   24-unit grid (y down), solid moulded shapes, 2.5-unit strokes
                   with round caps and cut-out details, like the system glyphs
                   of a handheld console (docs/specs/ui-look-and-feel.md).

The moulded dict order in glyphs() defines the codepoints (from U+E000) and the
Dart constant names; the pixel set must have exactly the same names in the same
order, and the build stops if it does not.

Outputs:
  app/assets/fonts/dena_icons/DenaIcons.otf
  app/lib/src/ui/dena_icons.dart
  (with --preview PATH) a PNG contact sheet of every glyph

Usage: python3 tools/icons/build_icons.py [--style pixel|moulded] [--preview PATH]
Needs: pip install fonttools skia-pathops (pillow for --preview).
"""
import argparse
import math
import pathlib

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen

ROOT = pathlib.Path(__file__).resolve().parents[2]
FONT_OUT = ROOT / 'app/assets/fonts/dena_icons/DenaIcons.otf'
DART_OUT = ROOT / 'app/lib/src/ui/dena_icons.dart'

GRID = 24
UPM = 960
SCALE = UPM / GRID
W = 2.5  # the house stroke
K = 0.5523  # cubic circle constant

U, D, I = pathops.PathOp.UNION, pathops.PathOp.DIFFERENCE, pathops.PathOp.INTERSECTION


# ---- primitives (design units, y down) -------------------------------------

def rrect(x, y, w, h, r, r2=None, r3=None, r4=None):
    """Rounded rect; one radius, or top-left, top-right, bottom-right, bottom-left."""
    rs = [r, r if r2 is None else r2, r if r3 is None else r3, r if r4 is None else r4]
    rs = [min(v, w / 2, h / 2) for v in rs]
    tl, tr, br, bl = rs
    p = pathops.Path()
    p.moveTo(x + tl, y)
    p.lineTo(x + w - tr, y)
    p.cubicTo(x + w - tr + tr * K, y, x + w, y + tr - tr * K, x + w, y + tr)
    p.lineTo(x + w, y + h - br)
    p.cubicTo(x + w, y + h - br + br * K, x + w - br + br * K, y + h, x + w - br, y + h)
    p.lineTo(x + bl, y + h)
    p.cubicTo(x + bl - bl * K, y + h, x, y + h - bl + bl * K, x, y + h - bl)
    p.lineTo(x, y + tl)
    p.cubicTo(x, y + tl - tl * K, x + tl - tl * K, y, x + tl, y)
    p.close()
    return p


def ellipse(cx, cy, rx, ry):
    p = pathops.Path()
    p.moveTo(cx + rx, cy)
    p.cubicTo(cx + rx, cy + ry * K, cx + rx * K, cy + ry, cx, cy + ry)
    p.cubicTo(cx - rx * K, cy + ry, cx - rx, cy + ry * K, cx - rx, cy)
    p.cubicTo(cx - rx, cy - ry * K, cx - rx * K, cy - ry, cx, cy - ry)
    p.cubicTo(cx + rx * K, cy - ry, cx + rx, cy - ry * K, cx + rx, cy)
    p.close()
    return p


def circle(cx, cy, r):
    return ellipse(cx, cy, r, r)


def poly(pts, r=0.0):
    """Closed polygon with each corner rounded by a quadratic of size r."""
    p = pathops.Path()
    n = len(pts)
    first = True
    for i in range(n):
        px, py = pts[i - 1]
        cx, cy = pts[i]
        nx, ny = pts[(i + 1) % n]
        l1 = math.hypot(px - cx, py - cy)
        l2 = math.hypot(nx - cx, ny - cy)
        d = min(r, l1 / 2, l2 / 2)
        a = (cx + (px - cx) / l1 * d, cy + (py - cy) / l1 * d)
        b = (cx + (nx - cx) / l2 * d, cy + (ny - cy) / l2 * d)
        if first:
            p.moveTo(*a)
            first = False
        else:
            p.lineTo(*a)
        if d > 0:
            p.quadTo(cx, cy, *b)
    p.close()
    return p


def stroke(path, w):
    path = pathops.Path(path)
    path.stroke(w, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    path.convertConicsToQuads()
    return path


def line(pts, w=W):
    p = pathops.Path()
    p.moveTo(*pts[0])
    for q in pts[1:]:
        p.lineTo(*q)
    return stroke(p, w)


def arc_pts(cx, cy, r, a0, a1, step=4):
    """Points on an arc; degrees, 0 = right, 90 = down."""
    n = max(2, int(abs(a1 - a0) / step) + 1)
    return [
        (cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / (n - 1))),
         cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / (n - 1))))
        for i in range(n)
    ]


def arc(cx, cy, r, a0, a1, w=W):
    return line(arc_pts(cx, cy, r, a0, a1), w)


def ring(cx, cy, r, w=W):
    return arc(cx, cy, r, 0, 360, w)


def head(tip, angle, s):
    """A rounded arrowhead with its tip at [tip], pointing along [angle] (deg)."""
    t = (math.cos(math.radians(angle)), math.sin(math.radians(angle)))
    n = (-t[1], t[0])
    bx, by = tip[0] - t[0] * s, tip[1] - t[1] * s
    return poly([
        tip,
        (bx + n[0] * s * 0.95, by + n[1] * s * 0.95),
        (bx - n[0] * s * 0.95, by - n[1] * s * 0.95),
    ], 0.7)


def arrow(pts, w=W, s=None):
    """A polyline ending in an arrowhead at its last point."""
    s = s or w * 1.9
    (x0, y0), (x1, y1) = pts[-2], pts[-1]
    ang = math.degrees(math.atan2(y1 - y0, x1 - x0))
    t = (math.cos(math.radians(ang)), math.sin(math.radians(ang)))
    body = pts[:-1] + [(x1 - t[0] * s * 0.6, y1 - t[1] * s * 0.6)]
    return union(line(body, w), head((x1, y1), ang, s))


def arc_arrow(cx, cy, r, a0, a1, w=W, s=None):
    """An arc ending in an arrowhead; a1 < a0 runs anticlockwise."""
    s = s or w * 1.9
    sign = 1 if a1 > a0 else -1
    # Stop the arc short so the head carries the tip.
    back = math.degrees(s * 0.55 / r) * sign
    body = arc(cx, cy, r, a0, a1 - back, w)
    ex = cx + r * math.cos(math.radians(a1 - back))
    ey = cy + r * math.sin(math.radians(a1 - back))
    tang = a1 - back + 90 * sign
    tip = (ex + math.cos(math.radians(tang)) * s * 0.55,
           ey + math.sin(math.radians(tang)) * s * 0.55)
    return union(body, head(tip, tang, s))


def star(cx, cy, ro, ri, n=5, r=0.9, rot=-90):
    pts = []
    for i in range(n * 2):
        rad = ro if i % 2 == 0 else ri
        a = math.radians(rot + i * 180 / n)
        pts.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
    return poly(pts, r)


def sparkle(cx, cy, R):
    return star(cx, cy, R, R * 0.32, n=4, r=0.25)


def rotate(path, deg, cx=12, cy=12):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return path.transform(c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy)


def mirror(path):
    return path.transform(-1, 0, 0, 1, GRID, 0)


def flip(path):
    return path.transform(1, 0, 0, -1, 0, GRID)


def move(path, dx, dy):
    return path.transform(1, 0, 0, 1, dx, dy)


def union(*paths):
    out = pathops.Path()
    for p in paths:
        out = pathops.op(out, p, U)
    return out


def cut(base, *paths):
    for p in paths:
        base = pathops.op(base, p, D)
    return base


def clip(a, b):
    return pathops.op(a, b, I)


def outline(shape, w=2.2):
    """The inner band of [shape]'s edge: an outlined version of a solid glyph."""
    return clip(stroke(shape, w * 2), shape)


def box(x, y, w, h):
    return rrect(x, y, w, h, 0)


# ---- shared shapes -----------------------------------------------------------

def controller():
    return rrect(1.8, 6.2, 20.4, 11.6, 5.8)


def controller_details():
    return [
        line([(7, 9.2), (7, 14.8)], 2.1),
        line([(4.2, 12), (9.8, 12)], 2.1),
        circle(15.6, 13.4, 1.55),
        circle(18.4, 10.6, 1.55),
    ]


def cart():
    return poly([(5, 2.5), (15.5, 2.5), (19, 6), (19, 21.5), (5, 21.5)], 2)


def cart_details():
    return [rrect(7.6, 5.8, 8.8, 8, 1.3)] + [rrect(x, 17.2, 1.6, 2.6, 0.5) for x in (8, 11.2, 14.4)]


def cloud():
    return union(circle(8.2, 13.4, 4.6), circle(13.4, 10.6, 6.0), circle(17.6, 14.2, 4.0),
                 rrect(3.6, 12.6, 18.0, 8.0, 4.0))


def gear():
    teeth = [rotate(rrect(10.2, 1.6, 3.6, 5, 1.1), k * 45) for k in range(8)]
    return union(circle(12, 12, 7.0), *teeth)


def house():
    return poly([(12, 2.8), (21.2, 10.4), (21.2, 21.2), (2.8, 21.2), (2.8, 10.4)], 2.2)


def page():
    return poly([(5, 2.5), (14, 2.5), (19, 7.5), (19, 21.5), (5, 21.5)], 2)


def folder():
    return poly([(2.5, 4.5), (9.2, 4.5), (11.4, 7.2), (21.5, 7.2), (21.5, 19.5), (2.5, 19.5)], 2)


def plus(cx, cy, s, w=2.2):
    return union(line([(cx, cy - s), (cx, cy + s)], w), line([(cx - s, cy), (cx + s, cy)], w))


def screen_frame():
    return cut(rrect(3, 4, 18, 16, 3), rrect(5.4, 6.4, 13.2, 11.2, 1.4))


def trophy_cup():
    return rrect(6.5, 3, 11, 9.5, 1.2, 1.2, 5.5, 5.5)


def trophy_rest():
    return [
        arc(6.5, 7.4, 2.7, 90, 270, 2.1),
        arc(17.5, 7.4, 2.7, -90, 90, 2.1),
        rrect(10.8, 12, 2.4, 4.5, 0.6),
        rrect(7.5, 16.2, 9, 2.3, 1),
        rrect(6, 18.8, 12, 2.7, 1.3),
    ]


def big_star():
    return star(12, 12.6, 10, 4.6, r=1.3)


def video_card():
    return rrect(2.8, 7, 18.4, 14, 2.6)


def video_strips():
    return [rrect(5, 3.4, 14, 2, 1)]


def apps_tiles(f):
    return [f(rrect(2.8 + i * 6.6, 2.8 + j * 6.6, 5.2, 5.2, 1.7)) for i in range(3) for j in range(3)]


def phone_frame():
    return cut(rrect(5.5, 1.8, 13, 20.4, 2.8), rrect(7.6, 4.6, 8.8, 13.6, 1))


def door_arrow(out):
    if out:
        return union(line([(10.5, 3.8), (5, 3.8), (5, 20.2), (10.5, 20.2)]),
                     arrow([(10, 12), (21, 12)]))
    return union(line([(13.5, 3.8), (19, 3.8), (19, 20.2), (13.5, 20.2)]),
                 arrow([(2.8, 12), (14.2, 12)]))


def magnifier(cx, cy, r, w=W):
    d = r / math.sqrt(2)
    return union(ring(cx, cy, r, w), line([(cx + d + 0.6, cy + d + 0.6), (cx + d + 4.2, cy + d + 4.2)], w + 0.9))


def person_at(dx=0.0, s=1.0):
    return union(circle(12 + dx, 7.8, 4.3 * s), rrect(12 + dx - 8 * s, 13.6, 16 * s, 7.6, 6, 6, 2, 2))


def note(cx, cy, s=1.0):
    return union(ellipse(cx, cy, 3.6 * s, 3.1 * s),
                 rrect(cx + 1.4 * s, cy - 13 * s, 2.5 * s, 13 * s, 1.2 * s),
                 poly([(cx + 1.4 * s, cy - 13 * s), (cx + 8 * s, cy - 11 * s), (cx + 8 * s, cy - 7.4 * s),
                       (cx + 3.9 * s, cy - 8.6 * s)], 1.2 * s))


def ten(cx, cy):
    return union(rrect(cx - 3.1, cy - 3, 1.6, 6, 0.7),
                 cut(ellipse(cx + 1.4, cy, 2.2, 3.1), ellipse(cx + 1.4, cy, 0.8, 1.7)))


def replay_arc(cx=12, cy=13):
    return arc_arrow(cx, cy, 7.6, 150, -88)


def sun_rays(r_in, r_len, w=2.2):
    return [rotate(line([(12, 12 - r_in), (12, 12 - r_in - r_len)], w), k * 45) for k in range(8)]


# ---- the glyphs ----------------------------------------------------------------
# name -> path. Order here is the codepoint order (from U+E000); append only, so
# codepoints stay stable across rebuilds.

def glyphs():
    g = {}
    g['play'] = poly([(6.8, 4), (20.4, 12), (6.8, 20)], 2.6)
    g['pause'] = union(rrect(5.4, 4.2, 5, 15.6, 1.8), rrect(13.6, 4.2, 5, 15.6, 1.8))
    g['controller'] = cut(controller(), *controller_details())
    g['controllerOutline'] = union(outline(controller()), *controller_details())
    g['cart'] = cut(cart(), *cart_details())
    g['cartOutline'] = union(outline(cart()), *cart_details())
    g['chevronRight'] = line([(9, 4.8), (16.2, 12), (9, 19.2)], 2.9)
    g['chevronLeft'] = mirror(g['chevronRight'])
    g['expandMore'] = line([(4.8, 9), (12, 16.2), (19.2, 9)], 2.9)
    g['expandLess'] = flip(g['expandMore'])
    g['arrowBack'] = union(line([(19.5, 12), (6, 12)], 2.8), line([(11.2, 5), (4.4, 12), (11.2, 19)], 2.8))
    g['arrowForward'] = mirror(g['arrowBack'])
    g['search'] = magnifier(10.2, 10.2, 6.3, 2.7)
    g['searchOff'] = union(magnifier(10.2, 10.2, 6.3, 2.7), line([(8, 8), (12.4, 12.4)], 2), line([(12.4, 8), (8, 12.4)], 2))
    g['person'] = person_at()
    g['personSearch'] = union(cut(person_at(-2.8, 0.85), circle(17.6, 15.2, 5.6)), magnifier(17, 14.6, 2.9, 2.1))
    g['musicNote'] = note(8.6, 17.4)
    g['lock'] = union(
        cut(rrect(4.4, 10, 15.2, 11.6, 3.2), circle(12, 14.6, 1.9), rrect(11.05, 15, 1.9, 3.8, 0.9)),
        line([(7.6, 11)] + arc_pts(12, 8.6, 4.4, 180, 360) + [(16.4, 11)], 2.5))
    g['trophy'] = union(cut(trophy_cup(), star(12, 7.4, 3, 1.35, r=0.4)), *trophy_rest())
    g['trophyOutline'] = union(outline(trophy_cup(), 2.1), *trophy_rest())
    g['star'] = big_star()
    g['starOutline'] = outline(big_star(), 2.3)
    g['globe'] = union(ring(12, 12, 8.6, 2.4), cut(ellipse(12, 12, 4.2, 8.6), ellipse(12, 12, 2.2, 7.4)),
                       line([(3.8, 12), (20.2, 12)], 2.1))
    link_shape = union(outline(rrect(1.6, 8.2, 11.6, 7.6, 3.8), 2.5), outline(rrect(10.8, 8.2, 11.6, 7.6, 3.8), 2.5))
    g['link'] = rotate(link_shape, -45)
    g['linkOff'] = union(cut(rotate(link_shape, -45), rotate(box(10.6, -2, 2.8, 28), -45)),
                         line([(4.4, 4.4), (19.6, 19.6)], 2.3))
    g['add'] = plus(12, 12, 7.6, 3)
    g['close'] = rotate(plus(12, 12, 7.8, 3), 45)
    g['check'] = line([(4.4, 12.6), (9.6, 17.6), (19.6, 6.6)], 3)
    medal = cut(circle(12, 9.4, 7), star(12, 9.6, 4, 1.8, r=0.5))
    ribbon = poly([(7.4, 13), (11, 15), (9.3, 21.6), (7.7, 19.6), (5.2, 20.4)], 0.8)
    g['premium'] = union(cut(union(ribbon, mirror(ribbon)), circle(12, 9.4, 8.4)), medal)
    g['broadcast'] = union(circle(12, 12, 2.4), arc(12, 12, 5.4, 140, 220, 2.3), arc(12, 12, 5.4, -40, 40, 2.3),
                           arc(12, 12, 9.2, 140, 220, 2.3), arc(12, 12, 9.2, -40, 40, 2.3))
    vplay = poly([(9.8, 10.4), (15.6, 14), (9.8, 17.6)], 1)
    g['videoLibrary'] = union(cut(video_card(), vplay), *video_strips())
    g['videoLibraryOutline'] = union(outline(video_card()), vplay, *video_strips())
    g['usb'] = union(cut(rrect(8, 2.2, 8, 7.4, 1.4), rrect(9.7, 4.4, 1.6, 2.2, 0.4), rrect(12.7, 4.4, 1.6, 2.2, 0.4)),
                     rrect(5.8, 8.8, 12.4, 9.6, 3.4), rrect(10.7, 17.5, 2.6, 4.5, 1.2))
    g['tv'] = union(cut(rrect(2.4, 4.4, 19.2, 13.4, 3.2), rrect(5, 7, 14, 8.2, 1.4)), rrect(7.5, 19.2, 9, 2.4, 1.2))
    g['sync'] = union(arc_arrow(12, 12, 7.4, 200, 335), arc_arrow(12, 12, 7.4, 20, 155))
    g['swap'] = union(arrow([(4, 8.2), (20.4, 8.2)]), arrow([(20, 15.8), (3.6, 15.8)]))
    g['refresh'] = arc_arrow(12, 12, 7.6, 70, 345)
    g['restore'] = union(replay_arc(12, 12.4), line([(12, 9.2), (12, 12.8), (14.6, 14.4)], 2.2))
    g['replay'] = union(replay_arc(), poly([(10.2, 10.4), (15, 13.2), (10.2, 16)], 0.8))
    g['rewind10'] = union(replay_arc(), ten(12.6, 13.2))
    g['forward10'] = union(mirror(replay_arc()), ten(11.6, 13.2))
    g['skipNext'] = union(poly([(4.6, 4.8), (15.6, 12), (4.6, 19.2)], 2.2), rrect(16.2, 4.8, 3.2, 14.4, 1.4))
    g['skipPrevious'] = mirror(g['skipNext'])
    g['fastForward'] = union(poly([(2.6, 5.6), (12, 12), (2.6, 18.4)], 1.8), poly([(12, 5.6), (21.4, 12), (12, 18.4)], 1.8))
    g['fastRewind'] = mirror(g['fastForward'])
    g['shuffle'] = union(arrow([(3.4, 7), (7.6, 7), (15.6, 17), (21, 17)], 2.3),
                         line([(3.4, 17), (7.6, 17), (10, 14)], 2.3), arrow([(13.2, 10), (15.6, 7), (21, 7)], 2.3))
    g['repeat'] = union(arrow([(5.6, 13.4), (5.6, 8.4), (20.4, 8.4)], 2.4), arrow([(18.4, 10.6), (18.4, 15.6), (3.6, 15.6)], 2.4))
    g['repeatOne'] = union(g['repeat'], rrect(11.1, 10.1, 1.8, 3.8, 0.7))
    g['fileAdd'] = cut(page(), plus(12, 14.2, 3.6))
    g['document'] = cut(page(), *[rrect(8, y, 8, 1.8, 0.9) for y in (10.4, 13.6)], rrect(8, 16.8, 5, 1.8, 0.9))
    g['folder'] = folder()
    g['folderAdd'] = cut(folder(), plus(12, 13.4, 3.4))
    g['film'] = cut(rrect(3, 3.6, 18, 16.8, 2.6), rrect(8.4, 5.6, 7.2, 12.8, 1.2),
                    *[rrect(x, y, 2, 2.2, 0.6) for x in (4.8, 17.2) for y in (6, 10.9, 15.8)])
    g['exit'] = door_arrow(True)
    g['enter'] = door_arrow(False)
    g['equalizer'] = union(*[rrect(x - 1.25, 12 - h / 2, 2.5, h, 1.25) for x, h in
                             ((3.8, 6), (8, 12), (12, 17), (16, 10), (20.2, 6))])
    g['download'] = union(arrow([(12, 3.2), (12, 16.2)], 2.8), rrect(4, 18.6, 16, 2.8, 1.4))
    srv = lambda y: cut(rrect(2.8, y, 18.4, 7.6, 2.2), circle(7, y + 3.8, 1.4), rrect(11, y + 2.9, 7, 1.8, 0.9))
    g['server'] = union(srv(3.2), srv(13.2))
    g['network'] = union(rrect(8.8, 2.6, 6.4, 5.4, 1.4), rrect(2.4, 16, 6.4, 5.4, 1.4), rrect(15.2, 16, 6.4, 5.4, 1.4),
                         line([(12, 8), (12, 12), (5.6, 12), (5.6, 16)], 2.1), line([(12, 12), (18.4, 12), (18.4, 16)], 2.1))
    g['trash'] = union(rrect(3.8, 4.8, 16.4, 2.8, 1.4), cut(rrect(9.3, 2.4, 5.4, 4, 1.4), rrect(10.9, 3.9, 2.2, 1.2, 0.3)),
                       cut(poly([(5.4, 8.6), (18.6, 8.6), (17.4, 21.4), (6.6, 21.4)], 2),
                           rrect(9.2, 11.2, 1.7, 7.2, 0.85), rrect(13.1, 11.2, 1.7, 7.2, 0.85)))
    g['cloud'] = cloud()
    g['cloudDone'] = cut(cloud(), line([(8.6, 15), (11.2, 17.4), (16, 12.6)], 2.3))
    g['cloudOff'] = union(cut(cloud(), rotate(box(10.4, -2, 3.2, 28), -45)), line([(4, 4), (20, 20)], 2.3))
    g['cloudSync'] = cut(cloud(), arc_arrow(12.6, 15.6, 3.2, 200, 330, 1.6, 2.6), arc_arrow(12.6, 15.6, 3.2, 20, 150, 1.6, 2.6))
    g['disc'] = cut(circle(12, 12, 9.6), circle(12, 12, 2.2), arc(12, 12, 6.2, 200, 250, 1.1))
    g['image'] = union(outline(rrect(2.8, 3.8, 18.4, 16.4, 2.8), 2.3),
                       poly([(5.8, 17.6), (9.8, 11.2), (12.8, 15), (14.8, 12.8), (18.2, 17.6)], 0.9), circle(15.4, 8.6, 1.9))
    g['speed'] = union(arc(12, 14.2, 8.6, 150, 390, 2.6), line([(12, 14.2), (16.6, 9)], 2.6), circle(12, 14.2, 2.4))
    g['sort'] = union(rrect(3, 5.2, 18, 2.8, 1.4), rrect(3, 10.6, 12, 2.8, 1.4), rrect(3, 16, 6, 2.8, 1.4))
    g['bag'] = union(rrect(4, 7.6, 16, 13.8, 1.6, 1.6, 3.4, 3.4), arc(12, 8.2, 3.8, 180, 360, 2.3))
    g['settings'] = cut(gear(), circle(12, 12, 2.9))
    g['settingsOutline'] = union(outline(gear(), 2.2), ring(12, 12, 2.6, 2.1))
    g['sdCard'] = cut(poly([(8.2, 2.4), (19, 2.4), (19, 21.6), (5, 21.6), (5, 5.6)], 1.9),
                      *[rrect(x, 4.6, 1.6, 3.6, 0.5) for x in (8.6, 11.4, 14.2)])
    g['save'] = cut(poly([(3.4, 3.4), (16.8, 3.4), (20.6, 7.2), (20.6, 20.6), (3.4, 20.6)], 2.2),
                    rrect(7, 3.4, 8.4, 5.2, 0.9), rrect(6.4, 12.6, 11.2, 5.6, 1.2))
    g['radioOff'] = ring(12, 12, 8, 2.5)
    g['radioOn'] = union(ring(12, 12, 8, 2.5), circle(12, 12, 4.3))
    g['playlist'] = union(rrect(2.8, 4.8, 12, 2.6, 1.3), rrect(2.8, 9.8, 12, 2.6, 1.3), rrect(2.8, 14.8, 7, 2.6, 1.3),
                          note(15.4, 18.4, 0.82))
    g['playCircle'] = cut(circle(12, 12, 9.6), poly([(9.6, 7.6), (17, 12), (9.6, 16.4)], 1.3))
    g['camera'] = cut(union(rrect(2.4, 6.8, 19.2, 13.6, 3.2), poly([(7.6, 7.6), (9.4, 4.2), (14.6, 4.2), (16.4, 7.6)], 1.2)),
                      cut(circle(12, 13.4, 4.8), circle(12, 13.4, 2.7)), circle(18.2, 10, 1))
    g['palette'] = cut(circle(12, 12, 9.4), *[circle(x, y, 1.65) for x, y in ((7.4, 10.4), (10.6, 6.6), (15.4, 7.2), (17.6, 11.4))],
                       circle(15.4, 18.6, 3.1))
    g['menu'] = union(*[rrect(3.4, y, 17.2, 2.9, 1.45) for y in (5.2, 10.55, 15.9)])
    flame = union(circle(12, 15, 6.4), poly([(6, 13.2), (11.4, 2.2), (14.2, 6.6), (18, 13.2)], 1.6))
    g['flame'] = cut(flame, union(circle(12, 17.2, 2.6), poly([(9.6, 16.4), (12, 11.6), (14.4, 16.4)], 0.6)))
    g['list'] = union(*[circle(4.8, y, 1.7) for y in (6.4, 12, 17.6)], *[rrect(8.6, y - 1.3, 12.6, 2.6, 1.3) for y in (6.4, 12, 17.6)])
    g['sun'] = union(circle(12, 12, 4.4), *sun_rays(6.6, 2.6))
    g['moon'] = cut(circle(12, 12.4, 8.6), circle(16.8, 7.6, 7))
    g['themeAuto'] = union(ring(12, 12, 8.6, 2.3), line([(8.4, 16.6), (12, 7.4), (15.6, 16.6)], 2.3), line([(9.9, 13.2), (14.1, 13.2)], 2))
    g['contrast'] = union(ring(12, 12, 8.6, 2.3), clip(circle(12, 12, 8.6), box(12, 0, 12, 24)))
    g['musicLibrary'] = union(cut(rrect(6.2, 2.4, 15.4, 15.4, 2.6), note(12.2, 13.8, 0.55)),
                              line([(2.8, 7.2), (2.8, 21.2), (16.8, 21.2)], 2.3))
    g['home'] = cut(house(), rrect(9.8, 14, 4.4, 9, 1.3))
    g['homeOutline'] = union(outline(house(), 2.3), rrect(10.3, 14.4, 3.4, 7, 1.1))
    g['help'] = cut(circle(12, 12, 9.6), line(arc_pts(12, 9.4, 3, 190, 400) + [(12.1, 13.2), (12.1, 14)], 2.4), circle(12.1, 17.2, 1.45))
    g['info'] = cut(circle(12, 12, 9.6), rrect(10.8, 10.4, 2.4, 7.2, 1.2), circle(12, 7.2, 1.55))
    g['warning'] = cut(poly([(12, 2.6), (22.2, 20.6), (1.8, 20.6)], 2.6), rrect(10.8, 8.4, 2.4, 6.6, 1.2), circle(12, 17.3, 1.45))
    g['error'] = cut(circle(12, 12, 9.6), rrect(10.8, 6.2, 2.4, 7.4, 1.2), circle(12, 16.8, 1.55))
    g['grid'] = union(*[rrect(x, y, 7.8, 7.8, 2.2) for x in (3.2, 13) for y in (3.2, 13)])
    diamond = poly([(16.8, 7.2), (13.4, 13.4), (7.2, 16.8), (10.6, 10.6)], 0.6)
    g['compass'] = union(cut(circle(12, 12, 9.6), diamond), poly([(16.8, 7.2), (13.4, 13.4), (10.6, 10.6)], 0.4))
    g['eject'] = union(poly([(12, 4.2), (20.2, 14), (3.8, 14)], 1.8), rrect(3.8, 16.6, 16.4, 3, 1.3))
    pencil = union(cut(rrect(10.1, 2.6, 3.8, 14.8, 1.2), box(9, 6.2, 6, 0.9)),
                   poly([(10.1, 17.4), (13.9, 17.4), (12, 21.4)], 0.5))
    g['edit'] = rotate(pencil, 45)
    g['dice'] = cut(rrect(3, 3, 18, 18, 4.2), *[circle(x, y, 1.75) for x, y in
                                                ((7.8, 7.8), (16.2, 7.8), (12, 12), (7.8, 16.2), (16.2, 16.2))])
    g['cable'] = union(rrect(2.6, 3.4, 6, 7.4, 1.6), rrect(4.3, 1.2, 2.6, 2.8, 0.6),
                       rrect(15.4, 13.2, 6, 7.4, 1.6), rrect(17.1, 20, 2.6, 2.8, 0.6),
                       line([(5.6, 10), (5.6, 14.6), (7.8, 17), (10, 17), (12, 15), (12, 9), (14, 7), (16.2, 7),
                             (18.4, 9.2), (18.4, 13.6)], 2.1))
    g['bolt'] = poly([(14, 1.8), (4.6, 13.6), (11, 13.6), (9.6, 22.2), (19.4, 9.8), (13, 9.8)], 1.1)
    g['magic'] = union(line([(4, 20), (14, 10)], 3), sparkle(17.6, 5.8, 4), sparkle(8.2, 5.2, 2.5), sparkle(19.4, 15, 2.5))
    g['apps'] = union(*apps_tiles(lambda p: p))
    g['appsOutline'] = union(*apps_tiles(lambda p: outline(p, 1.6)))
    g['addToHome'] = union(phone_frame(), plus(12, 11.4, 2.8, 2.1), rrect(10.4, 19.2, 3.2, 1.4, 0.7))
    g['appTile'] = cut(rrect(3.2, 3.2, 17.6, 17.6, 5.6), star(12, 12.4, 5, 2.3, r=0.6))
    g['speaker'] = union(rrect(2.6, 8.8, 5.4, 6.4, 1.2), poly([(6, 8.8), (12.4, 4), (12.4, 20), (6, 15.2)], 1.2),
                         arc(12.4, 12, 4.4, -45, 45, 2.2), arc(12.4, 12, 8, -45, 45, 2.2))
    g['moreVert'] = union(*[circle(12, y, 2.2) for y in (5.2, 12, 18.8)])
    g['dpad'] = union(rrect(8.6, 2.6, 6.8, 18.8, 1.8), rrect(2.6, 8.6, 18.8, 6.8, 1.8))
    g['brightness'] = union(cut(circle(12, 12, 4.4), box(12, 0, 12, 24)), ring(12, 12, 4.4, 1.6), *sun_rays(6.8, 2.4))
    return g


# ---- pixel style (the default) -------------------------------------------------
# Every glyph is a 9x9 bitmap: '#' is a filled cell, '.' an empty one. Strokes are
# one cell, curves and diagonals are stair-steps, like an old system font. Each
# cell becomes a square of PX design units; the grid sits centred in the same
# 24-unit box (and so the same em square and advance) as the moulded glyphs.

N = 9
PX = 2.2  # cell size in design units: the 9-cell grid spans 19.8 of the 24
P0 = (GRID - N * PX) / 2  # top-left of the grid, so glyphs centre like before

# Half-cell nudges for drawings whose natural layout is an even number of cells.
PIXEL_SHIFT = {'apps': (0.5, 0.5), 'moreVert': (0.5, 0.5)}


def bm(s):
    """A bitmap from a 9-line string of '#' and '.', checked for size."""
    rows = [r.strip() for r in s.strip('\n').split('\n')]
    if len(rows) != N or any(len(r) != N or set(r) - set('#.') for r in rows):
        raise ValueError(f'bitmap is not {N}x{N} of # and .:\n{s}')
    return '\n'.join(rows)


def _rows(s):
    return s.split('\n')


def bm_mirror(s):
    """Left-right mirror."""
    return '\n'.join(r[::-1] for r in _rows(s))


def bm_flip(s):
    """Top-bottom flip."""
    return '\n'.join(_rows(s)[::-1])


def bm_hollow(s):
    """The outline of a solid bitmap: keep only cells with an empty 4-neighbour."""
    rows = _rows(s)
    on = lambda r, c: 0 <= r < N and 0 <= c < N and rows[r][c] == '#'
    return '\n'.join(''.join(
        '#' if on(r, c) and not all(on(r + dr, c + dc) for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1))) else '.'
        for c in range(N)) for r in range(N))


def bm_or(*ss):
    """Cells filled in any of the bitmaps."""
    return '\n'.join(''.join('#' if any(_rows(s)[r][c] == '#' for s in ss) else '.' for c in range(N))
                     for r in range(N))


def bm_cut(s, holes):
    """Clear the cells marked '#' in [holes]."""
    h = _rows(holes)
    return '\n'.join(''.join('.' if h[r][c] == '#' else ch for c, ch in enumerate(row))
                     for r, row in enumerate(_rows(s)))


def bm_slash(s):
    """A top-left to bottom-right slash with a one-cell gap below it ("off")."""
    g = [list(r) for r in _rows(s)]
    for r in range(N):
        g[r][r] = '#'
        if r + 1 < N:
            g[r + 1][r] = '.'
    return '\n'.join(''.join(r) for r in g)


def bm_path(s, shift=(0.0, 0.0)):
    """Union the filled cells of a bitmap into one clean outline (24-grid, y down)."""
    rows = _rows(s)
    cells = pathops.Path()
    for r, row in enumerate(rows):
        c = 0
        while c < N:  # one rectangle per horizontal run keeps the union cheap
            if row[c] != '#':
                c += 1
                continue
            e = c
            while e < N and row[e] == '#':
                e += 1
            x, y = P0 + (c + shift[0]) * PX, P0 + (r + shift[1]) * PX
            cells.moveTo(x, y)
            cells.lineTo(x + (e - c) * PX, y)
            cells.lineTo(x + (e - c) * PX, y + PX)
            cells.lineTo(x, y + PX)
            cells.close()
            c = e
    return pathops.simplify(cells, fix_winding=True)


def pixel_bitmaps():
    p = {}
    p['play'] = bm('''
        ..#......
        ..##.....
        ..###....
        ..####...
        ..#####..
        ..####...
        ..###....
        ..##.....
        ..#......''')
    p['pause'] = bm('''
        .........
        .##...##.
        .##...##.
        .##...##.
        .##...##.
        .##...##.
        .##...##.
        .##...##.
        .........''')
    p['controller'] = bm('''
        .........
        .#######.
        ###.##.##
        ##...####
        ###.##.##
        #########
        ###...###
        ##.....##
        .........''')
    p['controllerOutline'] = bm('''
        .........
        .#######.
        #.#.....#
        ###...#.#
        #.#..#..#
        #..###..#
        #.#...#.#
        ##.....##
        .........''')
    p['cart'] = bm('''
        .######..
        .#######.
        .#.....#.
        .#.....#.
        .#.....#.
        .#######.
        .#######.
        .#.#.#.#.
        .#######.''')
    p['cartOutline'] = bm('''
        .######..
        .#.....#.
        .#.###.#.
        .#.###.#.
        .#.###.#.
        .#.....#.
        .#.....#.
        .#.#.#.#.
        .#######.''')
    p['chevronRight'] = bm('''
        .........
        ..##.....
        ...##....
        ....##...
        .....##..
        ....##...
        ...##....
        ..##.....
        .........''')
    p['chevronLeft'] = bm_mirror(p['chevronRight'])
    p['expandMore'] = bm('''
        .........
        .........
        .#.....#.
        .##...##.
        ..##.##..
        ...###...
        ....#....
        .........
        .........''')
    p['expandLess'] = bm_flip(p['expandMore'])
    p['arrowBack'] = bm('''
        .........
        ....#....
        ...##....
        ..##.....
        .#######.
        ..##.....
        ...##....
        ....#....
        .........''')
    p['arrowForward'] = bm_mirror(p['arrowBack'])
    p['search'] = bm('''
        ..###....
        .#...#...
        #.....#..
        #.....#..
        #.....#..
        .#...##..
        ..###.##.
        .......##
        ........#''')
    p['searchOff'] = bm('''
        ..###....
        .#...#...
        #.#.#.#..
        #..#..#..
        #.#.#.#..
        .#...##..
        ..###.##.
        .......##
        ........#''')
    p['person'] = bm('''
        ...###...
        ..#####..
        ..#####..
        ..#####..
        ...###...
        .........
        .#######.
        #########
        #########''')
    p['personSearch'] = bm('''
        .##......
        ####.....
        ####.....
        .##..##..
        ....#..#.
        ###.#..#.
        ####.##..
        ####...#.
        ####....#''')
    p['musicNote'] = bm('''
        ....#....
        ....##...
        ....#.#..
        ....#..#.
        ....#..#.
        ....#.#..
        .####....
        #####....
        .###.....''')
    p['lock'] = bm('''
        ...###...
        ..#...#..
        ..#...#..
        .#######.
        .#######.
        .###.###.
        .###.###.
        .#######.
        .#######.''')
    p['trophy'] = bm('''
        #########
        #.#####.#
        #.##.##.#
        .#.###.#.
        ...###...
        ....#....
        ....#....
        ..#####..
        ..#####..''')
    p['trophyOutline'] = bm('''
        #########
        #.#...#.#
        #.#...#.#
        .#.#.#.#.
        ...###...
        ....#....
        ....#....
        ..#####..
        ..#####..''')
    p['star'] = bm('''
        ....#....
        ...###...
        ...###...
        #########
        .#######.
        ..#####..
        ..#####..
        .###.###.
        .##...##.''')
    p['starOutline'] = bm_hollow(p['star'])
    p['globe'] = bm('''
        ..#####..
        .#.#.#.#.
        #..#.#..#
        #..#.#..#
        #########
        #..#.#..#
        #..#.#..#
        .#.#.#.#.
        ..#####..''')
    p['link'] = bm('''
        .........
        .........
        .###.###.
        #.......#
        #.#####.#
        #.......#
        .###.###.
        .........
        .........''')
    p['linkOff'] = bm('''
        .........
        .#.......
        .###.###.
        #..#....#
        #.#.#.#.#
        #....#..#
        .###.###.
        .......#.
        .........''')
    p['add'] = bm('''
        .........
        ....#....
        ....#....
        ....#....
        .#######.
        ....#....
        ....#....
        ....#....
        .........''')
    p['close'] = bm('''
        .........
        ##.....##
        .##...##.
        ..##.##..
        ...###...
        ..##.##..
        .##...##.
        ##.....##
        .........''')
    p['check'] = bm('''
        .........
        .......##
        ......##.
        .....##..
        #...##...
        ##.##....
        .###.....
        ..#......
        .........''')
    p['premium'] = bm('''
        ..#####..
        .#######.
        .###.###.
        .##...##.
        .###.###.
        .#######.
        ..#####..
        ..##.##..
        ..#...#..''')
    p['broadcast'] = bm('''
        .........
        .#.....#.
        #..#.#..#
        #.#...#.#
        #.#.#.#.#
        #.#...#.#
        #..#.#..#
        .#.....#.
        .........''')
    p['videoLibrary'] = bm('''
        ..#######
        ..##.####
        #.##..###
        #.##...##
        #.##..###
        #.##.####
        #.#######
        #........
        #######..''')
    p['videoLibraryOutline'] = bm('''
        ..#######
        ..#.....#
        #.#.#...#
        #.#.##..#
        #.#.#...#
        #.#.....#
        #.#######
        #........
        #######..''')
    p['usb'] = bm('''
        ..#####..
        ..#.#.#..
        ..#####..
        .#######.
        .#######.
        .#######.
        ..#####..
        ....#....
        ....#....''')
    p['tv'] = bm('''
        .........
        #########
        #.......#
        #.......#
        #.......#
        #.......#
        #########
        .........
        ..#####..''')
    p['sync'] = bm('''
        ..####.#.
        .#....##.
        #....###.
        #........
        .........
        ........#
        .###....#
        .##....#.
        .#.####..''')
    p['swap'] = bm('''
        .........
        ......#..
        ########.
        ......#..
        .........
        ..#......
        .########
        ..#......
        .........''')
    p['refresh'] = bm('''
        .........
        ..####.#.
        .#....##.
        #....###.
        #........
        #.......#
        #.......#
        .#.....#.
        ..#####..''')
    p['restore'] = bm('''
        .........
        #..####..
        #.#....#.
        ##......#
        ....#...#
        #...#...#
        #....#..#
        .#.....#.
        ..#####..''')
    p['replay'] = bm('''
        .........
        #..####..
        #.#....#.
        ##......#
        ...#....#
        #..##...#
        #..#....#
        .#.....#.
        ..#####..''')
    replay_arc = bm('''
        .........
        #..####..
        #.#....#.
        ##......#
        ........#
        #.......#
        #.......#
        .#.....#.
        ..#####..''')
    ten = bm('''
        .........
        .........
        .........
        .........
        ..#.###..
        ..#.#.#..
        ..#.###..
        .........
        .........''')
    p['rewind10'] = bm_or(replay_arc, ten)
    p['forward10'] = bm_or(bm_mirror(replay_arc), ten)
    p['skipNext'] = bm('''
        .........
        ..#....#.
        ..##...#.
        ..###..#.
        ..####.#.
        ..###..#.
        ..##...#.
        ..#....#.
        .........''')
    p['skipPrevious'] = bm_mirror(p['skipNext'])
    p['fastForward'] = bm('''
        .........
        #...#....
        ##..##...
        ###.###..
        ########.
        ###.###..
        ##..##...
        #...#....
        .........''')
    p['fastRewind'] = bm_mirror(p['fastForward'])
    p['shuffle'] = bm('''
        .........
        ......#..
        ##...####
        ..#.#.#..
        ...#.....
        ..#.#.#..
        ##...####
        ......#..
        .........''')
    p['repeat'] = bm('''
        .........
        .....#...
        .######..
        .#...#.#.
        .#.....#.
        .#.#...#.
        ..######.
        ...#.....
        .........''')
    p['repeatOne'] = bm('''
        .........
        .....#...
        .######..
        .#..#..#.
        .#.##..#.
        .#..#..#.
        ..######.
        ...#.....
        .........''')
    p['fileAdd'] = bm('''
        .#####...
        .######..
        .#######.
        .#######.
        .###.###.
        .##...##.
        .###.###.
        .#######.
        .#######.''')
    p['document'] = bm('''
        .#####...
        .######..
        .#######.
        .##...##.
        .#######.
        .##...##.
        .#######.
        .##..###.
        .#######.''')
    p['folder'] = bm('''
        .........
        ####.....
        #####....
        #########
        #########
        #########
        #########
        #########
        .........''')
    p['folderAdd'] = bm('''
        .........
        ####.....
        #####....
        ####.####
        ###...###
        ####.####
        #########
        #########
        .........''')
    p['film'] = bm('''
        #########
        #.#####.#
        #########
        #.#...#.#
        ###...###
        #.#...#.#
        #########
        #.#####.#
        #########''')
    p['exit'] = bm('''
        #####....
        #...#....
        #...#....
        #......#.
        #.#######
        #......#.
        #...#....
        #...#....
        #####....''')
    p['enter'] = bm('''
        ....#####
        ....#...#
        ....#...#
        .....#..#
        #######.#
        .....#..#
        ....#...#
        ....#...#
        ....#####''')
    p['equalizer'] = bm('''
        ....#....
        ..#.#....
        ..#.#.#..
        #.#.#.#.#
        #.#.#.#.#
        #.#.#.#.#
        ..#.#.#..
        ..#.#....
        ....#....''')
    p['download'] = bm('''
        ....#....
        ....#....
        ....#....
        .#..#..#.
        ..#.#.#..
        ...###...
        ....#....
        .........
        #########''')
    p['server'] = bm('''
        .........
        #########
        #.##...##
        #########
        .........
        #########
        #.##...##
        #########
        .........''')
    p['network'] = bm('''
        .........
        ...###...
        ...###...
        ....#....
        .#######.
        .#.....#.
        ###...###
        ###...###
        .........''')
    p['trash'] = bm('''
        ...###...
        #########
        .........
        .#######.
        .##.#.##.
        .##.#.##.
        .##.#.##.
        .#######.
        ..#####..''')
    p['cloud'] = bm('''
        .........
        .........
        ...###...
        ..#####..
        ..#######
        .########
        #########
        .#######.
        .........''')
    p['cloudDone'] = bm('''
        .........
        .........
        ...###...
        ..#####..
        ..####.##
        .##.#.###
        ####.####
        .#######.
        .........''')
    p['cloudOff'] = bm_slash(p['cloud'])
    p['cloudSync'] = bm('''
        .........
        .........
        ...###...
        ..#####..
        ..#..####
        .##.#.###
        ####..###
        .#######.
        .........''')
    p['disc'] = bm('''
        ..#####..
        .#######.
        ##.######
        #.#######
        ####.####
        #########
        #########
        .#######.
        ..#####..''')
    p['image'] = bm('''
        .........
        #########
        #.......#
        #.....#.#
        #...#...#
        #..###..#
        #.#####.#
        #########
        .........''')
    p['speed'] = bm('''
        .........
        ..#####..
        .#.....#.
        #.....#.#
        #....#..#
        #...#...#
        #..###..#
        .#.....#.
        .........''')
    p['sort'] = bm('''
        .........
        .........
        #########
        .........
        ######...
        .........
        ###......
        .........
        .........''')
    p['bag'] = bm('''
        .........
        ...###...
        ..#...#..
        #########
        #########
        #########
        #########
        #########
        .#######.''')
    p['settings'] = bm('''
        ....#....
        .#.###.#.
        ..#####..
        .##...##.
        ###...###
        .##...##.
        ..#####..
        .#.###.#.
        ....#....''')
    p['settingsOutline'] = bm('''
        ....#....
        .#.#.#.#.
        ..#...#..
        .#.###.#.
        #..#.#..#
        .#.###.#.
        ..#...#..
        .#.#.#.#.
        ....#....''')
    p['sdCard'] = bm('''
        ...#####.
        ..##.#.#.
        .###.#.#.
        .#######.
        .#######.
        .#######.
        .#######.
        .#######.
        .#######.''')
    p['save'] = bm('''
        #######..
        ##...###.
        ##...####
        #########
        #########
        ##.....##
        ##.....##
        ##.....##
        #########''')
    p['radioOff'] = bm('''
        ...###...
        .##...##.
        .#.....#.
        #.......#
        #.......#
        #.......#
        .#.....#.
        .##...##.
        ...###...''')
    p['radioOn'] = bm('''
        ...###...
        .##...##.
        .#.....#.
        #..###..#
        #..###..#
        #..###..#
        .#.....#.
        .##...##.
        ...###...''')
    p['playlist'] = bm('''
        .........
        ######...
        .........
        ######.#.
        .......##
        ###....#.
        .....###.
        .....##..
        .........''')
    p['playCircle'] = bm('''
        ..#####..
        .#######.
        ###.#####
        ###..####
        ###...###
        ###..####
        ###.#####
        .#######.
        ..#####..''')
    p['camera'] = bm('''
        .........
        ..###....
        #########
        #######.#
        ###...###
        ###.#.###
        ###...###
        #########
        .........''')
    p['palette'] = bm('''
        ..#####..
        .##.#.##.
        #.#######
        #######.#
        #########
        #########
        #####..##
        .####..#.
        ..####...''')
    p['menu'] = bm('''
        .........
        #########
        .........
        .........
        #########
        .........
        .........
        #########
        .........''')
    p['flame'] = bm('''
        ....#....
        ...##....
        ...###...
        ..####.#.
        .#######.
        .###.###.
        .##...##.
        .##...##.
        ..#####..''')
    p['list'] = bm('''
        .........
        #.#######
        .........
        .........
        #.#######
        .........
        .........
        #.#######
        .........''')
    p['sun'] = bm('''
        ....#....
        .#.....#.
        ...###...
        ..#####..
        #.#####.#
        ..#####..
        ...###...
        .#.....#.
        ....#....''')
    p['moon'] = bm('''
        ...###...
        .###.....
        .##......
        ###......
        ###......
        ###.....#
        .###...##
        .#######.
        ...###...''')
    p['themeAuto'] = bm('''
        ...###...
        .##...##.
        .#..#..#.
        #..#.#..#
        #..###..#
        #..#.#..#
        .#.....#.
        .##...##.
        ...###...''')
    p['contrast'] = bm('''
        ...###...
        .##.###..
        .#..####.
        #...#####
        #...#####
        #...#####
        .#..####.
        .##.###..
        ...###...''')
    p['musicLibrary'] = bm('''
        ..#######
        ..####..#
        #.####.##
        #.####.##
        #.##...##
        #.##..###
        #.#######
        #........
        #######..''')
    p['home'] = bm('''
        ....#....
        ...###...
        ..#####..
        .#######.
        #########
        .#######.
        .###.###.
        .###.###.
        .###.###.''')
    p['homeOutline'] = bm('''
        ....#....
        ...#.#...
        ..#...#..
        .#.....#.
        ##.....##
        .#.....#.
        .#..#..#.
        .#..#..#.
        .#######.''')
    p['help'] = bm('''
        ...###...
        .#######.
        .##...##.
        #####.###
        ####.####
        #########
        .###.###.
        .#######.
        ...###...''')
    p['info'] = bm('''
        ...###...
        .#######.
        .###.###.
        #########
        ####.####
        ####.####
        .###.###.
        .#######.
        ...###...''')
    p['warning'] = bm('''
        ....#....
        ...###...
        ...#.#...
        ..##.##..
        ..##.##..
        .#######.
        .###.###.
        #########
        .........''')
    p['error'] = bm('''
        ...###...
        .#######.
        .###.###.
        ####.####
        ####.####
        #########
        .###.###.
        .#######.
        ...###...''')
    p['grid'] = bm('''
        ####.####
        ####.####
        ####.####
        ####.####
        .........
        ####.####
        ####.####
        ####.####
        ####.####''')
    p['compass'] = bm('''
        ...###...
        .##...##.
        .#....##.
        #....###.
        #...#...#
        #..#....#
        .##.....#
        .##...##.
        ...###...''')
    p['eject'] = bm('''
        .........
        ....#....
        ...###...
        ..#####..
        .#######.
        #########
        .........
        #########
        .........''')
    p['edit'] = bm('''
        .......#.
        ......###
        .....#.#.
        ....###..
        ...###...
        ..###....
        .###.....
        .##......
        #........''')
    p['dice'] = bm('''
        .#######.
        #########
        ##.###.##
        #########
        ####.####
        #########
        ##.###.##
        #########
        .#######.''')
    p['cable'] = bm('''
        .#.......
        ###......
        ###..##..
        .#..#..#.
        .#..#..#.
        .#..#.###
        ..##..###
        .......#.
        .........''')
    p['bolt'] = bm('''
        .....##..
        ....##...
        ...##....
        ..######.
        .....##..
        ....##...
        ...##....
        ..#......
        .........''')
    p['magic'] = bm('''
        ......#..
        .#...###.
        ......#..
        ....##...
        ...##..#.
        ..##.....
        .##......
        ##.......
        .........''')
    p['apps'] = bm('''
        ##.##.##.
        ##.##.##.
        .........
        ##.##.##.
        ##.##.##.
        .........
        ##.##.##.
        ##.##.##.
        .........''')
    p['appsOutline'] = bm('''
        .#..#..#.
        #.##.##.#
        .#..#..#.
        .#..#..#.
        #.##.##.#
        .#..#..#.
        .#..#..#.
        #.##.##.#
        .#..#..#.''')
    p['addToHome'] = bm('''
        .#######.
        .#.....#.
        .#..#..#.
        .#.###.#.
        .#..#..#.
        .#.....#.
        .#######.
        .###.###.
        .#######.''')
    p['appTile'] = bm('''
        .#######.
        #########
        ####.####
        ###...###
        ##.....##
        ###...###
        ###.#.###
        #########
        .#######.''')
    p['speaker'] = bm('''
        .........
        ...#...#.
        ..##.#..#
        ####..#.#
        ####..#.#
        ####..#.#
        ..##.#..#
        ...#...#.
        .........''')
    p['moreVert'] = bm('''
        ...##....
        ...##....
        .........
        ...##....
        ...##....
        .........
        ...##....
        ...##....
        .........''')
    p['dpad'] = bm('''
        ...###...
        ...###...
        ...###...
        #########
        #########
        #########
        ...###...
        ...###...
        ...###...''')
    p['brightness'] = bm('''
        ....#....
        .#.....#.
        ...###...
        ..#.###..
        #.#.###.#
        ..#.###..
        ...###...
        .#.....#.
        ....#....''')
    return p


def pixel_glyphs(names):
    """The pixel set as paths, checked against the moulded set's names and order."""
    p = pixel_bitmaps()
    if list(p) != list(names):
        missing = [n for n in names if n not in p]
        extra = [n for n in p if n not in names]
        raise SystemExit(f'pixel glyphs out of step with the moulded set: missing {missing}, '
                         f'extra {extra}, or a different order. Names and order define the codepoints.')
    return {n: bm_path(s, PIXEL_SHIFT.get(n, (0.0, 0.0))) for n, s in p.items()}


# ---- output ----------------------------------------------------------------------

def build_font(gs):
    names = ['.notdef'] + list(gs)
    fb = FontBuilder(UPM, isTTF=False)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({0xE000 + i: n for i, n in enumerate(gs)})
    charstrings = {}
    pen = T2CharStringPen(UPM, None)
    charstrings['.notdef'] = pen.getCharString()
    for name, path in gs.items():
        pen = T2CharStringPen(UPM, None)
        path = pathops.simplify(path, fix_winding=True)
        path.draw(TransformPen(pen, (SCALE, 0, 0, -SCALE, 0, UPM)))
        charstrings[name] = pen.getCharString()
    fb.setupCFF('DenaIcons', {'FullName': 'Dena Icons'}, charstrings, {})
    fb.setupHorizontalMetrics({n: (UPM, 0) for n in names})
    fb.setupHorizontalHeader(ascent=UPM, descent=0)
    fb.setupNameTable({'familyName': 'Dena Icons', 'styleName': 'Regular',
                       'copyright': 'Dena.emu authors, GPL-3.0-or-later'})
    fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, usWinAscent=UPM, usWinDescent=0)
    fb.setupPost()
    FONT_OUT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(FONT_OUT))


HEADERS = {
    'pixel': [
        '// Dena Icons, pixel style: every glyph is a 9x9 grid of square cells,',
        '// one-cell strokes, the Brutalist look (no Material icons in the',
        '// launcher, settings or menus). Spec: docs/specs/brutalist-ui.md 2.5.',
        '// The rounded moulded set remains via build_icons.py --style moulded.',
    ],
    'moulded': [
        '// Dena Icons: the app\'s own chunky, moulded glyphs (no Material icons in',
        '// the launcher, settings or menus). Spec: docs/specs/ui-look-and-feel.md',
    ],
}


def dart_const(name, i):
    """One constant, wrapped the way dart format wraps it past 80 columns."""
    one = f"  static const IconData {name} = IconData(0x{0xE000 + i:X}, fontFamily: 'DenaIcons');"
    if len(one) <= 80:
        return [one]
    return [f'  static const IconData {name} = IconData(', f'    0x{0xE000 + i:X},',
            "    fontFamily: 'DenaIcons',", '  );']


def build_dart(gs, style):
    lines = [
        '// SPDX-License-Identifier: GPL-3.0-or-later',
        '// GENERATED by tools/icons/build_icons.py. Do not edit by hand.',
        *HEADERS[style],
        "import 'package:flutter/widgets.dart';",
        '',
        '/// The Dena Icons font: use these with [Icon] like Material icons.',
        'abstract final class DenaIcons {',
    ]
    for i, name in enumerate(gs):
        lines += dart_const(name, i)
    lines += [
        '',
        '  /// Every glyph by name, for the icon sheet test.',
        '  static const Map<String, IconData> all = {',
        *[f"    '{n}': {n}," for n in gs],
        '  };',
        '}',
        '',
    ]
    DART_OUT.write_text('\n'.join(lines))
    # Keep the generated file in the repo's dart format, if dart is on PATH.
    import shutil, subprocess
    if shutil.which('dart'):
        subprocess.run(['dart', 'format', str(DART_OUT)], check=False, capture_output=True)


def preview(gs, out):
    from PIL import Image, ImageDraw, ImageFont
    cols, cell = 10, 96
    rows = (len(gs) + cols - 1) // cols
    img = Image.new('RGB', (cols * cell, rows * cell), (32, 32, 36))
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(str(FONT_OUT), 56)
    lab = ImageFont.load_default()
    for i, n in enumerate(gs):
        x, y = (i % cols) * cell, (i // cols) * cell
        d.text((x + 20, y + 8), chr(0xE000 + i), font=f, fill=(241, 196, 15))
        d.text((x + 4, y + cell - 14), n[:15], font=lab, fill=(200, 198, 206))
    img.save(out)


def main():
    ap = argparse.ArgumentParser(description='Build the Dena Icons font and Dart constants.')
    ap.add_argument('--style', choices=('pixel', 'moulded'), default='pixel',
                    help='drawing style: pixel (9x9 cells, default) or moulded (rounded)')
    ap.add_argument('--preview', help='also write a PNG contact sheet to this path')
    a = ap.parse_args()
    gs = glyphs()  # the moulded set always runs: it defines the names and codepoints
    if a.style == 'pixel':
        gs = pixel_glyphs(list(gs))
    build_font(gs)
    build_dart(gs, a.style)
    if a.preview:
        preview(gs, a.preview)
    print(f'{len(gs)} {a.style} glyphs -> {FONT_OUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
