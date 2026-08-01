#!/usr/bin/env python3
"""check-contrast.py — measure every theme's colours against the frame it is rendered on.

"Decent contrast" is a number, not an opinion, so this computes it rather than asserting it.
WCAG 2.x relative luminance and contrast ratio; the thresholds are the standard ones:

    >= 4.5   normal body text (AA)
    >= 3.0   large/bold text and non-text UI such as the progress bars (AA)
    <  3.0   fails — unreadable on that background

Two frames only, matching make-screenshots.sh: light themes on #ffffff, dark themes on
#1e1e2e. A theme is reported PASS when every colour that carries INFORMATION clears 3.0 and
its body text clears 4.5. Borders and the empty half of a progress bar are decorative — they
are measured and shown, but they do not fail a theme, because a rule that made every divider
clear 4.5 would force the chrome to be as loud as the data.

Usage:  ./check-contrast.py [theme ...]      exit 1 if any checked theme fails
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "dashboard.sh"

LIGHT_THEMES = ["light", "solarized-light", "paper"]
LIGHT_BG, DARK_BG = "#ffffff", "#1e1e2e"

# Colours that carry information. T_BORDER / T_DIM / T_SEP are chrome.
INFORMATIVE = [
    "T_TITLE", "T_VALUE", "T_LABEL", "T_HIGHLIGHT",
    "T_ACCENT1", "T_ACCENT2", "T_ACCENT3",
    "T_GREEN", "T_YELLOW", "T_RED",
    "T_BAR_SESSION", "T_BAR_WEEK", "T_BAR_CTX",
]
BODY = ["T_VALUE", "T_TITLE"]          # must clear the 4.5 body-text bar
DECORATIVE = ["T_BORDER", "T_DIM", "T_WEATHER", "T_ACCENT4"]

ANSI_BASE = {
    30: "#000000", 31: "#cc0000", 32: "#4e9a06", 33: "#c4a000", 34: "#3465a4",
    35: "#75507b", 36: "#06989a", 37: "#d3d7cf", 90: "#555753", 91: "#ef2929",
    92: "#8ae234", 93: "#fce94f", 94: "#729fcf", 95: "#ad7fa8", 96: "#34e2e2",
    97: "#eeeeec",
}


def srgb_to_lin(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hexcolor: str) -> float:
    h = hexcolor.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * srgb_to_lin(r) + 0.7152 * srgb_to_lin(g) + 0.0722 * srgb_to_lin(b)


def ratio(fg: str, bg: str) -> float:
    a, b = luminance(fg), luminance(bg)
    lo, hi = sorted((a, b))
    return (hi + 0.05) / (lo + 0.05)


def theme_colors(theme: str) -> dict[str, str]:
    """Pull the theme's SGR sequences out of dashboard.sh by running its own case block."""
    src = SCRIPT.read_text()
    m = re.search(rf"^    {re.escape(theme)}\)\n(.*?)\n      ;;$", src, re.S | re.M)
    if not m:
        return {}
    out: dict[str, str] = {}
    for var, seq in re.findall(r"^\s+(T_[A-Z_0-9]+)='([^']*)'", m.group(1), re.M):
        codes = [int(c) for c in re.findall(r"\d+", seq)]
        col = None
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 38 and i + 4 < len(codes) and codes[i + 1] == 2:
                col = "#%02x%02x%02x" % tuple(codes[i + 2:i + 5]); i += 4
            elif c in ANSI_BASE:
                col = ANSI_BASE[c]
            i += 1
        if col:
            out[var] = col
    return out


def check(theme: str) -> bool:
    bg = LIGHT_BG if theme in LIGHT_THEMES else DARK_BG
    cols = theme_colors(theme)
    if not cols:
        print(f"{theme}: NO COLOURS PARSED"); return False

    failures, rows = [], []
    for var in INFORMATIVE + DECORATIVE:
        if var not in cols:
            continue
        r = ratio(cols[var], bg)
        need = 4.5 if var in BODY else 3.0
        decorative = var in DECORATIVE
        ok = decorative or r >= need
        if not ok:
            failures.append(f"{var} {r:.1f}:1 (needs {need})")
        rows.append((var, cols[var], r, "" if decorative else f"/{need:.1f}", ok, decorative))

    status = "PASS" if not failures else "FAIL"
    print(f"\n{theme}  on {bg}   {status}")
    for var, col, r, need, ok, dec in sorted(rows, key=lambda x: x[2]):
        mark = "·" if dec else ("ok" if ok else "XX")
        print(f"   {mark} {var:<16} {col}  {r:5.1f}:1{need}")
    for f in failures:
        print(f"   -> {f}")
    return not failures


if __name__ == "__main__":
    src = SCRIPT.read_text()
    all_themes = re.findall(r"^    ([a-z][a-z0-9-]*)\)\n      T_HEADER=", src, re.M)
    targets = sys.argv[1:] or all_themes
    ok = all([check(t) for t in targets])
    print(f"\n{'all checked themes pass' if ok else 'FAILURES above'}")
    sys.exit(0 if ok else 1)
