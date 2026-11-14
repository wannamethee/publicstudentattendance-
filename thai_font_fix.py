"""
thai_font_fix.py
Repairs Thai text extraction for SGS PDFs whose embedded fonts carry a broken
/ToUnicode map (tone marks and upper/lower vowels are decoded as a *consonant*,
e.g. "เรียน" -> "เรรยน").

The glyph *outlines* in the embedded subset fonts are intact and identical across
files, so every zero-width Thai mark glyph is identified by hashing its outline and
looking it up in `thai_glyph_labels.json`.

Usage:
    import thai_font_fix; thai_font_fix.install()      # before opening PDFs with pdfplumber
    python thai_font_fix.py --scan file1.pdf file2.pdf  # list mark glyphs that are not labelled yet
"""

import io
import os
import sys
import json
import hashlib
from pathlib import Path
from typing import Dict, List, Set, Tuple

import pdfminer.pdffont as _pf
from pdfminer.pdftypes import stream_value

LABELS_PATH = Path(__file__).with_name("thai_glyph_labels.json")

# (style, outline_hash) -> labelled Thai character ; filled by _load_labels()
LABELS: Dict[Tuple[str, str], str] = {}
# Unlabelled zero-width glyphs met while decoding: {(style, hash)}
UNKNOWN_GLYPHS: Set[Tuple[str, str]] = set()

_installed = False
_hash_cache: Dict[str, Dict[int, Tuple[str, str, int]]] = {}


def _load_labels() -> None:
    LABELS.clear()
    if LABELS_PATH.exists():
        raw = json.loads(LABELS_PATH.read_text(encoding="utf-8"))
        for style, table in raw.items():
            if style.startswith("_"):
                continue
            for h, ch in table.items():
                if not h.startswith("_"):
                    LABELS[(style, h)] = ch


def glyph_hash(tt, gname: str):
    from fontTools.pens.recordingPen import DecomposingRecordingPen
    gs = tt.getGlyphSet()
    pen = DecomposingRecordingPen(gs)
    gs[gname].draw(pen)
    if not pen.value:
        return None
    return hashlib.md5(repr(pen.value).encode()).hexdigest()[:10]


def font_code_table(font_bytes: bytes, style: str) -> Dict[int, Tuple[str, str, int]]:
    """code -> (style, outline_hash, advance_width) for a simple symbolic TrueType subset."""
    key = hashlib.md5(font_bytes).hexdigest() + style
    if key in _hash_cache:
        return _hash_cache[key]
    from fontTools.ttLib import TTFont
    tt = TTFont(io.BytesIO(font_bytes))
    table: Dict[int, Tuple[str, str, int]] = {}
    cm = tt["cmap"].getcmap(3, 0)   # symbolic subset -> signature of the broken generator
    if cm is not None:
        hmtx = tt["hmtx"]
        for code, gname in cm.cmap.items():
            if gname == ".notdef":
                continue
            h = glyph_hash(tt, gname)
            if h:
                table[code & 0xFF] = (style, h, hmtx[gname][0])
    _hash_cache[key] = table
    return table


def install() -> None:
    """Monkeypatch pdfminer so labelled mark glyphs decode to the right Thai character."""
    global _installed
    if _installed:
        return
    _load_labels()
    orig_init = _pf.PDFSimpleFont.__init__
    orig_to_unichr = _pf.PDFSimpleFont.to_unichr

    def __init__(self, descriptor, widths, spec):
        orig_init(self, descriptor, widths, spec)
        self._thai_fix = {}
        try:
            ff = descriptor.get("FontFile2") if descriptor else None
            if ff is None:
                return
            style = "Bold" if "bold" in str(descriptor.get("FontName", "")).lower() else "Regular"
            table = font_code_table(stream_value(ff).get_data(), style)
            for code, (st, h, adv) in table.items():
                if (st, h) in LABELS:
                    self._thai_fix[code] = LABELS[(st, h)]
                elif adv == 0:
                    # zero-width glyph we cannot identify: never trust the broken ToUnicode
                    self._thai_fix[code] = ""
                    UNKNOWN_GLYPHS.add((st, h))
        except Exception:
            self._thai_fix = {}

    def to_unichr(self, cid):
        fix = getattr(self, "_thai_fix", None)
        if fix and cid in fix:
            return fix[cid]
        return orig_to_unichr(self, cid)

    _pf.PDFSimpleFont.__init__ = __init__
    _pf.PDFSimpleFont.to_unichr = to_unichr
    _installed = True


def scan(paths: List[str]) -> None:
    """Report zero-width glyph shapes without a label."""
    import pdfplumber
    from pdfminer.pdftypes import resolve1
    _load_labels()
    seen: Dict[Tuple[str, str], int] = {}
    for p in paths:
        with pdfplumber.open(p) as pdf:
            for page in pdf.pages:
                fonts = resolve1(resolve1(page.page_obj.resources).get("Font"))
                for _, ref in fonts.items():
                    f = resolve1(ref)
                    fd = resolve1(f.get("FontDescriptor"))
                    ff = fd.get("FontFile2") if fd else None
                    if ff is None:
                        continue
                    style = "Bold" if "bold" in str(f.get("BaseFont")).lower() else "Regular"
                    for code, (st, h, adv) in font_code_table(resolve1(ff).get_data(), style).items():
                        if adv == 0 and (st, h) not in LABELS:
                            seen[(st, h)] = seen.get((st, h), 0) + 1
    if not seen:
        print("All zero-width glyphs are labelled.")
    for (st, h), n in seen.items():
        print(f"UNLABELLED  style={st} hash={h} (in {n} font(s))")


if __name__ == "__main__":
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) > 2 and sys.argv[1] == "--scan":
        scan(sys.argv[2:])
    else:
        print(__doc__)
