# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Verify the product's in-process remuxer against real compressed fixtures.

Host-only FFmpeg CLI generates offline test input; the product Swift executable
links the minimal native FFmpeg libraries and never starts a media subprocess.
"""
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def probe(ffprobe, path):
    return json.loads(subprocess.check_output((ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path))))


def packet_hashes(ffprobe, path, selector):
    data = json.loads(subprocess.check_output((ffprobe, "-v", "error", "-select_streams", selector,
                                             "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(path))))
    return [packet["data_hash"] for packet in data["packets"]]


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This native test requires macOS and Xcode command-line tools.")
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("Host ffmpeg/ffprobe are required to generate and inspect local test fixtures.")
    encoders = subprocess.check_output((ffmpeg, "-hide_banner", "-encoders"), text=True)
    av1_encoder = "libaom-av1" if "libaom-av1" in encoders else "libsvtav1"
    arch = platform.machine()
    library = ROOT / "Dependencies/FFmpeg" / ("macos-" + arch)
    if not (library / "lib/libavformat.a").is_file():
        raise SystemExit("Run Scripts/bootstrap_ffmpeg.py first.")
    with tempfile.TemporaryDirectory(prefix="Downloader-remux-") as temporary:
        work = Path(temporary)
        executable = work / "MediaRemuxSmoke"
        print("Compiling the product Swift remuxer with bundled static FFmpeg libraries…", flush=True)
        run("xcrun", "swiftc", "-module-cache-path", str(work / "Modules"),
            "-I", str(library / "include"), "-L", str(library / "lib"),
            "-lavformat", "-lavcodec", "-lavutil", "-lswscale", "-ldav1d",
            "-framework", "VideoToolbox", "-framework", "CoreMedia", "-framework", "CoreVideo", "-lz", "-lbz2", "-liconv", "-lc++",
            str(ROOT / "Shared (Core)/NativeMediaRequest.swift"), str(ROOT / "Shared (Core)/MediaRemux.swift"),
            str(ROOT / "Tests/MediaRemuxSmoke.swift"), "-o", str(executable))
        cases = (("h264", "libx264", "aac", "aac", "mp4", "m4a", "mp4"),
                 ("hevc", "libx265", "aac", "aac", "mp4", "m4a", "mp4"),
                 ("vp9", "libvpx-vp9", "opus", "libopus", "webm", "webm", "mkv"),
                 ("av1", av1_encoder, "opus", "libopus", "webm", "webm", "mkv"))
        for video_codec, video_encoder, audio_codec, audio_encoder, video_ext, audio_ext, output_ext in cases:
            print(f"Generating local {video_codec}/{audio_codec} fixtures…", flush=True)
            video = work / (video_codec + "." + video_ext)
            audio = work / (audio_codec + "." + audio_ext)
            output = work / (video_codec + "-merged." + output_ext)
            video_command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                             "-i", "testsrc2=size=160x90:rate=10", "-t", "1", "-an", "-c:v", video_encoder]
            if video_codec == "av1":
                if av1_encoder == "libaom-av1":
                    video_command.extend(("-cpu-used", "8", "-row-mt", "1"))
                else:
                    video_command.extend(("-preset", "12", "-crf", "50", "-svtav1-params", "lp=2"))
            elif video_codec == "vp9":
                video_command.extend(("-deadline", "realtime", "-cpu-used", "8"))
            elif video_codec == "hevc":
                video_command.extend(("-preset", "ultrafast", "-pix_fmt", "yuv420p", "-x265-params", "log-level=error:pools=1"))
            else:
                video_command.extend(("-preset", "ultrafast", "-pix_fmt", "yuv420p"))
            run(*video_command, str(video))
            run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                "sine=frequency=1000:sample_rate=48000", "-t", "1", "-vn", "-c:a", audio_encoder, str(audio))
            run(str(executable), str(video), str(audio), str(output), output_ext)
            info = probe(ffprobe, output)
            assert [(s["codec_type"], s["codec_name"]) for s in info["streams"]] == [("video", video_codec), ("audio", audio_codec)], info
            assert info["streams"][0]["width"] == 160 and info["streams"][0]["height"] == 90
            assert 0.9 < float(info["format"]["duration"]) < 1.2
            # Packet payloads must be byte-for-byte preserved. This proves
            # remuxing changes container metadata while keeping codec quality.
            assert packet_hashes(ffprobe, video, "v:0") == packet_hashes(ffprobe, output, "v:0")
            assert packet_hashes(ffprobe, audio, "a:0") == packet_hashes(ffprobe, output, "a:0")
            print(f"Verified {video_codec}+{audio_codec} → {output_ext}: both tracks and every compressed packet preserved.", flush=True)
        print("All native lossless remux tests passed.", flush=True)


if __name__ == "__main__":
    main()
