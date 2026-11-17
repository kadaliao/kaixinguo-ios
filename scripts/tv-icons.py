#!/usr/bin/env python3
"""Draws the Apple TV app's icon and Top Shelf images into its asset catalog.

The shapes are resources/icon.svg's: the green tile, the pistachio shell and
the kernel that is a play button. tvOS icons are 5:3 and layered, each layer
moving a little as focus tilts the icon: the tile and the shell's shadow at
the back, the shell in the middle, the kernel in front.

    scripts/tv-icons.py

Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick).
"""
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "KaixinguoTV/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
INFO = {"author": "xcode", "version": 1}

DEFS = """<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#C3E58F"/><stop offset="1" stop-color="#5E9F3A"/>
  </linearGradient>
  <linearGradient id="shell" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#FFFBF2"/><stop offset="1" stop-color="#EBDDBF"/>
  </linearGradient>
  <linearGradient id="kernel" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#7CC24A"/><stop offset="1" stop-color="#4E8F2C"/>
  </linearGradient>
</defs>"""

# The nut's parts, in icon.svg's own coordinates, around the shell's center
# at (512, 530); the tilted shell is 558 units tall.
PARTS = {
    "shadow": '<ellipse cx="528" cy="560" rx="228" ry="292" transform="rotate(-28 528 560)" fill="#2F5E1C" opacity="0.22"/>',
    "shell": '<ellipse cx="512" cy="530" rx="228" ry="292" transform="rotate(-28 512 530)" fill="url(#shell)"/>',
    "kernel": '<path transform="translate(-14 -16)" d="M452 418 L452 662 Q452 690 476 676 L668 562 Q690 548 668 534 L476 404 Q452 390 452 418 Z" fill="url(#kernel)"/>',
}


def nut(parts, cx, cy, height):
    """The parts of the nut, its shell centered on (cx, cy), height tall."""
    s = height / 558
    shapes = "".join(PARTS[p] for p in parts)
    return f'<g transform="translate({cx - 512 * s:.2f} {cy - 530 * s:.2f}) scale({s:.5f})">{shapes}</g>'


def svg(w, h, body, tile=False):
    back = f'<rect width="{w}" height="{h}" fill="url(#bg)"/>' if tile else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{DEFS}{back}{body}</svg>'


def render(source, path, w, h, opaque=False):
    """Renders the SVG source at w × h into path; opaque drops the alpha
    channel, which the App Store refuses on a back layer."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(source)
    subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), "-o", str(path), f.name], check=True)
    if opaque:
        subprocess.run(["magick", str(path), "-alpha", "off", str(path)], check=True)
    pathlib.Path(f.name).unlink()


def contents(path, data):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(data | {"info": INFO}, indent=2, ensure_ascii=False) + "\n")


def icon_layers():
    """The icon's three layers, drawn 400 × 240."""
    w, h = 400, 240
    cx, cy, size = w / 2, h / 2, h * 0.64
    return {
        "Front": (svg(w, h, nut(["kernel"], cx, cy, size)), False),
        "Middle": (svg(w, h, nut(["shell"], cx, cy, size)), False),
        "Back": (svg(w, h, nut(["shadow"], cx, cy, size), tile=True), True),
    }


def stack(name, scales):
    """An image stack of the icon's layers, at each (scale, width, height)."""
    d = OUT / f"{name}.imagestack"
    contents(d, {"layers": [{"filename": f"{layer}.imagestacklayer"} for layer in ("Front", "Middle", "Back")]})
    for layer, (source, opaque) in icon_layers().items():
        ld = d / f"{layer}.imagestacklayer"
        contents(ld, {})
        images = []
        for scale, w, h in scales:
            file = f"{layer.lower()}{'' if scale == 1 else f'@{scale}x'}.png"
            render(source, ld / "Content.imageset" / file, w, h, opaque)
            images.append({"filename": file, "idiom": "tv", "scale": f"{scale}x"})
        contents(ld / "Content.imageset", {"images": images})


def top_shelf(name, w, h):
    """The Top Shelf image: the nut beside the app's name and what it is."""
    size = h * 0.6
    nut_w = size * 487 / 558
    title, line = 200, 64  # font sizes
    width = nut_w + 90 + title * 3
    x = (w - width) / 2
    text = (
        f'<g font-family="Hiragino Sans GB" fill="#FFFFFF">'
        f'<text x="{x + nut_w + 90:.0f}" y="{h / 2 + 30:.0f}" font-size="{title}" font-weight="bold">开心果</text>'
        f'<text x="{x + nut_w + 96:.0f}" y="{h / 2 + 130:.0f}" font-size="{line}" fill-opacity="0.85">无广告、不烧心</text>'
        f"</g>"
    )
    body = nut(["shadow", "shell", "kernel"], x + nut_w / 2, h / 2, size) + text
    d = OUT / f"{name}.imageset"
    images = []
    for scale in (1, 2):
        file = f"top{'' if scale == 1 else f'@{scale}x'}.png"
        render(svg(w, h, body, tile=True), d / file, w * scale, h * scale, opaque=True)
        images.append({"filename": file, "idiom": "tv", "scale": f"{scale}x"})
    contents(d, {"images": images})


def main():
    stack("App Icon", [(1, 400, 240), (2, 800, 480)])
    stack("App Icon - App Store", [(1, 1280, 768)])
    top_shelf("Top Shelf Image", 1920, 720)
    top_shelf("Top Shelf Image Wide", 2320, 720)
    contents(OUT, {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ]})


if __name__ == "__main__":
    main()
