"""Drift tests for the NOOP brand mark (Tools/noop_brand.py).

Every logo file in the repository is generated from noop_brand.py. These tests fail when a derived
file no longer matches its source (someone edited an icon or a drawable by hand, or changed the
geometry without re-running the script), and when the retired ring mark creeps back into source.
"""
import hashlib
import io
import json
import os
import struct
import unittest
import zlib
from contextlib import redirect_stdout

import noop_brand

ROOT = noop_brand.ROOT


def _read(rel):
    with open(os.path.join(ROOT, rel), "rb") as fh:
        return fh.read()


def _png_pixel(png, x, y):
    """RGB of one pixel of an 8-bit RGB, filter-0 PNG as noop_brand writes them."""
    width = struct.unpack(">I", png[16:20])[0]
    pos, idat = 8, b""
    while pos < len(png):
        length = struct.unpack(">I", png[pos:pos + 4])[0]
        if png[pos + 4:pos + 8] == b"IDAT":
            idat += png[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw = zlib.decompress(idat)
    row = y * (1 + 3 * width) + 1
    return tuple(raw[row + 3 * x: row + 3 * x + 3])


class BrandFilesAreCurrent(unittest.TestCase):

    def test_every_text_output_matches_the_generator(self):
        for rel, text in noop_brand.text_outputs().items():
            with self.subTest(rel):
                self.assertEqual(_read(rel).decode(), text,
                                 f"{rel} is stale: run python3 Tools/noop_brand.py")

    def test_png_outputs_match_the_manifest(self):
        manifest = json.loads(_read(noop_brand.MANIFEST))
        self.assertEqual(manifest["fingerprint"], noop_brand.fingerprint(),
                         "the icon geometry changed: run python3 Tools/noop_brand.py")
        for rel in noop_brand.png_outputs():
            with self.subTest(rel):
                self.assertEqual(hashlib.sha256(_read(rel)).hexdigest(), manifest["files"][rel],
                                 f"{rel} was edited by hand: run python3 Tools/noop_brand.py")

    def test_check_mode_reports_nothing_stale(self):
        with redirect_stdout(io.StringIO()) as out:
            status = noop_brand.main(["--check"])
        self.assertEqual(status, 0, out.getvalue())


class BrandGeometry(unittest.TestCase):

    def test_mark_is_centred_on_its_grid(self):
        x0, y0, x1, y1 = noop_brand.MARK_BOX
        self.assertEqual((x0 + x1) / 2, 32)
        self.assertEqual((y0 + y1) / 2, 32)

    def test_icon_pixels_land_on_mark_and_tile(self):
        png = noop_brand.icon_png(64, noop_brand.BRICK, noop_brand.CREAM, noop_brand.ICON_MARK_FRACTION)
        cream, brick = noop_brand._rgb(noop_brand.CREAM), noop_brand._rgb(noop_brand.BRICK)
        s = 64 * noop_brand.ICON_MARK_FRACTION / 44          # grid units -> pixels on this tile
        to_px = lambda v: int(32 + (v - 32) * s)              # noqa: E731
        self.assertEqual(_png_pixel(png, to_px(32), to_px(44.5)), cream)   # the dot
        self.assertEqual(_png_pixel(png, to_px(32), to_px(13)), cream)     # the arch's crown
        self.assertEqual(_png_pixel(png, to_px(24), to_px(44.5)), brick)   # doorway beside the dot
        self.assertEqual(_png_pixel(png, 1, 1), brick)                     # the tile

    def test_every_consumer_carries_the_current_mark(self):
        mark = noop_brand.mark_path()
        for rel in ("Packages/StrandDesign/Sources/StrandDesign/BrandPaths.swift",
                    "android/app/src/main/res/drawable/ic_noop_mark.xml",
                    "docs/assets/noop-mark.svg"):
            with self.subTest(rel):
                self.assertIn(mark, _read(rel).decode())


class RetiredMarkIsGone(unittest.TestCase):
    """The open recovery ring + core dot was the mark until the arch replaced it."""

    SIGNATURES = (
        "sweepAngle = 288f",            # the ring arc on Android
        "trim(from: 0, to: 0.8)",       # the ring arc on macOS
        "openFraction",                 # the ring arc in StrandDesign
        "fun LoopMark(",                # the Android avatar copy of the ring
        "ic_launcher_metal",            # the titanium launcher tiles
        "logo-v3.png",                  # the README's ring logo
    )
    ROOTS = ("Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch",
             "NOOPWatchComplications", "Packages/StrandDesign/Sources", "android/app/src/main")
    EXTENSIONS = (".swift", ".kt", ".xml")

    def test_no_source_draws_the_ring_mark(self):
        hits = []
        files = [os.path.join(ROOT, "README.md")]
        for top in self.ROOTS:
            for dirpath, _, names in os.walk(os.path.join(ROOT, top)):
                files += [os.path.join(dirpath, n) for n in names if n.endswith(self.EXTENSIONS)]
        for path in files:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            hits += [f"{os.path.relpath(path, ROOT)}: {sig}" for sig in self.SIGNATURES if sig in text]
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
