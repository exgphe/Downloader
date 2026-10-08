"""Extract Instagram/X progressive videos inside the bundled CPython interpreter.

yt-dlp handles site extraction only. Swift owns downloading and PhotoKit saving;
this module never runs a shell, an external downloader, or a postprocessor.
"""

import json
import re
import sys
import time
from urllib.parse import urlsplit

MAX_VIDEOS = 20
EXTRACTION_SECONDS = 40
SOCKET_SECONDS = 8


class ResolutionError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _post_site(address):
    parts = urlsplit(address)
    if (parts.scheme != "https" or parts.username or parts.password
            or parts.port not in (None, 443) or parts.query or parts.fragment):
        raise ResolutionError("invalidPost", "Provide a supported Instagram or X post URL.")
    host = (parts.hostname or "").lower()
    if host in ("instagram.com", "www.instagram.com") and re.fullmatch(
            r"/(?:p|reel|tv)/[A-Za-z0-9_-]+/?", parts.path):
        return "instagram"
    if host in ("x.com", "www.x.com", "twitter.com", "www.twitter.com") and re.fullmatch(
            r"/(?:[A-Za-z0-9_]+/status/[0-9]+|i/web/status/[0-9]+)/?", parts.path):
        return "x"
    raise ResolutionError("invalidPost", "Provide a supported Instagram or X post URL.")


def _allowed_media(address):
    if not isinstance(address, str) or len(address) > 16384:
        return False
    try:
        parts = urlsplit(address)
        host = (parts.hostname or "").lower()
        return (parts.scheme == "https" and not parts.username and not parts.password
                and parts.port in (None, 443) and not parts.fragment
                and (host == "video.twimg.com" or host == "pbs.twimg.com"
                     or host == "cdninstagram.com" or host.endswith(".cdninstagram.com")
                     or host == "fbcdn.net" or host.endswith(".fbcdn.net")))
    except ValueError:
        return False


def _progressive(format_info, has_separate_audio):
    address = format_info.get("url")
    if not _allowed_media(address) or format_info.get("protocol") not in (None, "http", "https"):
        return False
    extension = format_info.get("ext") or urlsplit(address).path.rsplit(".", 1)[-1].lower()
    return (extension == "mp4" and format_info.get("vcodec") != "none"
            and not format_info.get("fragments") and not format_info.get("requested_formats")
            and not (format_info.get("acodec") == "none" and has_separate_audio))


def _quality(format_info):
    def number(key):
        value = format_info.get(key)
        return value if isinstance(value, (int, float)) else 0
    return (number("height"), number("width"), number("tbr"), number("filesize"))


def _video_items(info, ydl, check_deadline, site, depth=0):
    check_deadline()
    if not isinstance(info, dict) or depth > 3:
        raise ResolutionError("invalidVideoResult", "The post returned unsupported video information.")
    result_type = info.get("_type", "video")
    if result_type in ("playlist", "multi_video"):
        result = []
        for index, entry in enumerate(info.get("entries") or ()):
            check_deadline()
            if index >= MAX_VIDEOS:
                raise ResolutionError("tooManyVideos", "A post can contain at most 20 media items.")
            result.extend(_video_items(entry, ydl, check_deadline, site, depth + 1))
            if len(result) > MAX_VIDEOS:
                raise ResolutionError("tooManyVideos", "A post can contain at most 20 media items.")
        return result
    if result_type in ("url", "url_transparent"):
        # Some Instagram carousels return URLs to the individual video posts.
        nested_url = info.get("url")
        if _post_site(nested_url) != site or info.get("ie_key") not in (None, "Instagram", "Twitter"):
            raise ResolutionError("unsupportedVideo", "This post links to an unsupported video source.")
        nested = ydl.extract_info(nested_url, download=False, process=False)
        return _video_items(nested, ydl, check_deadline, site, depth + 1)

    formats = info.get("formats") or ([info] if info.get("url") else [])
    # Instagram API carousels also contain still-image entries. Leave their
    # images to the page collector instead of processing them as videos.
    if site == "instagram" and not formats and info.get("thumbnails") and not info.get("duration"):
        return []
    has_separate_audio = any(f.get("vcodec") == "none" for f in formats)
    candidates = [f for f in formats if _progressive(f, has_separate_audio)]
    if not candidates:
        raise ResolutionError("unsupportedVideo", "This video has no downloadable MP4. Live or segmented streams are not supported yet.")
    chosen = max(candidates, key=_quality)
    identifier = re.sub(r"[^A-Za-z0-9_-]", "_", str(info.get("id") or "video"))[:100]
    return [{"url": chosen["url"], "kind": "video", "filename": f"{site}_{identifier}.mp4"}]


class _QuietLogger:
    def debug(self, message):
        pass
    def warning(self, message):
        pass
    def error(self, message):
        pass


def resolve_json(address):
    """Return a JSON envelope so Swift can preserve actionable error codes."""
    previous_trace = sys.gettrace()
    deadline = time.monotonic() + EXTRACTION_SECONDS

    def check_deadline():
        if time.monotonic() >= deadline:
            raise ResolutionError("videoResolutionTimeout", "Video extraction timed out. Try again.")

    def trace(frame, event, argument):
        check_deadline()
        return trace

    try:
        site = _post_site(address)
        # Install the deadline before import as well as extraction. Network
        # operations use short socket timeouts; tracing bounds Python work.
        sys.settrace(trace)
        import certifi
        from yt_dlp import YoutubeDL
        from yt_dlp.extractor.instagram import InstagramIE
        from yt_dlp.extractor.twitter import TwitterIE

        options = {
            "quiet": True, "no_warnings": True, "logger": _QuietLogger(),
            "socket_timeout": SOCKET_SECONDS, "retries": 0, "extractor_retries": 0,
            "fragment_retries": 0, "skip_download": True, "getcomments": False,
            "noplaylist": False, "cachedir": False, "postprocessors": [],
            "js_runtimes": {}, "remote_components": [], "nocheckcertificate": False,
            "compat_opts": set(),
        }
        # CPython/OpenSSL does not automatically use the Apple trust store.
        # certifi is bundled with the app, with certificate verification on.
        # yt-dlp's urllib handler already uses certifi when it is importable;
        # this is deliberately not a global monkeypatch of SSL settings.
        class DeadlineYoutubeDL(YoutubeDL):
            def urlopen(self, request):
                check_deadline()
                if hasattr(request, "extensions"):
                    request.extensions["timeout"] = max(0.1, min(SOCKET_SECONDS, deadline - time.monotonic()))
                response = super().urlopen(request)
                try:
                    check_deadline()
                except ResolutionError:
                    response.close()
                    raise
                return response

        with DeadlineYoutubeDL(options, auto_init=False) as ydl:
            ydl.add_info_extractor(InstagramIE() if site == "instagram" else TwitterIE())
            info = ydl.extract_info(address, download=False, process=False)
            media = _video_items(info, ydl, check_deadline, site)
            if not media:
                raise ResolutionError("noVideo", "No downloadable video was found in this post.")
            unique = {item["url"]: item for item in media}
            return json.dumps({"ok": True, "media": list(unique.values())}, ensure_ascii=False)
    except ResolutionError as error:
        return json.dumps({"ok": False, "code": error.code, "error": str(error)})
    except Exception as error:
        # Extractor failures can contain sensitive site URLs; return a useful
        # site-independent message and do not forward Python tracebacks.
        if any(phrase in str(error).lower() for phrase in (
                "login required", "log in", "sign in", "private", "not authorized", "protected")):
            return json.dumps({"ok": False, "code": "loginRequired",
                               "error": "This video requires sign-in. Safari's login session is not automatically shared with the built-in video engine."})
        return json.dumps({"ok": False, "code": "videoResolutionFailed",
                           "error": "The site could not provide this video. It may require sign-in, or its download API may have changed."})
    finally:
        sys.settrace(previous_trace)
