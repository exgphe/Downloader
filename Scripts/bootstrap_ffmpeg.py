# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build a minimal LGPL FFmpeg library for local MP4/Matroska remuxing.

No decoders, encoders, network protocols, command-line programs or GPL components
are enabled. Invoke with uv run --no-project --script Scripts/bootstrap_ffmpeg.py.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = {
    "macos-arm64": ("macosx", "aarch64", "arm64-apple-macos12.0"),
    "macos-x86_64": ("macosx", "x86_64", "x86_64-apple-macos12.0"),
    "ios-arm64": ("iphoneos", "aarch64", "arm64-apple-ios17.0"),
    "ios-simulator-arm64": ("iphonesimulator", "aarch64", "arm64-apple-ios17.0-simulator"),
    "ios-simulator-x86_64": ("iphonesimulator", "x86_64", "x86_64-apple-ios17.0-simulator"),
    "xros-arm64": ("xros", "aarch64", "arm64-apple-xros26.0"),
    "xros-simulator-arm64": ("xrsimulator", "aarch64", "arm64-apple-xros26.0-simulator"),
}

def run(command, *, cwd=None, log=None):
    if log:
        with log.open("w") as output:
            result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"Build failed; see {log}")
    else:
        subprocess.run(command, cwd=cwd, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", action="append", choices=VARIANTS)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    lock = json.loads((ROOT / "Dependencies/runtime-lock.json").read_text())["ffmpeg"]
    archive = ROOT / "Dependencies/archives" / lock["filename"]
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        if args.offline:
            raise SystemExit(f"Missing {archive}")
        urllib.request.urlretrieve(lock["url"], archive)
    with archive.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != lock["sha256"]:
            raise SystemExit("FFmpeg source checksum does not match runtime-lock.json")
    scratch = ROOT / "Dependencies/FFmpegBuild"
    scratch.mkdir(exist_ok=True)
    source = scratch / ("ffmpeg-" + lock["version"])
    if not source.exists():
        with tarfile.open(archive) as file:
            file.extractall(scratch, filter="data")
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    variants = args.variant or list(VARIANTS)
    for variant in variants:
        destination = ROOT / "Dependencies/FFmpeg" / variant
        marker = destination / "build.json"
        if marker.exists() and json.loads(marker.read_text()).get("sourceSHA256") == lock["sha256"]:
            print(f"Already built {variant}", flush=True)
            continue
        sdk, arch, target = VARIANTS[variant]
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        build = scratch / variant
        build.mkdir(exist_ok=True)
        flags = f"-target {target} -isysroot {sdk_path} -fapplication-extension -fPIC"
        configuration = [str(source / "configure"), f"--prefix={destination}", "--target-os=darwin",
                         f"--arch={arch}", f"--cc={clang}", "--enable-cross-compile", "--enable-static",
                         "--disable-shared", "--disable-everything", "--disable-autodetect", "--disable-network",
                         "--disable-programs", "--disable-doc", "--disable-debug", "--disable-asm",
                         "--disable-avdevice", "--disable-avfilter", "--disable-swscale", "--disable-swresample",
                         "--enable-demuxer=mov,matroska", "--enable-muxer=mp4,matroska", "--enable-protocol=file",
                         "--enable-parser=aac,av1,h264,hevc,opus,vp9", "--enable-bsf=aac_adtstoasc",
                         f"--extra-cflags={flags}", f"--extra-ldflags={flags}"]
        print(f"Building local remux libraries for {variant}…", flush=True)
        run(configuration, cwd=build, log=build / "configure.log")
        run(["make", "-j", str(min(8, os.cpu_count() or 4))], cwd=build, log=build / "build.log")
        run(["make", "install"], cwd=build, log=build / "install.log")
        (destination / "include/module.modulemap").write_text(
            'module LocalAV [system] {\n'
            '    header "libavformat/avformat.h"\n'
            '    header "libavcodec/avcodec.h"\n'
            '    header "libavutil/avutil.h"\n'
            '    header "libavutil/mathematics.h"\n'
            '    export *\n'
            '}\n')
        (destination / "COPYING.LGPLv2.1").write_bytes((source / "COPYING.LGPLv2.1").read_bytes())
        marker.write_text(json.dumps({"sourceSHA256": lock["sha256"], "version": lock["version"],
                                     "target": target, "configuration": configuration}, indent=2))
    print("Minimal local FFmpeg libraries are ready.", flush=True)

if __name__ == "__main__":
    main()
