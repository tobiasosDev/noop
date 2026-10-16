#!/usr/bin/env python3
"""NOOP brand mark: the one source every logo file in the repository is generated from.

The mark is the arch of a lowercase n with a dot underneath it: your data, under its own roof.
It is one flat shape in one colour, drawn on a 64-unit grid. The wordmark is "noop" set in
Hanken Grotesk SemiBold (SIL Open Font License, already bundled in StrandDesign) and stored
here as outlines, so no consumer needs the font.

    python3 Tools/noop_brand.py           regenerate every derived file
    python3 Tools/noop_brand.py --check   exit 1 if any derived file is out of date

Derived files (all listed in OUTPUTS, all pinned by Tools/test_noop_brand.py):
  - Swift path data for BrandMark / BrandLockup (StrandDesign)
  - Android vector drawables: launcher foreground, backgrounds, monochrome, in-app mark + lockup
  - app icons: iOS (default + the "AppIcon-Navy" alternate), macOS, watchOS
  - docs/assets: mark, lockup (black and white), app icon, README banner

PNG files are rasterised here (pure standard library, exact per-row span coverage), so the icons
can be rebuilt on any machine without Pillow or a font. Change a constant, run the script,
commit what it writes.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------------------------
# Geometry (64-unit grid, y down). The bounding box is 11…53 × 10…54, centred on (32, 32).

ARCH_CX, ARCH_CY = 32.0, 31.0      # centre of the arch's half-circles
ARCH_R = 21.0                      # outer radius
ARCH_W = 10.5                      # stroke: inner radius is ARCH_R - ARCH_W
ARCH_BOTTOM = 54.0                 # where both legs end
DOT_CX, DOT_CY, DOT_R = 32.0, 44.5, 6.5

# Colours. The mark itself is always ONE colour; these only fill tiles behind it.
BRICK = "#B4512E"   # app icon tile
CREAM = "#F6F0E6"   # mark on the app icon tile
NAVY = "#0F1B33"    # the alternate ("AppIcon-Navy") tile
INK = "#0A0A0A"

# "noop" in Hanken Grotesk, wght 600, at size 100 (baseline y = 0, y down). Outlined with fontkit
# from Packages/StrandDesign/Sources/StrandDesign/Resources/Fonts/HankenGrotesk-Variable.ttf.
WORDMARK_CAP = 69.7
WORDMARK_XHEIGHT = 49.3
WORDMARK_PATH = (
    "M6.5 0L6.5 -49.3L17.6 -49.3L17.6 -38.4L15.6 -37.9Q16.9 -42.2 19.4 -44.9Q21.9 -47.6 25.25 -48.9"
    "Q28.6 -50.2 32.3 -50.2Q40.6 -50.2 45.25 -45.45Q49.9 -40.7 49.9 -31.9L49.9 0L38.8 0L38.8 -27.8"
    "Q38.8 -34.4 36.4 -37.5Q34 -40.6 29 -40.6Q25.3 -40.6 22.75 -38.85Q20.2 -37.1 18.9 -33.4"
    "Q17.6 -29.7 17.6 -24L17.6 0ZM84.56 0.9Q77.56 0.9 71.96 -2.4Q66.36 -5.7 63.21 -11.5"
    "Q60.06 -17.3 60.06 -24.7Q60.06 -32.1 63.21 -37.9Q66.36 -43.7 71.91 -46.95"
    "Q77.46 -50.2 84.56 -50.2Q91.76 -50.2 97.21 -46.95Q102.66 -43.7 105.86 -37.9"
    "Q109.06 -32.1 109.06 -24.7Q109.06 -17.3 105.91 -11.5Q102.76 -5.7 97.21 -2.4Q91.66 0.9 84.56 0.9Z"
    "M84.66 -8.9Q88.76 -8.9 91.76 -10.8Q94.76 -12.7 96.36 -16.3Q97.96 -19.9 97.96 -24.7"
    "Q97.96 -29.6 96.36 -33.15Q94.76 -36.7 91.76 -38.6Q88.76 -40.5 84.66 -40.5"
    "Q80.36 -40.5 77.36 -38.55Q74.36 -36.6 72.76 -33.1Q71.16 -29.6 71.16 -24.7"
    "Q71.16 -19.9 72.76 -16.3Q74.36 -12.7 77.36 -10.8Q80.36 -8.9 84.66 -8.9ZM141.94 0.9"
    "Q134.94 0.9 129.34 -2.4Q123.74 -5.7 120.59 -11.5Q117.44 -17.3 117.44 -24.7"
    "Q117.44 -32.1 120.59 -37.9Q123.74 -43.7 129.29 -46.95Q134.84 -50.2 141.94 -50.2"
    "Q149.14 -50.2 154.59 -46.95Q160.04 -43.7 163.24 -37.9Q166.44 -32.1 166.44 -24.7"
    "Q166.44 -17.3 163.29 -11.5Q160.14 -5.7 154.59 -2.4Q149.04 0.9 141.94 0.9ZM142.04 -8.9"
    "Q146.14 -8.9 149.14 -10.8Q152.14 -12.7 153.74 -16.3Q155.34 -19.9 155.34 -24.7"
    "Q155.34 -29.6 153.74 -33.15Q152.14 -36.7 149.14 -38.6Q146.14 -40.5 142.04 -40.5"
    "Q137.74 -40.5 134.74 -38.55Q131.74 -36.6 130.14 -33.1Q128.54 -29.6 128.54 -24.7"
    "Q128.54 -19.9 130.14 -16.3Q131.74 -12.7 134.74 -10.8Q137.74 -8.9 142.04 -8.9ZM177.12 20.4"
    "L177.12 -49.3L188.12 -49.3L188.12 -35.6L185.32 -35.5Q186.62 -40.9 189.17 -44.1"
    "Q191.72 -47.3 195.27 -48.75Q198.82 -50.2 202.82 -50.2Q209.42 -50.2 214.22 -46.85"
    "Q219.02 -43.5 221.67 -37.7Q224.32 -31.9 224.32 -24.6Q224.32 -16.7 221.42 -10.95"
    "Q218.52 -5.2 213.67 -2.15Q208.82 0.9 202.82 0.9Q198.62 0.9 195.07 -0.7Q191.52 -2.3 189.07 -5.5"
    "Q186.62 -8.7 185.62 -13.3L188.12 -13.8L188.12 20.4ZM200.12 -9.2Q204.02 -9.2 206.97 -11.1"
    "Q209.92 -13 211.52 -16.5Q213.12 -20 213.12 -24.6Q213.12 -29.2 211.52 -32.7"
    "Q209.92 -36.2 206.97 -38.1Q204.02 -40 200.12 -40Q196.22 -40 193.27 -38.1"
    "Q190.32 -36.2 188.72 -32.7Q187.12 -29.2 187.12 -24.6Q187.12 -20 188.72 -16.55"
    "Q190.32 -13.1 193.27 -11.15Q196.22 -9.2 200.12 -9.2Z"
)


# ---------------------------------------------------------------------------------------------
# Paths

def _n(v: float) -> str:
    """Compact number: at most two decimals, no trailing zeros, no '-0'."""
    s = f"{round(v, 2):.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def mark_path(scale: float = 1.0, tx: float = 0.0, ty: float = 0.0) -> str:
    """The mark as SVG path data: arcs and lines only, so it is exact at every size.

    Coordinates are rounded to two decimals; each half-circle's radius is then taken as exactly
    half its rounded chord. Rounding the radius on its own would make it a hair short of the chord,
    and a renderer then has to grow it, which moves the arc's centre and flattens the apex.
    """
    def x(v: float) -> float:
        return round(v * scale + tx, 2)

    def y(v: float) -> float:
        return round(v * scale + ty, 2)

    def r3(v: float) -> str:
        s = f"{v:.3f}".rstrip("0").rstrip(".")
        return "0" if s in ("-0", "") else s

    def half_circle(x0: float, x1: float, cy: float, sweep: int, large: int = 0) -> str:
        r = r3(abs(x1 - x0) / 2)
        return f"A{r} {r} 0 {large} {sweep} {_n(x1)} {_n(cy)}"

    lo, ro = x(ARCH_CX - ARCH_R), x(ARCH_CX + ARCH_R)
    li, ri = x(ARCH_CX - ARCH_R + ARCH_W), x(ARCH_CX + ARCH_R - ARCH_W)
    cy, bottom = y(ARCH_CY), y(ARCH_BOTTOM)
    dl, dr, dcy = x(DOT_CX - DOT_R), x(DOT_CX + DOT_R), y(DOT_CY)
    return (
        f"M{_n(lo)} {_n(bottom)}L{_n(lo)} {_n(cy)}" + half_circle(lo, ro, cy, 1)
        + f"L{_n(ro)} {_n(bottom)}L{_n(ri)} {_n(bottom)}L{_n(ri)} {_n(cy)}" + half_circle(ri, li, cy, 0)
        + f"L{_n(li)} {_n(bottom)}Z"
        + f"M{_n(dl)} {_n(dcy)}" + half_circle(dl, dr, dcy, 0, 1) + half_circle(dr, dl, dcy, 0, 1) + "Z"
    )


MARK_BOX = (ARCH_CX - ARCH_R, ARCH_CY - ARCH_R, ARCH_CX + ARCH_R, ARCH_BOTTOM)   # x0, y0, x1, y1

_TOKEN = re.compile(r"[MLHVQCZmlhvqcz]|-?\d*\.?\d+(?:e-?\d+)?")


def transform_path(d: str, scale: float, tx: float, ty: float) -> str:
    """Scale + translate absolute M/L/H/V/Q/C/Z path data (what the font outliner emits)."""
    out, cmd, args = [], None, []
    arity = {"M": 2, "L": 2, "Q": 4, "C": 6, "H": 1, "V": 1, "Z": 0}

    def flush() -> None:
        if cmd is None:
            return
        if cmd == "Z":
            out.append("Z")
            return
        k = arity[cmd]
        for i in range(0, len(args), k):
            chunk = args[i:i + k]
            if cmd == "H":
                vals = [chunk[0] * scale + tx]
            elif cmd == "V":
                vals = [chunk[0] * scale + ty]
            else:
                vals = [v * scale + (tx if j % 2 == 0 else ty) for j, v in enumerate(chunk)]
            out.append(cmd + " ".join(_n(v) for v in vals))

    for tok in _TOKEN.findall(d):
        if tok.isalpha():
            if tok.islower():
                raise ValueError("relative path commands are not supported: " + tok)
            flush()
            cmd, args = tok, []
        else:
            args.append(float(tok))
    flush()
    return "".join(out)


def path_box(d: str) -> tuple[float, float, float, float]:
    """Bounding box of absolute M/L/Q/C path data (control points included; fine for layout)."""
    nums = [float(t) for t in _TOKEN.findall(d) if not t.isalpha()]
    xs, ys = nums[0::2], nums[1::2]
    return min(xs), min(ys), max(xs), max(ys)


# ---------------------------------------------------------------------------------------------
# Lockups. Horizontal: mark ≈ 1.3 × cap height, gap 0.4 × cap, mark centred on the x-height
# (the word is lowercase). Stacked: mark 2.2 × cap above the word, gap 0.6 × cap.

def lockup(stacked: bool = False) -> tuple[str, float, float]:
    """(path data, width, height) with the lockup's box starting at (0, 0)."""
    word = WORDMARK_PATH
    wx0, wy0, wx1, wy1 = path_box(word)
    mx0, my0, mx1, my1 = MARK_BOX
    mw, mh = mx1 - mx0, my1 - my0
    cap = WORDMARK_CAP
    if not stacked:
        s = 1.3 * cap / mh
        mid = -WORDMARK_XHEIGHT / 2
        m_tx, m_ty = -mx0 * s, mid - (my0 + my1) / 2 * s
        w_tx = mw * s + 0.4 * cap - wx0
        top = min(mid - mh * s / 2, wy0)
        bottom = max(mid + mh * s / 2, wy1)
        width = mw * s + 0.4 * cap + (wx1 - wx0)
        left = 0.0
        w_ty = 0.0
    else:
        s = 2.2 * cap / mh
        gw = wx1 - wx0
        top = wy0 - 0.6 * cap - mh * s
        cx = wx0 + gw / 2
        m_tx, m_ty = cx - (mx0 + mx1) / 2 * s, top - my0 * s
        width = max(gw, mw * s)
        left = cx - width / 2
        bottom = wy1
        w_tx = w_ty = 0.0
    d = mark_path(s, m_tx - left, m_ty - top) + transform_path(word, 1.0, w_tx - left, w_ty - top)
    return d, round(width, 2), round(bottom - top, 2)


# ---------------------------------------------------------------------------------------------
# Rasteriser: exact horizontal coverage per sub-row, SS sub-rows per pixel.

def _merge(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    spans = sorted(s for s in spans if s[1] > s[0])
    out: list[tuple[float, float]] = []
    for a, b in spans:
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def _half_width(r: float, dy: float) -> float:
    return math.sqrt(r * r - dy * dy) if abs(dy) < r else -1.0


def mark_spans(y: float) -> list[tuple[float, float]]:
    """Horizontal spans of the mark on grid row y."""
    spans: list[tuple[float, float]] = []
    dy = y - ARCH_CY
    if ARCH_CY - ARCH_R < y <= ARCH_BOTTOM:
        ho = ARCH_R if dy >= 0 else _half_width(ARCH_R, dy)
        ri = ARCH_R - ARCH_W
        hi = ri if dy >= 0 else _half_width(ri, dy)
        if hi > 0:
            spans += [(ARCH_CX - ho, ARCH_CX - hi), (ARCH_CX + hi, ARCH_CX + ho)]
        elif ho > 0:
            spans.append((ARCH_CX - ho, ARCH_CX + ho))
    hd = _half_width(DOT_R, y - DOT_CY)
    if hd > 0:
        spans.append((DOT_CX - hd, DOT_CX + hd))
    return _merge(spans)


def _coverage_row(span_fn, row: int, width: int, ss: int) -> list[float]:
    diff = [0.0] * (width + 1)
    part = [0.0] * (width + 1)
    for k in range(ss):
        for a, b in span_fn(row + (k + 0.5) / ss):
            a, b = max(0.0, a), min(float(width), b)
            if b <= a:
                continue
            ia, ib = int(a), int(b)
            if ia == ib:
                part[ia] += b - a
                continue
            part[ia] += ia + 1 - a
            diff[ia + 1] += 1.0
            diff[ib] -= 1.0
            part[ib] += b - ib
    out, run = [], 0.0
    for x in range(width):
        run += diff[x]
        out.append(min(1.0, (run + part[x]) / ss))
    return out


def _rgb(hexstr: str) -> tuple[int, int, int]:
    h = hexstr.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def icon_png(size: int, bg: str, fg: str, mark_fraction: float, ss: int = 8) -> bytes:
    """A full-bleed square tile (the OS applies its own mask) with the mark centred on it.

    `mark_fraction` is the mark's larger side as a fraction of the tile edge.
    """
    mx0, my0, mx1, my1 = MARK_BOX
    s = size * mark_fraction / max(mx1 - mx0, my1 - my0)
    ox = size / 2 - (mx0 + mx1) / 2 * s
    oy = size / 2 - (my0 + my1) / 2 * s

    def spans(ypx: float) -> list[tuple[float, float]]:
        return [(a * s + ox, b * s + ox) for a, b in mark_spans((ypx - oy) / s)]

    br, bgc, bb = _rgb(bg)
    fr, fgc, fb = _rgb(fg)
    raw = bytearray()
    for row in range(size):
        raw.append(0)
        for c in _coverage_row(spans, row, size, ss):
            raw += bytes((round(br + (fr - br) * c), round(bgc + (fgc - bgc) * c), round(bb + (fb - bb) * c)))
    return _png(size, size, bytes(raw))


def _png(w: int, h: int, raw: bytes) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)   # 8-bit RGB, no alpha (App Store rule for iOS)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


# ---------------------------------------------------------------------------------------------
# Derived text files

GENERATED = "Generated by Tools/noop_brand.py. Do not edit by hand; change the script and re-run it."

ICON_MARK_FRACTION = 36 / 64   # the mark's larger side on an app tile


def _svg(viewbox: str, body: str, w: float | None = None, h: float | None = None) -> str:
    size = f' width="{_n(w)}" height="{_n(h)}"' if w else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}"{size}>'
            f"<!-- {GENERATED} -->{body}</svg>\n")


def swift_paths() -> str:
    d_h, w_h, h_h = lockup()
    return f"""// {GENERATED}
//
// The NOOP mark (the arch of an n with your data underneath) and the "noop" lockup as SVG path data.
// BrandMark and BrandLockup draw these through SVGPathParser, so the app, the icons and the README all
// come from the same numbers.

import CoreGraphics

enum BrandPaths {{
    static let markViewBox = CGRect(x: 0, y: 0, width: 64, height: 64)
    static let mark = "{mark_path()}"

    static let lockupViewBox = CGRect(x: 0, y: 0, width: {w_h}, height: {h_h})
    static let lockup = "{d_h}"
}}
"""


def _vector(w_dp: float, h_dp: float, vw: float, vh: float, paths: str, comment: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- {comment}
     {GENERATED} -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="{_n(w_dp)}dp" android:height="{_n(h_dp)}dp"
    android:viewportWidth="{_n(vw)}" android:viewportHeight="{_n(vh)}">
{paths}
</vector>
"""


def _adaptive_mark(fill: str) -> str:
    # Adaptive icons are 108 dp with a 72 dp visible area: the mark takes the same share of the
    # visible area as it does of the iOS tile.
    k = 72 * ICON_MARK_FRACTION / (MARK_BOX[3] - MARK_BOX[1])
    mx0, my0, mx1, my1 = MARK_BOX
    d = mark_path(k, 54 - (mx0 + mx1) / 2 * k, 54 - (my0 + my1) / 2 * k)
    return f'    <path android:fillColor="{fill}" android:pathData="{d}"/>'


def text_outputs() -> dict[str, str]:
    d_h, w_h, h_h = lockup()
    d_v, w_v, h_v = lockup(stacked=True)
    vb_h = f"0 0 {_n(w_h)} {_n(h_h)}"
    vb_v = f"0 0 {_n(w_v)} {_n(h_v)}"
    res = "android/app/src/main/res/drawable/"
    tile = (f'<rect width="64" height="64" rx="14.3" fill="{BRICK}"/>'
            f'<path fill="{CREAM}" d="{_tile_mark_path(64)}"/>')
    # README banner: the lockup centred on the brick ground.
    bw, bh = 1280.0, 360.0
    bs = 150 / h_h
    banner = (f'<rect width="{_n(bw)}" height="{_n(bh)}" fill="{BRICK}"/>'
              f'<path fill="{CREAM}" transform="translate({_n((bw - w_h * bs) / 2)} {_n((bh - h_h * bs) / 2)}) '
              f'scale({_n(bs)})" d="{d_h}"/>')
    return {
        "Packages/StrandDesign/Sources/StrandDesign/BrandPaths.swift": swift_paths(),
        res + "ic_launcher_foreground.xml": _vector(108, 108, 108, 108, _adaptive_mark(CREAM),
                                                    "Adaptive launcher foreground: the NOOP mark inside the safe zone."),
        res + "ic_launcher_monochrome.xml": _vector(108, 108, 108, 108, _adaptive_mark("#FFFFFF"),
                                                    "Themed-icon layer: the same mark as one silhouette."),
        res + "ic_launcher_background.xml": _vector(108, 108, 108, 108,
                                                    f'    <path android:fillColor="{BRICK}" android:pathData="M0 0H108V108H0Z"/>',
                                                    "Adaptive launcher background: the brick tile."),
        res + "ic_launcher_background_navy.xml": _vector(108, 108, 108, 108,
                                                         f'    <path android:fillColor="{NAVY}" android:pathData="M0 0H108V108H0Z"/>',
                                                         "Background of the alternate navy launcher icon."),
        res + "ic_noop_mark.xml": _vector(24, 24, 64, 64, f'    <path android:fillColor="#FFFFFF" android:pathData="{mark_path()}"/>',
                                          "The NOOP mark for in-app use; tint it at the call site."),
        res + "ic_noop_lockup.xml": _vector(w_h / h_h * 24, 24, w_h, h_h,
                                            f'    <path android:fillColor="#FFFFFF" android:pathData="{d_h}"/>',
                                            "The NOOP lockup (mark + noop) for in-app headers; tint it at the call site."),
        "docs/assets/noop-mark.svg": _svg("0 0 64 64", f'<path fill="{INK}" d="{mark_path()}"/>', 256, 256),
        "docs/assets/noop-lockup.svg": _svg(vb_h, f'<path fill="{INK}" d="{d_h}"/>'),
        "docs/assets/noop-lockup-white.svg": _svg(vb_h, f'<path fill="#FFFFFF" d="{d_h}"/>'),
        "docs/assets/noop-lockup-stacked.svg": _svg(vb_v, f'<path fill="{INK}" d="{d_v}"/>'),
        "docs/assets/noop-icon.svg": _svg("0 0 64 64", tile, 256, 256),
        "docs/assets/banner.svg": _svg(f"0 0 {_n(bw)} {_n(bh)}", banner, bw, bh),
    }


def _tile_mark_path(edge: float) -> str:
    mx0, my0, mx1, my1 = MARK_BOX
    s = edge * ICON_MARK_FRACTION / max(mx1 - mx0, my1 - my0)
    return mark_path(s, edge / 2 - (mx0 + mx1) / 2 * s, edge / 2 - (my0 + my1) / 2 * s)


def png_outputs() -> dict[str, tuple[int, str, str]]:
    """path -> (edge px, tile colour, mark colour)."""
    out = {
        "StrandiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png": (1024, BRICK, CREAM),
        "StrandiOS/Resources/Assets.xcassets/AppIcon-Navy.appiconset/icon_1024.png": (1024, NAVY, CREAM),
        "NOOPWatch/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png": (1024, BRICK, CREAM),
    }
    mac = "Strand/Resources/Assets.xcassets/AppIcon.appiconset/"
    for pt in (16, 32, 128, 256, 512):
        out[f"{mac}icon_{pt}x{pt}.png"] = (pt, BRICK, CREAM)
        out[f"{mac}icon_{pt}x{pt}@2x.png"] = (pt * 2, BRICK, CREAM)
    return out


MANIFEST = "Tools/noop_brand_manifest.json"


def fingerprint() -> str:
    """Changes whenever anything that feeds the PNGs changes."""
    src = json.dumps([MARK_BOX, ARCH_W, DOT_CX, DOT_CY, DOT_R, ICON_MARK_FRACTION,
                      sorted(png_outputs().items())], sort_keys=True)
    return hashlib.sha256(src.encode()).hexdigest()


def build() -> dict[str, bytes]:
    files = {k: v.encode() for k, v in text_outputs().items()}
    for path, (edge, bg, fg) in png_outputs().items():
        files[path] = icon_png(edge, bg, fg, ICON_MARK_FRACTION)
    manifest = {
        "fingerprint": fingerprint(),
        "files": {k: hashlib.sha256(v).hexdigest() for k, v in sorted(files.items())},
    }
    files[MANIFEST] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    return files


def main(argv: list[str]) -> int:
    check = "--check" in argv
    stale = []
    for rel, data in build().items():
        path = os.path.join(ROOT, rel)
        current = open(path, "rb").read() if os.path.exists(path) else None
        if current == data:
            continue
        if check:
            stale.append(rel)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(data)
            print("wrote", rel)
    if stale:
        print("out of date (run python3 Tools/noop_brand.py):\n  " + "\n  ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
