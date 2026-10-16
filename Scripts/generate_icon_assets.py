#!/usr/bin/env python3
"""Render visionOS icon layers from the editable SVG artwork.

Run with uv run --no-project Scripts/generate_icon_assets.py.
Requires librsvg's rsvg-convert (brew install librsvg).
Liquid Glass .icon source stays vector; only visionOS uses rendered layers.
"""

import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Shared (App)/AppIcon.icon"
CATALOG = ROOT / "visionOS (App)/Assets.xcassets"
STACK = CATALOG / "AppIcon.solidimagestack"
INFO = {"author": "xcode", "version": 1}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    renderer = shutil.which("rsvg-convert")
    if renderer is None:
        raise SystemExit("Install librsvg to regenerate visionOS PNG layers.")
    layers = [
        ("Front", ICON / "Assets/arrow.svg"),
        ("Middle", ICON / "Assets/tray.svg"),
        ("Back", ROOT / "Artwork/AppIcon/vision-background.svg"),
    ]
    write_json(CATALOG / "Contents.json", {"info": INFO})
    write_json(STACK / "Contents.json", {"info": INFO, "layers": [
        {"filename": name + ".solidimagestacklayer"} for name, _ in layers
    ]})
    for name, source in layers:
        layer = STACK / (name + ".solidimagestacklayer")
        image = layer / "Content.imageset"
        write_json(layer / "Contents.json", {"info": INFO})
        write_json(image / "Contents.json", {"images": [
            {"filename": name.lower() + ".png", "idiom": "vision", "scale": "2x"}
        ], "info": INFO})
        subprocess.run([renderer, "--width", "1024", "--height", "1024", "--output",
                        str(image / (name.lower() + ".png")), str(source)], check=True)
    print("Rendered three 1024 × 1024 visionOS layers from the SVG sources.")


if __name__ == "__main__":
    main()
