"""One isolated, time/size-bounded job. The parent terminates its process group."""

import json
from pathlib import Path
import shutil
import subprocess
import sys

from .urls import canonical_post_url


class DownloadFailure(RuntimeError):
    pass


def video_entries(info: dict, maximum: int, inherited_extractor: str = "") -> list[dict]:
    extractor = info.get("extractor_key", inherited_extractor)
    if extractor and extractor.lower() not in {"instagram", "twitter"}:
        raise DownloadFailure("The post resolved to an unsupported website.")
    entries = info.get("entries")
    if entries is not None:
        result = []
        for entry in entries:
            if not isinstance(entry, dict):
                raise DownloadFailure("A video in this post is unavailable. No partial download was returned.")
            result.extend(video_entries(entry, maximum, extractor))
            if len(result) > maximum:
                raise DownloadFailure("This post contains more videos than the configured limit.")
        return result
    if info.get("_type", "video") not in {"video", None}:
        raise DownloadFailure("The post resolved to an unsupported video source.")
    image_extensions = {"jpg", "jpeg", "png", "webp", "avif", "heic", "gif"}
    if info.get("vcodec") == "none" or info.get("ext") in image_extensions:
        return []
    formats = info.get("formats") or []
    if any(item.get("vcodec") != "none" and item.get("ext") not in image_extensions for item in formats) or (info.get("url") and info.get("ext") in {"mp4", "webm", "mov", "mkv"}):
        return [info]
    return []


def audio_expected(info: dict) -> bool:
    # Only explicitly audio-free formats establish a silent source. Missing codec
    # metadata does not excuse a lost audio track in a mux/format selection.
    formats = info.get("formats") or [info]
    return not all(item.get("acodec") == "none" for item in formats)


def probe(path: Path, ffprobe: str) -> tuple[dict, dict | None]:
    try:
        process = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries", "stream=codec_type,codec_name,pix_fmt", "-of", "json", str(path)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=30, check=True,
        )
        streams = json.loads(process.stdout).get("streams", [])
    except (subprocess.SubprocessError, ValueError) as error:
        raise DownloadFailure("The downloaded file could not be verified as a video.") from error
    video = next((item for item in streams if item.get("codec_type") == "video"), None)
    audio = next((item for item in streams if item.get("codec_type") == "audio"), None)
    if not video:
        raise DownloadFailure("The downloaded file contains no video stream.")
    return video, audio


def make_compatible(source: Path, target: Path, ffmpeg: str, ffprobe: str, expect_audio: bool) -> bool:
    video, audio = probe(source, ffprobe)
    if expect_audio and audio is None:
        raise DownloadFailure("The video was downloaded without its audio track. Update yt-dlp or provide valid server-side cookies and retry.")
    copy_video = video.get("codec_name") == "h264" and video.get("pix_fmt") == "yuv420p"
    copy_audio = audio is None or audio.get("codec_name") == "aac"
    arguments = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), "-map", "0:v:0", "-map", "0:a:0?"]
    arguments += ["-c:v", "copy"] if copy_video else [
        "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-threads", "2",
    ]
    arguments += ["-c:a", "copy"] if copy_audio else ["-c:a", "aac", "-b:a", "192k"]
    arguments += ["-movflags", "+faststart", str(target)]
    try:
        subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    except subprocess.SubprocessError as error:
        raise DownloadFailure("FFmpeg could not prepare a Photos-compatible MP4. Install FFmpeg with H.264 and AAC support.") from error
    final_video, final_audio = probe(target, ffprobe)
    if final_video.get("codec_name") != "h264" or (final_audio and final_audio.get("codec_name") != "aac"):
        raise DownloadFailure("The output could not be converted to a Photos-compatible MP4.")
    if audio is not None and final_audio is None:
        raise DownloadFailure("The MP4 conversion lost the video's audio track.")
    source.unlink()
    return final_audio is not None


class QuietLogger:
    def debug(self, _message):
        pass

    def warning(self, _message):
        pass

    def error(self, _message):
        pass


def download(directory: Path, request: dict) -> dict:
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise DownloadFailure("Install ffmpeg and ffprobe on the video server, then retry the download.")
    try:
        from yt_dlp import YoutubeDL
        from yt_dlp.extractor.instagram import InstagramIE
        from yt_dlp.extractor.twitter import TwitterIE
        from yt_dlp.postprocessor.common import PostProcessor
    except ImportError as error:
        raise DownloadFailure("yt-dlp is missing. Run uv sync in the Server directory and start the service with uv run.") from error

    post_url = canonical_post_url(request["postURL"])
    maximum = request["maxMedia"]
    collected = []

    class CollectFiles(PostProcessor):
        def run(self, information):
            filepath = information.get("filepath")
            if not filepath:
                raise DownloadFailure("yt-dlp did not report a completed video file.")
            collected.append(Path(filepath))
            return [], information

    parameters = {
        "format": "bv*[vcodec^=avc1][ext=mp4]+ba[acodec^=mp4a][ext=m4a]/b[vcodec^=avc1][acodec^=mp4a][ext=mp4]/bv*+ba/b/bv*",
        "merge_output_format": "mp4",
        "outtmpl": str(directory / "source-%(autonumber)03d.%(ext)s"),
        "paths": {"home": str(directory), "temp": str(directory)},
        "overwrites": True,
        "max_filesize": request["maxBytes"],
        "playlistend": maximum + 1,
        "max_downloads": maximum + 1,
        "socket_timeout": 15,
        "retries": 2,
        "fragment_retries": 2,
        "extractor_retries": 1,
        "concurrent_fragment_downloads": 1,
        "skip_unavailable_fragments": False,
        "ignoreerrors": False,
        "quiet": True,
        "no_warnings": True,
        "logger": QuietLogger(),
        "ffmpeg_location": ffmpeg,
        "cachedir": False,
        "writethumbnail": False,
        "writeinfojson": False,
        "writesubtitles": False,
    }
    if request.get("cookieFile"):
        # yt-dlp saves its cookie jar when it exits. Never rewrite the owner's
        # source cookie file, and do not share a mutable cookie jar across jobs.
        job_cookies = directory / "cookies.txt"
        shutil.copyfile(request["cookieFile"], job_cookies)
        job_cookies.chmod(0o600)
        parameters["cookiefile"] = str(job_cookies)
    try:
        # Register only the expected extractor. Redirects cannot dispatch a
        # generic downloader or an unrelated yt-dlp site extractor.
        with YoutubeDL(parameters, auto_init=False) as downloader:
            downloader.add_info_extractor(InstagramIE() if "instagram.com" in post_url else TwitterIE())
            downloader.add_post_processor(CollectFiles(downloader), when="after_move")
            # Instagram's extractor includes image-only carousel entries with
            # an empty formats list. Inspect the raw result before yt-dlp's
            # normal video processing rejects those image entries.
            information = downloader.extract_info(post_url, download=False, process=False)
            if not isinstance(information, dict):
                raise DownloadFailure("The post could not be read. It may be private, deleted or unavailable.")
            entries = video_entries(information, maximum)
            if not entries:
                raise DownloadFailure("No downloadable videos were found in this post.")
            media = []
            for index, entry in enumerate(entries, start=1):
                for key in ("extractor", "extractor_key", "webpage_url", "original_url"):
                    if information.get(key):
                        entry.setdefault(key, information[key])
                expect_audio = audio_expected(entry)
                before = len(collected)
                downloader.process_ie_result(entry, download=True)
                if len(collected) != before + 1:
                    raise DownloadFailure("A video in this post could not be downloaded. The file may exceed the size limit.")
                source = collected[-1]
                if source.parent.resolve() != directory.resolve() or source.is_symlink() or not source.is_file():
                    raise DownloadFailure("yt-dlp returned an invalid output path.")
                filename = f"video-{index:03d}.mp4"
                has_audio = make_compatible(source, directory / filename, ffmpeg, ffprobe, expect_audio)
                media.append({"filename": filename, "hasAudio": has_audio})
    except DownloadFailure:
        raise
    except Exception as error:
        raise DownloadFailure("The post could not be downloaded. It may be private, unavailable or rate-limited. Update yt-dlp, or configure server-side cookies if the post requires sign-in.") from error
    if request.get("cookieFile"):
        job_cookies.unlink(missing_ok=True)
    result = {"media": media}
    if any(not item["hasAudio"] for item in media):
        result["warning"] = "Some source videos have no audio track; those videos were saved without audio."
    return result


def main() -> None:
    directory = Path(sys.argv[1]).resolve()
    status = 0
    try:
        request = json.loads((directory / "request.json").read_text(encoding="utf-8"))
        result = download(directory, request)
    except Exception as error:
        message = str(error)[:400] if isinstance(error, DownloadFailure) else "The video worker could not complete this post. Check the server configuration."
        result = {"error": message}
        status = 1
    (directory / "result.json").write_text(json.dumps(result), encoding="utf-8")
    raise SystemExit(status)


if __name__ == "__main__":
    main()
