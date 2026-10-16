#!/usr/bin/env python3
"""Generate Safari branding from the App's Icon Composer/vector sources.

Run with uv run --no-project Scripts/generate_safari_icons.py.
Requires Xcode (Icon Composer and sips); no third-party Python packages.
"""

from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Shared (App)/AppIcon.icon"
IMAGES = ROOT / "Shared (Extension)/Resources/images"
SIZES = (16, 32, 48, 64, 96, 128, 256, 512)


def main():
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    tool = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    if not tool.is_file():
        raise SystemExit("Select an Xcode installation containing Icon Composer.")
    IMAGES.mkdir(parents=True, exist_ok=True)

    # Safari tints the toolbar glyph. Use only its alpha silhouette, with a
    # tighter viewBox for toolbar sizes; the paths are the App's same artwork.
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    svg = ET.Element("{http://www.w3.org/2000/svg}svg", {
        "width": "24", "height": "24", "viewBox": "184 192 656 656", "fill": "#000000"
    })
    for name in ("arrow", "tray"):
        source = ET.parse(ICON / "Assets" / (name + ".svg")).getroot()
        for shape in source:
            shape.attrib.pop("fill", None)
            svg.append(shape)
    ET.indent(svg, space="  ")
    ET.ElementTree(svg).write(IMAGES / "download-toolbar.svg", encoding="utf-8", xml_declaration=True)

    # Settings and extension listings use a full-color raster icon. Render the
    # actual Liquid Glass document rather than approximating its system effects.
    with tempfile.TemporaryDirectory(prefix="DownloaderSafariIcons-") as temporary:
        master = Path(temporary) / "AppIcon.png"
        subprocess.run([str(tool), str(ICON), "--export-image", "--output-file", str(master),
                        "--platform", "iOS", "--rendition", "Default", "--width", "1024",
                        "--height", "1024", "--scale", "1"], check=True)
        for size in SIZES:
            subprocess.run(["sips", "--resampleHeightWidth", str(size), str(size), str(master),
                            "--out", str(IMAGES / ("icon-" + str(size) + ".png"))],
                           check=True, stdout=subprocess.DEVNULL)
    print("Generated Safari's vector toolbar glyph and eight Liquid Glass icon sizes.")


if __name__ == "__main__":
    main()
