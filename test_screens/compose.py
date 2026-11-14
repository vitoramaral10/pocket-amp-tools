#!/usr/bin/env python3
"""Composes the website/README images from the renders in goldens/.

Run after `flutter test test_screens --update-goldens`:

    python3 test_screens/compose.py

Writes docs/screenshot-{dark,light}.png, docs/screenshot-phone-{dark,light}.png,
docs/social-preview.png and docs/icon.png, and copies the phone renders to the
store listing in fastlane/. Needs rsvg-convert and the Noto Sans font.
"""
import base64
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GOLD = ROOT / "test_screens" / "goldens"
DOCS = ROOT / "docs"
STORE = ROOT / "fastlane/metadata/android/en-US/images/phoneScreenshots"
ICON = ROOT / "assets" / "icon" / "app_icon.png"

SHOT_W, SHOT_H = 2560, 1600  # the presets editor at 1280x800, 2x
BAR = 72  # title bar height at 2x

THEMES = {
    "dark": dict(page="#0e0e0e", glow="#c4511a", app="#1a1a1a",
                 bar="#2b2b2b", title="#ededed", line="#333333"),
    "light": dict(page="#f2efed", glow="#ff8a50", app="#ffffff",
                  bar="#ebebeb", title="#1c1c1c", line="#dddddd"),
}


def uri(path: Path) -> str:
    # rsvg-convert only loads files next to the SVG, so embed them.
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()


def window(t, shot, x, y, scale):
    """An app window with a title bar, drawn at (x, y)."""
    w, h = SHOT_W * scale, (SHOT_H + BAR) * scale
    r = 24 * scale
    return f"""
  <g transform="translate({x} {y})">
    <rect x="0" y="{24 * scale}" width="{w}" height="{h}" rx="{r}"
          fill="#000" opacity=".35" filter="url(#blur)"/>
    <clipPath id="win{x}"><rect width="{w}" height="{h}" rx="{r}"/></clipPath>
    <g clip-path="url(#win{x})">
      <rect width="{w}" height="{h}" fill="{t['app']}"/>
      <rect width="{w}" height="{BAR * scale}" fill="{t['bar']}"/>
      <text x="{w / 2}" y="{BAR * scale * .62}" text-anchor="middle"
            font-family="Noto Sans" font-weight="600"
            font-size="{26 * scale}" fill="{t['title']}">Pocket AMP Tools</text>
      <image href="{uri(shot)}" x="0" y="{BAR * scale}" width="{SHOT_W * scale}"
             height="{SHOT_H * scale}" preserveAspectRatio="xMinYMin slice"/>
    </g>
    <rect width="{w}" height="{h}" rx="{r}" fill="none"
          stroke="{t['line']}" stroke-width="{2 * scale}"/>
  </g>"""


DEFS = """
  <defs>
    <filter id="blur" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="28"/>
    </filter>
    <radialGradient id="glow" cx="80%" cy="0%" r="90%">
      <stop offset="0" stop-color="{glow}" stop-opacity=".35"/>
      <stop offset="1" stop-color="{glow}" stop-opacity="0"/>
    </radialGradient>
  </defs>"""


def render(svg: str, out: Path, width: int):
    src = out.with_suffix(".svg")
    src.write_text(svg)
    try:
        subprocess.run(["rsvg-convert", "-w", str(width), "-o", str(out),
                        str(src)], check=True)
    finally:
        src.unlink()


def screenshot(name):
    t = THEMES[name]
    pad = 96
    W, H = SHOT_W + 2 * pad, SHOT_H + BAR + 2 * pad
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
  {DEFS.format(**t)}
  <rect width="{W}" height="{H}" fill="{t['page']}"/>
  <rect width="{W}" height="{H}" fill="url(#glow)"/>
  {window(t, GOLD / f"layout-presets-{name}.png", pad, pad, 1)}
</svg>"""
    render(svg, DOCS / f"screenshot-{name}.png", W)


def phone(name):
    """The phone render with rounded corners, at a third of its size."""
    t = THEMES[name]
    W, H, r = 1080, 2340, 84
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
  <clipPath id="c"><rect width="{W}" height="{H}" rx="{r}"/></clipPath>
  <image href="{uri(GOLD / f"layout-phone-presets-{name}.png")}" width="{W}"
         height="{H}" clip-path="url(#c)"/>
  <rect x="3" y="3" width="{W - 6}" height="{H - 6}" rx="{r - 3}" fill="none"
        stroke="{t['line']}" stroke-width="6"/>
</svg>"""
    render(svg, DOCS / f"screenshot-phone-{name}.png", 720)


def store():
    """The store listing shows them in file name order."""
    STORE.mkdir(parents=True, exist_ok=True)
    for i, screen in enumerate(("presets", "library", "backups"), 1):
        shutil.copyfile(GOLD / f"layout-phone-{screen}-dark.png",
                        STORE / f"{i}.png")


def social():
    t = THEMES["dark"]
    W, H = 1280, 640
    s = 0.30
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
  {DEFS.format(**t)}
  <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1">
    <stop offset=".72" stop-color="{t['page']}" stop-opacity="0"/>
    <stop offset="1" stop-color="{t['page']}" stop-opacity="1"/>
  </linearGradient>
  <rect width="{W}" height="{H}" fill="{t['page']}"/>
  <rect width="{W}" height="{H}" fill="url(#glow)"/>
  {window(t, GOLD / "layout-presets-dark.png", 700, 120, s)}
  <rect x="700" y="0" width="{W - 640}" height="{H}" fill="url(#fade)"/>
  <image href="{uri(ICON)}" x="64" y="88" width="88" height="88"/>
  <text font-family="Noto Sans" fill="#ededed">
    <tspan x="64" y="268" font-size="54" font-weight="700">Edit and update</tspan>
    <tspan x="64" y="336" font-size="54" font-weight="700">your Pocket AMP</tspan>
  </text>
  <text x="64" y="398" font-family="Noto Sans" font-size="27" fill="#bdbdbd">M-VAVE, Donner, PIXIE1, SK17: any brand</text>
  <text x="64" y="440" font-family="Noto Sans" font-size="27" fill="#bdbdbd">macOS, Linux, Windows and Android</text>
  <rect x="64" y="496" width="404" height="52" rx="26" fill="none" stroke="#ff8a50" stroke-width="2"/>
  <text x="266" y="530" text-anchor="middle" font-family="Noto Sans" font-weight="600" font-size="21" fill="#ff8a50">Free &amp; open source · GPL-3.0</text>
</svg>"""
    render(svg, DOCS / "social-preview.png", W)


if __name__ == "__main__":
    for n in ("dark", "light"):
        for shot in ("presets", "phone-presets"):
            if not (GOLD / f"layout-{shot}-{n}.png").exists():
                sys.exit(f"missing goldens/layout-{shot}-{n}.png: render them first")
        screenshot(n)
        phone(n)
    store()
    social()
    render(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">'
           f'<image href="{uri(ICON)}" width="1024" height="1024"/></svg>',
           DOCS / "icon.png", 180)
