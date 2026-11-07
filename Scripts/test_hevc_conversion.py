# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Exercise the product's static FFmpeg transcoder on real offline AV1 fixtures.

The host FFmpeg CLI generates/inspects fixtures only. Product conversion runs
inside the compiled Swift process with bundled libraries.
"""
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)

def probe(path):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))

def audio_hashes(path):
    data = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(path)]))
    return [packet["data_hash"] for packet in data["packets"]]

def main():
    if platform.system() != "Darwin" or not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise SystemExit("macOS, Xcode, and host ffmpeg/ffprobe are required for this offline test.")
    library = ROOT / "Dependencies/FFmpeg" / ("macos-" + platform.machine())
    encoders = subprocess.check_output(["ffmpeg", "-hide_banner", "-encoders"], text=True)
    av1_encoder = "libaom-av1" if "libaom-av1" in encoders else "libsvtav1"
    av1_options = ["-cpu-used", "8", "-row-mt", "1"] if av1_encoder == "libaom-av1" else ["-preset", "12", "-svtav1-params", "lp=2", "-crf", "36"]
    with tempfile.TemporaryDirectory(prefix="Downloader-HEVC-") as directory:
        work = Path(directory)
        executable = work / "HEVCTranscoderSmoke"
        run("xcrun", "swiftc", "-module-cache-path", str(work / "Modules"),
            "-I", str(library / "include"), "-L", str(library / "lib"),
            "-lavformat", "-lavcodec", "-lavutil", "-lswscale", "-ldav1d", "-lz", "-liconv",
            "-framework", "VideoToolbox", "-framework", "CoreMedia", "-framework", "CoreVideo",
            str(ROOT / "Shared (Core)/NativeMediaRequest.swift"), str(ROOT / "Shared (Core)/DownloadModels.swift"),
            str(ROOT / "Shared (Core)/HEVCConversionSettings.swift"), str(ROOT / "Shared (Core)/HEVCTranscoder.swift"),
            str(ROOT / "Tests/HEVCTranscoderSmoke.swift"), "-o", str(executable))
        cases = [("8bit-aac", "yuv420p", "aac", "mp4", "bt709", "bt709"),
                 ("10bit-opus", "yuv420p10le", "libopus", "mkv", "bt2020", "smpte2084"),
                 ("downscale-aac", "yuv420p", "aac", "mp4", "bt709", "bt709")]
        for name, pixel_format, audio_codec, container, primaries, transfer in cases:
            source = work / (name + ".mkv")
            output = work / (name + "-hevc." + container)
            if av1_encoder == "libsvtav1":
                values = "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9" if primaries == "bt2020" else "color-primaries=1:transfer-characteristics=1:matrix-coefficients=1"
                av1_options = ["-preset", "12", "-svtav1-params", "lp=2:" + values, "-crf", "36"]
            source_size = "160x1440" if name == "downscale-aac" else "320x180"
            run("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=" + source_size + ":rate=24",
                "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000", "-t", "1",
                "-c:v", av1_encoder, *av1_options, "-pix_fmt", pixel_format,
                "-color_primaries", primaries, "-color_trc", transfer,
                "-colorspace", "bt2020nc" if primaries == "bt2020" else "bt709", "-color_range", "tv",
                "-c:a", audio_codec, str(source))
            run(str(executable), str(source), str(output), container, "1080" if name == "downscale-aac" else "original", "2")
            before, after = probe(source), probe(output)
            video = next(stream for stream in after["streams"] if stream["codec_type"] == "video")
            assert video["codec_name"] == "hevc", video
            assert (video["width"], video["height"]) == ((120, 1080) if name == "downscale-aac" else (320, 180)), video
            assert video["nb_frames"] == "24" if container == "mp4" else abs(float(video["avg_frame_rate"].split('/')[0]) / float(video["avg_frame_rate"].split('/')[1]) - 24) < 0.1
            assert video.get("color_primaries") == primaries and video.get("color_transfer") == transfer, video
            assert video["pix_fmt"] == ("yuv420p10le" if pixel_format.endswith("10le") else "yuv420p"), video
            assert abs(float(after["format"]["duration"]) - float(before["format"]["duration"])) < 0.1
            assert audio_hashes(source) == audio_hashes(output), "Audio packets must remain byte-for-byte identical"
            run("ffmpeg", "-v", "error", "-i", str(output), "-f", "null", "-")
            run(str(executable), str(source), str(work / "cancelled.mkv"), "mkv", "original", "2", "cancel")
            print(f"Verified {name}: HEVC, frame dimensions, colour, bit depth, audio packets, decoding and cancellation", flush=True)
        print("Real bundled AV1/HEVC conversion smoke checks passed.", flush=True)

if __name__ == "__main__":
    main()
