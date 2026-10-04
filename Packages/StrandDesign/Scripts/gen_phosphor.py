#!/usr/bin/env python3
"""Regenerate the bundled Phosphor icon resource for StrandDesign.

Reads the Iconify JSON for the Phosphor set (`@iconify-json/ph`, MIT) and writes
`Sources/StrandDesign/Resources/phosphor.json`: a compact map of icon name to the list of
SVG path-data strings that make up the icon, e.g.

    {"heart-light": ["M178 42c-21 0-39.26 9.47-50 25.34..."], ...}

Only the Light and Fill weights are kept (names ending in `-light` / `-fill`); aliases with
those suffixes are resolved to their parent's body. Every icon sits on a 256x256 grid, which
the script asserts, because `PhosphorShape` scales from a fixed 256 viewBox. Each list entry
is one SVG element, filled on its own with the non-zero rule, which is how the source draws it.

Bodies are flattened: `<g>` wrappers are walked, `<path d>` is kept verbatim, and
`<circle>`, `<ellipse>`, `<rect>` (with optional rx/ry), `<polygon>` and `<polyline>` are
converted to equivalent path data. Anything that cannot be represented as a plain filled
path (opacity, an even-odd fill rule, a transform, a stroke-only element, an alias that flips
or rotates its parent) is reported and the icon is skipped rather than drawn wrongly.

Usage:
    python3 Packages/StrandDesign/Scripts/gen_phosphor.py              # download @latest
    python3 Packages/StrandDesign/Scripts/gen_phosphor.py icons.json   # use a local copy
"""

from __future__ import annotations

import json
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SOURCE_URL = "https://cdn.jsdelivr.net/npm/@iconify-json/ph@latest/icons.json"
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = PACKAGE_ROOT / "Sources/StrandDesign/Resources/phosphor.json"
SUFFIXES = ("-light", "-fill")
VIEWBOX = 256

# Attributes that change how an element paints and that the flat `name -> [d]` resource cannot
# carry. Seeing one means the icon would render wrongly, so it is skipped and reported.
UNSUPPORTED_ATTRS = ("opacity", "fill-opacity", "fill-rule", "clip-rule", "transform",
                     "stroke", "stroke-width", "mask", "clip-path")


class Unsupported(Exception):
    """Raised for an element the flat filled-path resource cannot express."""


def num(value: str | None, default: float = 0.0) -> float:
    if value is None or value == "":
        return default
    return float(value)


def fmt(value: float) -> str:
    """Shortest stable decimal form: no trailing zeros, no `-0`."""
    if abs(value) < 1e-9:
        return "0"
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text


def points_path(points: str, close: bool) -> str:
    raw = points.replace(",", " ").split()
    if len(raw) < 4 or len(raw) % 2:
        raise Unsupported(f"bad points list {points!r}")
    coords = [fmt(float(v)) for v in raw]
    pairs = [f"{coords[i]} {coords[i + 1]}" for i in range(0, len(coords), 2)]
    # A filled polyline is implicitly closed in SVG, so both shapes close the subpath.
    return "M" + pairs[0] + "".join("L" + p for p in pairs[1:]) + "Z"


def ellipse_path(cx: float, cy: float, rx: float, ry: float) -> str:
    if rx <= 0 or ry <= 0:
        raise Unsupported("ellipse with a zero radius")
    return (f"M{fmt(cx - rx)} {fmt(cy)}"
            f"a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(2 * rx)} 0"
            f"a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(-2 * rx)} 0Z")


def rect_path(el: ET.Element) -> str:
    x, y = num(el.get("x")), num(el.get("y"))
    w, h = num(el.get("width")), num(el.get("height"))
    if w <= 0 or h <= 0:
        raise Unsupported("rect with a zero size")
    rx_attr, ry_attr = el.get("rx"), el.get("ry")
    rx = num(rx_attr) if rx_attr is not None else num(ry_attr)
    ry = num(ry_attr) if ry_attr is not None else rx
    rx, ry = min(rx, w / 2), min(ry, h / 2)
    if rx <= 0 or ry <= 0:
        return f"M{fmt(x)} {fmt(y)}h{fmt(w)}v{fmt(h)}h{fmt(-w)}Z"
    return (f"M{fmt(x + rx)} {fmt(y)}h{fmt(w - 2 * rx)}"
            f"a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(ry)}v{fmt(h - 2 * ry)}"
            f"a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(ry)}h{fmt(-(w - 2 * rx))}"
            f"a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(-ry)}v{fmt(-(h - 2 * ry))}"
            f"a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(-ry)}Z")


def element_paths(el: ET.Element, inherited_fill: str | None) -> list[str]:
    tag = el.tag.split("}")[-1]
    for attr in UNSUPPORTED_ATTRS:
        if attr in el.attrib:
            raise Unsupported(f"<{tag}> carries {attr}={el.attrib[attr]!r}")
    fill = el.get("fill", inherited_fill)
    if tag == "g":
        out: list[str] = []
        for child in el:
            out.extend(element_paths(child, fill))
        return out
    if fill == "none":
        raise Unsupported(f"<{tag}> is not filled")
    if tag == "path":
        d = " ".join((el.get("d") or "").split())
        if not d:
            raise Unsupported("<path> without d")
        return [d]
    if tag == "circle":
        r = num(el.get("r"))
        return [ellipse_path(num(el.get("cx")), num(el.get("cy")), r, r)]
    if tag == "ellipse":
        return [ellipse_path(num(el.get("cx")), num(el.get("cy")),
                             num(el.get("rx")), num(el.get("ry")))]
    if tag == "rect":
        return [rect_path(el)]
    if tag == "polygon":
        return [points_path(el.get("points", ""), close=True)]
    if tag == "polyline":
        return [points_path(el.get("points", ""), close=False)]
    if tag == "line":
        # A line has no area; it only paints with a stroke, which this resource does not carry.
        raise Unsupported("<line> paints only with a stroke")
    raise Unsupported(f"unknown element <{tag}>")


def body_paths(body: str) -> list[str]:
    root = ET.fromstring(f'<svg xmlns="http://www.w3.org/2000/svg">{body}</svg>')
    out: list[str] = []
    for child in root:
        out.extend(element_paths(child, None))
    if not out:
        raise Unsupported("empty body")
    return out


def resolve(name: str, icons: dict, aliases: dict, depth: int = 0) -> dict:
    if name in icons:
        return icons[name]
    alias = aliases.get(name)
    if alias is None or depth > 8:
        raise Unsupported(f"unresolvable alias {name!r}")
    extra = set(alias) - {"parent"}
    if extra:
        raise Unsupported(f"alias {name!r} transforms its parent ({sorted(extra)})")
    return resolve(alias["parent"], icons, aliases, depth + 1)


def load(argv: list[str]) -> dict:
    if len(argv) > 1:
        return json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    with urllib.request.urlopen(SOURCE_URL, timeout=60) as response:  # noqa: S310 (fixed https URL)
        return json.loads(response.read().decode("utf-8"))


def main(argv: list[str]) -> int:
    data = load(argv)
    assert data.get("prefix") == "ph", f"unexpected prefix {data.get('prefix')!r}"
    assert data.get("width", 16) == VIEWBOX and data.get("height", 16) == VIEWBOX, \
        f"default viewBox is {data.get('width')}x{data.get('height')}, expected {VIEWBOX}"
    icons: dict = data["icons"]
    aliases: dict = data.get("aliases", {})

    names = sorted(n for n in set(icons) | set(aliases) if n.endswith(SUFFIXES))
    result: dict[str, list[str]] = {}
    skipped: list[tuple[str, str]] = []
    for name in names:
        try:
            icon = resolve(name, icons, aliases)
            width = icon.get("width", data["width"])
            height = icon.get("height", data["height"])
            if (width, height) != (VIEWBOX, VIEWBOX) or icon.get("left", 0) or icon.get("top", 0):
                raise Unsupported(f"viewBox {icon.get('left', 0)} {icon.get('top', 0)} {width} {height}")
            result[name] = body_paths(icon["body"])
        except (Unsupported, ET.ParseError, ValueError) as err:
            skipped.append((name, str(err)))

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(result, separators=(",", ":"), sort_keys=True, ensure_ascii=True)
    OUTPUT.write_text(payload + "\n", encoding="utf-8")

    light = sum(n.endswith("-light") for n in result)
    fill = sum(n.endswith("-fill") for n in result)
    multi = sum(len(v) > 1 for v in result.values())
    print(f"wrote {OUTPUT.relative_to(PACKAGE_ROOT)}: {len(result)} icons "
          f"({light} light, {fill} fill, {multi} multi-element), {OUTPUT.stat().st_size} bytes")
    for name, reason in skipped:
        print(f"skipped {name}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
