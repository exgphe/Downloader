# /// script
# requires-python = ">=3.12"
# dependencies = ["meson==1.9.1", "ninja==1.13.0", "pkgconf==3.0.7.post0"]
# ///
"""Build local LGPL FFmpeg libraries with BSD dav1d AV1 decoding.

HEVC encoding uses Apple's VideoToolbox. Network protocols, command-line
programs and GPL components are disabled. Python/build tools are managed by uv.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
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
    locks = json.loads((ROOT / "Dependencies/runtime-lock.json").read_text())
    lock = locks["ffmpeg"]
    dav1d = locks["dav1d"]
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
    # FFmpeg 8.0.1 treats visionOS as iOS here, but OpenGLES is unavailable.
    # Use the public Metal compatibility key for its pixel buffers instead.
    compatibility = source / "libavcodec/videotoolbox.c"
    original = "#if TARGET_OS_IPHONE\n    CFDictionarySetValue(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue);"
    patched = "#if TARGET_OS_VISION\n    CFDictionarySetValue(buffer_attributes, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);\n#elif TARGET_OS_IPHONE\n    CFDictionarySetValue(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue);"
    contents = compatibility.read_text()
    if original in contents:
        compatibility.write_text(contents.replace(original, patched))
    elif patched not in contents:
        raise SystemExit("FFmpeg VideoToolbox source does not match the expected visionOS compatibility patch")
    dav1d_archive = archive.parent / dav1d["filename"]
    if not dav1d_archive.exists():
        if args.offline:
            raise SystemExit(f"Missing {dav1d_archive}")
        urllib.request.urlretrieve(dav1d["url"], dav1d_archive)
    with dav1d_archive.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != dav1d["sha256"]:
            raise SystemExit("dav1d source checksum does not match runtime-lock.json")
    dav1d_source = scratch / ("dav1d-" + dav1d["version"])
    if not dav1d_source.exists():
        with tarfile.open(dav1d_archive) as file:
            file.extractall(scratch, filter="data")
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    variants = args.variant or list(VARIANTS)
    for variant in variants:
        destination = ROOT / "Dependencies/FFmpeg" / variant
        marker = destination / "build.json"
        expected = {"sourceSHA256": lock["sha256"], "dav1dSHA256": dav1d["sha256"], "buildRevision": 2}
        if marker.exists() and all(json.loads(marker.read_text()).get(key) == value for key, value in expected.items()):
            print(f"Already built {variant}", flush=True)
            continue
        sdk, arch, target = VARIANTS[variant]
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        build = scratch / (variant + "-media-v" + str(expected["buildRevision"]))
        build.mkdir(exist_ok=True)
        flags = f"-target {target} -isysroot {sdk_path} -fapplication-extension -fPIC"
        dav1d_build = scratch / (variant + "-dav1d")
        cross = scratch / (variant + "-dav1d.ini")
        cross.write_text(
            f"[binaries]\nc = {[clang, '-target', target, '-isysroot', sdk_path]!r}\n"
            f"ar = {subprocess.check_output(['xcrun', '--find', 'ar'], text=True).strip()!r}\n"
            f"[host_machine]\nsystem = 'darwin'\ncpu_family = {arch!r}\ncpu = {arch!r}\nendian = 'little'\n"
            "[properties]\nneeds_exe_wrapper = true\n"
            "[built-in options]\nc_args = ['-fapplication-extension', '-fPIC']\n")
        if dav1d_build.exists():
            shutil.rmtree(dav1d_build)
        run(["meson", "setup", str(dav1d_build), str(dav1d_source), "--cross-file", str(cross),
             "--prefix", str(destination), "--libdir", "lib", "--buildtype", "release",
             "--default-library", "static", "-Denable_asm=false", "-Denable_tools=false",
             "-Denable_tests=false"], log=build / "dav1d-configure.log")
        run(["meson", "compile", "-C", str(dav1d_build), "-j", "4"], log=build / "dav1d-build.log")
        run(["meson", "install", "-C", str(dav1d_build)], log=build / "dav1d-install.log")
        pkg_config = shutil.which("pkgconf") or shutil.which("pkg-config")
        if not pkg_config:
            raise SystemExit("Run this script through uv to provide the pinned pkgconf tool.")
        os.environ["PKG_CONFIG_LIBDIR"] = str(destination / "lib/pkgconfig")
        configuration = [str(source / "configure"), f"--prefix={destination}", "--target-os=darwin",
                         f"--arch={arch}", f"--cc={clang}", "--enable-cross-compile", "--enable-static",
                         "--disable-shared", "--disable-everything", "--disable-autodetect", "--disable-network",
                         "--disable-programs", "--disable-doc", "--disable-debug", "--disable-asm",
                         "--disable-avdevice", "--disable-avfilter", "--enable-swscale", "--disable-swresample",
                         "--enable-libdav1d", f"--pkg-config={pkg_config}", "--pkg-config-flags=--static",
                         "--enable-videotoolbox", "--enable-decoder=libdav1d", "--enable-encoder=hevc_videotoolbox",
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
            '    header "libavutil/opt.h"\n'
            '    header "libavutil/pixdesc.h"\n'
            '    header "libswscale/swscale.h"\n'
            '    export *\n'
            '}\n')
        (destination / "COPYING.LGPLv2.1").write_bytes((source / "COPYING.LGPLv2.1").read_bytes())
        (destination / "COPYING.dav1d").write_bytes((dav1d_source / "COPYING").read_bytes())
        marker.write_text(json.dumps({**expected, "version": lock["version"],
                                     "target": target, "configuration": configuration}, indent=2))
    print("Local FFmpeg remuxing and AV1/HEVC conversion libraries are ready.", flush=True)

if __name__ == "__main__":
    main()
