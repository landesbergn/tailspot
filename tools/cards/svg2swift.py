#!/usr/bin/env python3
"""
svg2swift.py — convert a potrace SVG silhouette into SwiftUI `Path` code.

STAGE-2b CARD-STYLE SPIKE (feat/card-style-spike). This is the bridge from
"traced real reference imagery" to the procedural card-art primitives in
CardSilhouettes.swift. It reads the SVG that `potrace -s` produced from a
thresholded reference image, and emits a `nonisolated struct <Name>Silhouette:
Shape` whose `path(in:)` reproduces the trace, normalized into the same unit
design space the spike harness already uses.

Pipeline (per aircraft, see Makefile-style commands in SOURCES.md):
    reference image  ->  ImageMagick threshold/flood-fill  ->  clean B/W bitmap
                     ->  potrace -s  ->  SVG (cubic-bezier path data)
                     ->  svg2swift.py  ->  Swift Shape

Design-space contract (matches CardSilhouettes.PlanFormMap):
    - The shape draws NOSE-UP: y = 0 is the nose, y = 1 is the tail.
    - x is centered: x = 0 is the centerline, x in [-1, +1] spans full width.
    - We map the trace's bounding box into this space, preserving the trace's
      own aspect ratio is NOT our job here — the host (SilhouetteKind.aspect)
      letterboxes. We normalize x to [-1,1] by the HALF-width that makes the
      widest point reach +/-1, and y to [0,1] by height. The result is a shape
      that fills a unit-ish box; PlanFormMap then fits it to the card slot.

Why parse the SVG (not potrace's GeoJSON): the brief calls for cubic beziers
mapping 1:1 onto SwiftUI `addCurve`, so the rendered card keeps potrace's
smooth outline instead of a flattened polygon. potrace emits only M/m, L/l,
C/c, and z in its SVG path, plus a group transform of the form
    translate(0, H) scale(0.1, -0.1)
which we apply so the emitted coordinates are already in final image space
(y-down). We then flip y so nose-up maps to y=0 (the reference images are
fed in already nose-up, i.e. nose at the TOP / small image-y).

Usage:
    python3 svg2swift.py work/c172.svg --name C172 > /tmp/c172.swift
    # or emit several into one file via --append / a driver script.
"""

import sys
import re
import argparse
import xml.etree.ElementTree as ET


# ---------------------------------------------------------------------------
# SVG path tokenizer / parser (potrace subset: M m L l C c Z z, plus H/V/S
# for safety). Produces a list of subpaths, each a list of segments. Each
# segment is ('move', (x,y)) | ('line', (x,y)) | ('cubic', (c1,c2,end)) |
# ('close',). All coordinates ABSOLUTE in path-local space (pre-transform).
# ---------------------------------------------------------------------------

_NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
_CMD = re.compile(r'[MmLlHhVvCcSsQqTtAaZz]')


def _tokenize(d):
    """Yield (command_letter, [float args]) in document order."""
    i = 0
    n = len(d)
    cur_cmd = None
    while i < n:
        ch = d[i]
        if ch.isspace() or ch == ',':
            i += 1
            continue
        if _CMD.match(ch):
            cur_cmd = ch
            i += 1
            # Z/z take no args
            if ch in 'Zz':
                yield (ch, [])
                cur_cmd = None
            continue
        # Otherwise we're reading numbers for the current command.
        m = _NUM.match(d, i)
        if not m:
            i += 1
            continue
        # gather the full arg list for this command instance
        args = []
        while True:
            m = _NUM.match(d, i)
            if not m:
                break
            args.append(float(m.group()))
            i = m.end()
            while i < n and (d[i].isspace() or d[i] == ','):
                i += 1
            # stop if next char is a command letter
            if i < n and _CMD.match(d[i]):
                break
        yield (cur_cmd, args)


# how many args each command consumes per element
_ARGC = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2}


def parse_path(d):
    """Parse path data `d` into a list of subpaths of absolute segments."""
    subpaths = []
    cur = None            # current subpath list
    cx = cy = 0.0         # current point
    sx = sy = 0.0         # subpath start (for Z)
    prev_cubic_c2 = None  # for S smooth (unused by potrace but safe)

    def start_subpath():
        nonlocal cur
        cur = []
        subpaths.append(cur)

    for cmd, args in _tokenize(d):
        rel = cmd.islower()
        C = cmd.upper()
        if C == 'M':
            # first pair is moveto, subsequent pairs are implicit linetos
            for k in range(0, len(args), 2):
                x, y = args[k], args[k + 1]
                if rel:
                    x += cx
                    y += cy
                if k == 0:
                    start_subpath()
                    cur.append(('move', (x, y)))
                    sx, sy = x, y
                else:
                    cur.append(('line', (x, y)))
                cx, cy = x, y
        elif C == 'L':
            for k in range(0, len(args), 2):
                x, y = args[k], args[k + 1]
                if rel:
                    x += cx
                    y += cy
                cur.append(('line', (x, y)))
                cx, cy = x, y
        elif C == 'H':
            for x in args:
                if rel:
                    x += cx
                cur.append(('line', (x, cy)))
                cx = x
        elif C == 'V':
            for y in args:
                if rel:
                    y += cy
                cur.append(('line', (cx, y)))
                cy = y
        elif C == 'C':
            for k in range(0, len(args), 6):
                x1, y1, x2, y2, x, y = args[k:k + 6]
                if rel:
                    x1 += cx; y1 += cy
                    x2 += cx; y2 += cy
                    x += cx;  y += cy
                cur.append(('cubic', ((x1, y1), (x2, y2), (x, y))))
                prev_cubic_c2 = (x2, y2)
                cx, cy = x, y
        elif C == 'S':
            for k in range(0, len(args), 4):
                x2, y2, x, y = args[k:k + 4]
                if rel:
                    x2 += cx; y2 += cy
                    x += cx;  y += cy
                # reflect previous c2 for first control point
                if prev_cubic_c2 is not None:
                    x1 = 2 * cx - prev_cubic_c2[0]
                    y1 = 2 * cy - prev_cubic_c2[1]
                else:
                    x1, y1 = cx, cy
                cur.append(('cubic', ((x1, y1), (x2, y2), (x, y))))
                prev_cubic_c2 = (x2, y2)
                cx, cy = x, y
        elif C == 'Z':
            if cur:
                cur.append(('close',))
            cx, cy = sx, sy
    return subpaths


# ---------------------------------------------------------------------------
# Apply the potrace group transform and load the path(s).
# ---------------------------------------------------------------------------

def load_svg(path):
    tree = ET.parse(path)
    root = tree.getroot()
    ns = {'svg': 'http://www.w3.org/2000/svg'}

    # group transform: translate(tx,ty) scale(sx,sy)
    tx = ty = 0.0
    scx = scy = 1.0
    g = root.find('svg:g', ns)
    if g is not None and g.get('transform'):
        t = g.get('transform')
        mt = re.search(r'translate\(([-\d.]+)[ ,]+([-\d.]+)\)', t)
        if mt:
            tx, ty = float(mt.group(1)), float(mt.group(2))
        ms = re.search(r'scale\(([-\d.]+)(?:[ ,]+([-\d.]+))?\)', t)
        if ms:
            scx = float(ms.group(1))
            scy = float(ms.group(2)) if ms.group(2) else scx

    def xform(p):
        return (p[0] * scx + tx, p[1] * scy + ty)

    subpaths = []
    container = g if g is not None else root
    for pe in container.findall('.//svg:path', ns):
        for sp in parse_path(pe.get('d', '')):
            out = []
            for seg in sp:
                if seg[0] == 'move' or seg[0] == 'line':
                    out.append((seg[0], xform(seg[1])))
                elif seg[0] == 'cubic':
                    c1, c2, e = seg[1]
                    out.append(('cubic', (xform(c1), xform(c2), xform(e))))
                elif seg[0] == 'close':
                    out.append(('close',))
            subpaths.append(out)
    return subpaths


# ---------------------------------------------------------------------------
# Normalize into the nose-up unit design space and emit Swift.
# ---------------------------------------------------------------------------

def all_points(subpaths):
    pts = []
    for sp in subpaths:
        for seg in sp:
            if seg[0] in ('move', 'line'):
                pts.append(seg[1])
            elif seg[0] == 'cubic':
                pts.extend(seg[1])
    return pts


def normalize(subpaths, flip_y=True):
    """Map trace coords -> design space: x in [-1,1] centered, y in [0,1].

    flip_y: potrace's transform yields y-up final coords (the scale has a
    negative y). The reference images are nose-up = nose at small image-y.
    We want design y=0 at the nose, increasing toward the tail, so we flip
    so the geometric top of the trace becomes y=0.
    """
    pts = all_points(subpaths)
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    w = maxx - minx
    h = maxy - miny
    cx = (minx + maxx) / 2.0
    half = w / 2.0 if w else 1.0

    def nx(x):
        return (x - cx) / half          # -> [-1, 1]

    def ny(y):
        t = (y - miny) / h if h else 0.0  # [0,1], 0 at top of image
        # potrace final coords are y-up; "top of image" is the LARGER final-y.
        # To make design-y=0 the nose (image top), invert when flip_y.
        return (1.0 - t) if flip_y else t

    def conv(p):
        return (nx(p[0]), ny(p[1]))

    out = []
    for sp in subpaths:
        nsp = []
        for seg in sp:
            if seg[0] in ('move', 'line'):
                nsp.append((seg[0], conv(seg[1])))
            elif seg[0] == 'cubic':
                c1, c2, e = seg[1]
                nsp.append(('cubic', (conv(c1), conv(c2), conv(e))))
            elif seg[0] == 'close':
                nsp.append(('close',))
        out.append(nsp)
    return out


def fmt(v):
    return f"{v:.4f}"


def emit_swift(subpaths, name, aspect, label, source_note):
    lines = []
    lines.append(f"// MARK: - {name} (traced)")
    lines.append("")
    for ln in source_note.splitlines():
        lines.append(f"/// {ln}")
    lines.append(f"nonisolated struct {name}Silhouette: Shape {{")
    lines.append("    nonisolated func path(in rect: CGRect) -> Path {")
    lines.append(f"        let m = PlanFormMap(rect: rect, aspect: {fmt(aspect)})")
    lines.append("        var p = Path()")
    for sp in subpaths:
        for seg in sp:
            if seg[0] == 'move':
                x, y = seg[1]
                lines.append(f"        p.move(to: m.pt({fmt(x)}, {fmt(y)}))")
            elif seg[0] == 'line':
                x, y = seg[1]
                lines.append(f"        p.addLine(to: m.pt({fmt(x)}, {fmt(y)}))")
            elif seg[0] == 'cubic':
                c1, c2, e = seg[1]
                lines.append(
                    f"        p.addCurve(to: m.pt({fmt(e[0])}, {fmt(e[1])}), "
                    f"control1: m.pt({fmt(c1[0])}, {fmt(c1[1])}), "
                    f"control2: m.pt({fmt(c2[0])}, {fmt(c2[1])}))"
                )
            elif seg[0] == 'close':
                lines.append("        p.closeSubpath()")
    lines.append("        return p")
    lines.append("    }")
    lines.append("}")
    return "\n".join(lines)


def count_controls(subpaths):
    n = 0
    for sp in subpaths:
        for seg in sp:
            if seg[0] == 'cubic':
                n += 3
            elif seg[0] in ('move', 'line'):
                n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('svg')
    ap.add_argument('--name', required=True, help='Shape base name, e.g. C172')
    ap.add_argument('--aspect', type=float, default=1.0)
    ap.add_argument('--label', default='')
    ap.add_argument('--source', default='Traced from a license-clean reference.')
    ap.add_argument('--no-flip', action='store_true',
                    help='do not flip y (use if reference was nose-down)')
    ap.add_argument('--stats', action='store_true',
                    help='print control-point count to stderr')
    args = ap.parse_args()

    subpaths = load_svg(args.svg)
    norm = normalize(subpaths, flip_y=not args.no_flip)
    if args.stats:
        print(f"[{args.name}] subpaths={len(norm)} controls={count_controls(norm)}",
              file=sys.stderr)
    print(emit_swift(norm, args.name, args.aspect, args.label, args.source))


if __name__ == '__main__':
    main()
