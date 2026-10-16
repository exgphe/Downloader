"""Local, extraction-only manifests for YouTube and Instagram app downloads.

All byte transfer and adaptive-stream remuxing belong to the native download
manager. This module cannot start an external downloader or postprocessor.
"""

import json
import math
import re
import sys
import time
from http.cookiejar import Cookie
from urllib.parse import parse_qs, urlsplit

from downloader_resolver import ResolutionError, _QuietLogger, SOCKET_SECONDS

EXTRACTION_SECONDS = 60
MAX_MEDIA = 20
_HEADER_NAMES = {"user-agent": "User-Agent", "referer": "Referer", "origin": "Origin",
                 "accept": "Accept", "accept-language": "Accept-Language"}
_INSTAGRAM_HOSTS = {"instagram.com", "www.instagram.com"}
_INSTAGRAM_COOKIE_NAMES = {"sessionid", "csrftoken", "ds_user_id", "mid", "ig_did", "rur"}
_INSTAGRAM_LOGIN_MESSAGE = ("This Instagram post requires sign-in. Open instagram.com in Safari, sign in or complete its verification, "
                            "then sync its session in Downloader and try again.")


def _instagram_cookies(session_json):
    """Validate the native Keychain handoff again without files or global config.

    A usable cookie only proves that a session was synced, not that Instagram
    still accepts it. Server-side revocation is handled by the extractor errors.
    """
    invalid = "The synced Instagram session is invalid. Sign in to instagram.com in Safari and sync its session again."
    try:
        if not isinstance(session_json, str) or len(session_json.encode("utf-8")) > 65_536:
            raise ValueError()
        items = json.loads(session_json)
        if not isinstance(items, list) or len(items) > 24:
            raise ValueError()
        cookies, sessions, keys, value_bytes = [], set(), set(), 0
        now = time.time()
        for item in items:
            if not isinstance(item, dict):
                raise ValueError()
            name, value = item.get("name"), item.get("value")
            raw_domain, path = item.get("domain"), item.get("path")
            secure, http_only = item.get("secure"), item.get("httpOnly")
            if not isinstance(raw_domain, str):
                raise ValueError()
            domain = raw_domain.lower()
            if domain.startswith("."):
                domain = domain[1:]
            if (name not in _INSTAGRAM_COOKIE_NAMES or domain not in _INSTAGRAM_HOSTS or path != "/"
                    or not isinstance(value, str) or not value or len(value.encode("utf-8")) > 8192
                    or any(ord(char) <= 32 or ord(char) == 127 or char == ";" for char in value)
                    or type(secure) is not bool or type(http_only) is not bool):
                raise ValueError()
            value_bytes += len(value.encode("utf-8"))
            if value_bytes > 32_768:
                raise ValueError()
            expires = item.get("expires")
            if expires is not None:
                if type(expires) not in (int, float) or not math.isfinite(expires) or expires >= 2**63:
                    raise ValueError()
                if expires <= now:
                    raise ResolutionError("instagramSessionExpired", "The synced Instagram session has expired. Sign in to instagram.com in Safari and sync its session again.")
                expires = int(expires)
            if name == "sessionid":
                if not secure:
                    raise ValueError()
                sessions.add(value)
            key = (name, domain, path)
            if key in keys:
                raise ValueError()
            keys.add(key)
            cookies.append(Cookie(
                version=0, name=name, value=value, port=None, port_specified=False,
                domain=domain, domain_specified=True, domain_initial_dot=False,
                path=path, path_specified=True, secure=secure, expires=expires,
                discard=expires is None, comment=None, comment_url=None,
                rest={"HttpOnly": None} if http_only else {}, rfc2109=False))
        if items and len(sessions) != 1:
            raise ValueError()
        return cookies
    except ResolutionError:
        raise
    except Exception:
        # Never reflect the payload, cookie values or parser exceptions.
        raise ResolutionError("instagramSessionInvalid", invalid) from None


def _instagram_request_host(address):
    try:
        parts = urlsplit(address)
        return (parts.scheme == "https" and not parts.username and not parts.password
                and parts.port in (None, 443) and (parts.hostname or "").lower() in _INSTAGRAM_HOSTS)
    except (TypeError, ValueError):
        return False


def _instagram_effective_cookies(cookies):
    # All gallery-dl post and API requests use www.instagram.com. A host cookie
    # takes precedence over a parent-domain cookie with the same name, preventing
    # duplicate Cookie fields and a CSRF header/value mismatch. Validate the
    # complete handoff before this reduction so it cannot hide mixed sessions.
    selected = {}
    for cookie in cookies:
        if cookie.name not in selected or cookie.domain == "www.instagram.com":
            selected[cookie.name] = cookie
    return list(selected.values())


def _scoped_instagram_session(original):
    """Keep authentication inside the two exact HTTPS Instagram hosts.

    Requests prepares redirects internally without calling prepare_request.
    Checking send as well ensures their copied Cookie/CSRF headers are scoped.
    """
    import requests

    class InstagramSession(requests.Session):
        @staticmethod
        def _scope(request):
            # No HTTP Basic/.netrc Authorization is needed for the cookie bridge.
            request.headers.pop("Authorization", None)
            if not _instagram_request_host(request.url):
                for name in ("Cookie", "X-CSRFToken", "X-IG-WWW-Claim"):
                    request.headers.pop(name, None)

        def prepare_request(self, request):
            prepared = super().prepare_request(request)
            self._scope(prepared)
            return prepared

        def send(self, request, **kwargs):
            self._scope(request)
            return super().send(request, **kwargs)

    session = InstagramSession()
    session.headers = original.headers
    session.adapters = original.adapters
    session.cookies = original.cookies
    session.trust_env = False
    return session


class _QuietGalleryLogger:
    def debug(self, *args, **kwargs): pass
    def info(self, *args, **kwargs): pass
    def warning(self, *args, **kwargs): pass
    def error(self, *args, **kwargs): pass
    def traceback(self, *args, **kwargs): pass


def _source_url(address):
    if not isinstance(address, str) or len(address) > 16384:
        raise ResolutionError("invalidSource", "Provide a YouTube video or Instagram post link.")
    try:
        parts = urlsplit(address.strip())
        if (parts.scheme != "https" or parts.username or parts.password
                or parts.port not in (None, 443)):
            raise ValueError()
    except ValueError:
        raise ResolutionError("invalidSource", "Provide a YouTube video or Instagram post link.")
    host = (parts.hostname or "").lower()
    if host in ("instagram.com", "www.instagram.com"):
        match = re.fullmatch(r"/(p|reel|reels|tv|share(?:/(?:p|reel|reels|tv))?)/([A-Za-z0-9_-]+)/?", parts.path)
        if match:
            return "instagram", f"https://www.instagram.com/{match[1]}/{match[2]}/"
    if host in ("x.com", "www.x.com", "twitter.com", "www.twitter.com"):
        from downloader_resolver import _post_site
        canonical = f"https://{host}{parts.path}"
        if _post_site(canonical) == "x":
            return "x", canonical
    identifier = None
    if host in ("youtu.be", "www.youtu.be"):
        identifier = parts.path.strip("/")
    elif host in ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"):
        if parts.path == "/watch":
            identifier = (parse_qs(parts.query).get("v") or [None])[0]
        else:
            match = re.fullmatch(r"/(?:shorts|live|embed)/([A-Za-z0-9_-]+)/?", parts.path)
            if match:
                identifier = match[1]
    if identifier and re.fullmatch(r"[A-Za-z0-9_-]{11}", identifier):
        return "youtube", f"https://www.youtube.com/watch?v={identifier}"
    raise ResolutionError("invalidSource", "Provide a YouTube video or Instagram post link.")


def _allowed_media(address, site):
    if not isinstance(address, str) or len(address) > 16384:
        return False
    try:
        parts = urlsplit(address)
        host = (parts.hostname or "").lower()
        if (parts.scheme != "https" or parts.username or parts.password
                or parts.port not in (None, 443) or parts.fragment):
            return False
        if site == "youtube":
            return host == "googlevideo.com" or host.endswith(".googlevideo.com")
        return (host == "cdninstagram.com" or host.endswith(".cdninstagram.com")
                or host == "fbcdn.net" or host.endswith(".fbcdn.net"))
    except ValueError:
        return False


def _headers(*sources):
    result = {}
    for source in sources:
        if not isinstance(source, dict):
            continue
        for key, value in source.items():
            name = _HEADER_NAMES.get(str(key).lower())
            if name and isinstance(value, str) and len(value) <= 4096 and "\r" not in value and "\n" not in value:
                result[name] = value
    return result


def _number(value):
    return value if isinstance(value, (int, float)) and math.isfinite(value) and value > 0 else 0


def _integer(value):
    number = _number(value)
    return int(number) if number and number <= 2**63 - 1 else None


def _video_quality(item):
    return tuple(_number(item.get(key)) for key in ("height", "width", "fps", "quality", "vbr", "tbr", "filesize", "filesize_approx"))


def _audio_quality(item):
    preference = item.get("language_preference", 0)
    if not isinstance(preference, (int, float)) or not math.isfinite(preference):
        preference = 0
    return (preference, *(_number(item.get(key)) for key in ("audio_channels", "abr", "asr", "quality", "tbr", "filesize")))


def _codec(item, key):
    value = item.get(key)
    return value if isinstance(value, str) and value not in ("none", "unknown", "") else None


def _photos_video(item):
    codec = (_codec(item, "vcodec") or "").lower()
    return codec.startswith(("avc1", "h264", "hev1", "hvc1", "hevc", "h265"))


def _photos_audio(item):
    codec = (_codec(item, "acodec") or "").lower()
    return codec.startswith(("mp4a", "aac"))


def _direct_format(item):
    return (isinstance(item, dict) and _allowed_media(item.get("url"), "youtube")
            and item.get("protocol") in (None, "http", "https") and not item.get("fragments")
            and not item.get("has_drm") and not item.get("is_drm")
            and item.get("ext") in ("mp4", "webm", "m4a", "mkv"))


def _stream(item, role, headers):
    value = {"url": item["url"], "headers": _headers(headers, item.get("http_headers")),
             "role": role, "container": item.get("ext") or "mp4"}
    for target, source in (("videoCodec", "vcodec"), ("audioCodec", "acodec")):
        if codec := _codec(item, source):
            value[target] = codec
    # Only exact lengths can be used to reject truncated downloads. Approximate
    # sizes are not a reliable Content-Length or expected download byte count.
    if size := _integer(item.get("filesize")):
        value["expectedBytes"] = size
    return value


def _youtube_media(info, destination):
    if not isinstance(info, dict) or info.get("_type", "video") != "video":
        raise ResolutionError("unsupportedVideo", "Provide one YouTube video link, rather than a playlist.")
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        raise ResolutionError("liveVideo", "Live and upcoming YouTube broadcasts cannot be downloaded yet.")
    formats = [item for item in info.get("formats") or () if _direct_format(item)]
    videos = [item for item in formats if _codec(item, "vcodec")]
    audios = [item for item in formats if not _codec(item, "vcodec") and _codec(item, "acodec")]
    if destination == "photos":
        videos = [item for item in videos if _photos_video(item)
                  and (not _codec(item, "acodec") or _photos_audio(item))]
        audios = [item for item in audios if _photos_audio(item)]
    if not videos:
        raise ResolutionError("noCompatibleVideo" if destination == "photos" else "unsupportedVideo",
                              "This video has no Photos-compatible H.264/HEVC version. Choose Files to preserve other codecs."
                              if destination == "photos" else "This video has no directly downloadable video stream.")
    # Reject silent adaptive candidates if the source has audio but none of the
    # audio formats selected for this destination are usable. No silent success.
    source_has_audio = any(_codec(item, "acodec") for item in info.get("formats") or ())
    candidates = [item for item in videos if _codec(item, "acodec") or audios or not source_has_audio]
    if not candidates:
        raise ResolutionError("noCompatibleAudio", "This video has no compatible downloadable audio stream.")
    chosen = max(candidates, key=_video_quality)
    headers = info.get("http_headers")
    streams = [_stream(chosen, "combined" if _codec(chosen, "acodec") else "video", headers)]
    if not _codec(chosen, "acodec") and audios:
        streams.append(_stream(max(audios, key=_audio_quality), "audio", headers))
    # Matroska carries AV1/VP9 + Opus without lossy conversion, while Photos
    # gets MP4 with its compatible codecs. Progressive originals stay intact.
    container = ("mp4" if destination == "photos" else "mkv") if len(streams) > 1 else chosen["ext"]
    identifier = re.sub(r"[^A-Za-z0-9_-]", "_", str(info.get("id") or "video"))[:100]
    media = {"id": identifier, "kind": "video", "filename": f"youtube_{identifier}.{container}",
             "container": container, "streams": streams}
    for key in ("width", "height"):
        if number := _integer(chosen.get(key)):
            media[key] = number
    if all(stream.get("expectedBytes") for stream in streams):
        media["expectedBytes"] = sum(stream["expectedBytes"] for stream in streams)
    return [media]


def _youtube(address, destination, check_deadline, deadline):
    # Register before YoutubeIE builds its JS challenge request director.
    import apple_jsc_provider
    from yt_dlp.dependencies import yt_dlp_ejs
    if not callable(apple_jsc_provider.evaluate_javascript) or yt_dlp_ejs is None:
        raise ResolutionError("javascriptEngineUnavailable", "The built-in YouTube JavaScript engine is unavailable. Update or reinstall Downloader.")
    from yt_dlp import YoutubeDL
    from yt_dlp.extractor.youtube import YoutubeIE

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

    options = {"quiet": True, "no_warnings": True, "logger": _QuietLogger(),
               "socket_timeout": SOCKET_SECONDS, "retries": 0, "extractor_retries": 0,
               "fragment_retries": 0, "skip_download": True, "getcomments": False,
               "noplaylist": True, "cachedir": False, "postprocessors": [],
               "js_runtimes": {}, "remote_components": [], "nocheckcertificate": False,
               "compat_opts": set()}
    with DeadlineYoutubeDL(options, auto_init=False) as ydl:
        ydl.add_info_extractor(YoutubeIE())
        info = ydl.extract_info(address, download=False, process=False)
    return str(info.get("title") or "YouTube video")[:500], _youtube_media(info, destination)


def _instagram(address, check_deadline, deadline, session_json="[]"):
    import certifi
    from gallery_dl import exception
    from gallery_dl.extractor.instagram import InstagramPostExtractor
    from gallery_dl.extractor.message import Message
    cookies = _instagram_effective_cookies(_instagram_cookies(session_json))

    class LocalPostExtractor(InstagramPostExtractor):
        def config(self, key, default=None):
            # Avoid loading host config/cookies and avoid gallery-dl's ytdl:
            # pseudo-URLs, which invoke the external downloader.
            return {"videos": "merged", "audio": False, "previews": False,
                    "cookies": None, "username": None, "password": None,
                    "cookies-update": False, "proxy": None, "proxy-env": False, "verify": certifi.where(),
                    "timeout": SOCKET_SECONDS, "retries": 0,
                    "sleep-429": 0, "sleep-retries": 0}.get(key, default)

        def _init_session(self):
            super()._init_session()
            self.session = _scoped_instagram_session(self.session)

        def _init_cookies(self):
            # The native handoff is loaded below into this instance only. Do
            # not consult gallery-dl config, cookie files or browser databases.
            pass

        def login(self):
            # Upstream checks only '.instagram.com' and misses a www host cookie.
            # All handoff session cookies here have a valid domain/root path and
            # expiration; the server must still validate them on the request.
            self._logged_in = any(cookie.name == "sessionid" and not cookie.is_expired()
                                  for cookie in self.cookies)

        def request(self, url, **kwargs):
            check_deadline()
            kwargs["timeout"] = max(0.1, min(SOCKET_SECONDS, deadline - time.monotonic()))
            response = super().request(url, **kwargs)
            check_deadline()
            return response

        def request_json(self, url, **kwargs):
            data = super().request_json(url, **kwargs)
            if isinstance(data, dict):
                # Instagram also reports revoked sessions with HTTP 200 JSON.
                # Classify it before gallery-dl looks for a missing items key.
                reason = str(data.get("message") or data.get("error_type") or "").lower()
                if data.get("login_required") is True or reason in (
                        "login_required", "challenge_required", "checkpoint_required", "consent_required"):
                    raise exception.AuthRequired(message="Instagram requires session verification.")
            return data

        def _parse_post(self, post):
            items = post.get("carousel_media") or [post]
            expected = _integer(post.get("carousel_media_count")) or len(items)
            # The upstream extractor chooses the last API video version. Sort
            # to retain its behavior while selecting the largest resolution.
            for item in items:
                if candidates := item.get("video_versions"):
                    item["video_versions"] = sorted(candidates, key=lambda v: (
                        _number(v.get("height")), _number(v.get("width"))))
                if candidates := item.get("image_versions2", {}).get("candidates"):
                    item["image_versions2"]["candidates"] = sorted(candidates, key=lambda v: (
                        _number(v.get("height")), _number(v.get("width"))), reverse=True)
            parsed = super()._parse_post(post)
            actual = sum(not item.get("audio_url") for item in parsed.get("_files", ()))
            if actual != expected:
                raise ResolutionError("incompletePost", "Instagram did not provide every item in this post. It may require sign-in.")
            # gallery-dl also exposes separate soundtrack files, even when its
            # audio setting disables their download. They are not post images
            # or videos and must not inflate the expected visual item count.
            parsed["_files"] = [item for item in parsed.get("_files", ()) if not item.get("audio_url")]
            return parsed

    extractor = LocalPostExtractor.from_url(address)
    if not extractor:
        raise ResolutionError("invalidSource", "Provide an Instagram post or reel link.")
    media, title, expected = [], "Instagram post", None
    try:
        extractor.log = _QuietGalleryLogger()
        # initialize creates the real Requests session and upstream API. It also
        # generates a random csrftoken; replace its jar with the synced cookies
        # before __iter__ calls items/login or makes any network request.
        extractor.initialize()
        if cookies:
            extractor.cookies.clear()
            for cookie in cookies:
                extractor.cookies.set_cookie(cookie)
        csrf = next((cookie.value for cookie in cookies if cookie.name == "csrftoken"
                     and cookie.domain == "www.instagram.com"), None)
        if csrf is None:
            csrf = next((cookie.value for cookie in cookies if cookie.name == "csrftoken"), None)
        if csrf:
            extractor.csrf_token = csrf
        for message in extractor:
            check_deadline()
            if message[0] == Message.Directory:
                metadata = message[2]
                title = str(metadata.get("description") or metadata.get("post_shortcode") or title)[:500]
                expected = _integer(metadata.get("count"))
                continue
            if message[0] != Message.Url:
                raise ResolutionError("unsupportedMedia", "Instagram returned unsupported media information.")
            address, metadata = message[1:]
            if not _allowed_media(address, "instagram"):
                raise ResolutionError("unsupportedMedia", "Instagram returned an unsupported media location.")
            extension = str(metadata.get("extension") or "").lower()
            if extension == "mp4":
                kind, role = "video", "combined"
            elif extension in ("jpg", "jpeg", "png", "webp", "heic", "avif"):
                kind, role = "image", "image"
            else:
                raise ResolutionError("unsupportedMedia", "This Instagram media format is not supported.")
            identifier = re.sub(r"[^A-Za-z0-9_-]", "_", str(metadata.get("media_id") or len(media) + 1))[:100]
            stream = {"url": address, "role": role, "container": extension,
                      "headers": _headers(dict(extractor.session.headers), metadata.get("_http_headers"))}
            item = {"id": identifier, "kind": kind, "filename": f"instagram_{identifier}.{extension}",
                    "container": extension, "streams": [stream]}
            for key in ("width", "height"):
                if number := _integer(metadata.get(key)):
                    item[key] = number
            media.append(item)
            if len(media) > MAX_MEDIA:
                raise ResolutionError("tooManyMedia", "An Instagram post can contain at most 20 media items.")
    except (exception.AuthorizationError, exception.AuthenticationError) as error:
        raise ResolutionError("loginRequired", _INSTAGRAM_LOGIN_MESSAGE) from error
    except exception.NotFoundError as error:
        raise ResolutionError("postUnavailable", "This Instagram post is unavailable or private.") from error
    except exception.HttpError as error:
        if error.status in (401, 403):
            raise ResolutionError("loginRequired", _INSTAGRAM_LOGIN_MESSAGE) from error
        if error.status == 429:
            raise ResolutionError("rateLimited", "Instagram is limiting requests. Try again later.") from error
        raise
    finally:
        if extractor.session is not None:
            extractor.session.cookies.clear()
            extractor.session.close()
    if not media:
        raise ResolutionError("postUnavailable", "Instagram did not provide any media. The post may be private or require sign-in.")
    if expected and expected != len(media):
        raise ResolutionError("incompletePost", "Instagram did not provide every item in this post.")
    return title, media


def _x(address):
    from downloader_resolver import resolve_json as resolve_video_json
    result = json.loads(resolve_video_json(address))
    if not result.get("ok"):
        raise ResolutionError(result.get("code", "mediaResolutionFailed"), result.get("error", "Video extraction failed."))
    media = []
    for index, video in enumerate(result["media"]):
        media.append({"id": str(index + 1), "kind": "video", "filename": video["filename"],
                      "container": "mp4", "streams": [{"url": video["url"], "headers": {},
                      "role": "combined", "container": "mp4"}]})
    return "X video", media


def resolve_json(address, destination, session_json="[]"):
    previous_trace = sys.gettrace()
    deadline = time.monotonic() + EXTRACTION_SECONDS
    site = None

    def check_deadline():
        if time.monotonic() >= deadline:
            raise ResolutionError("mediaResolutionTimeout", "Media extraction timed out. Try again.")

    def trace(frame, event, argument):
        check_deadline()
        return trace

    try:
        if destination not in ("photos", "files"):
            raise ResolutionError("invalidDestination", "Choose Photos or Files for this download.")
        site, canonical = _source_url(address)
        sys.settrace(trace)
        if site == "youtube":
            title, media = _youtube(canonical, destination, check_deadline, deadline)
        elif site == "x":
            title, media = _x(canonical)
        else:
            title, media = _instagram(canonical, check_deadline, deadline, session_json)
        return json.dumps({"ok": True, "download": {"sourceURL": canonical, "title": title, "media": media}}, ensure_ascii=False)
    except ResolutionError as error:
        return json.dumps({"ok": False, "code": error.code, "error": str(error)})
    except Exception as error:
        reason = str(error).lower()
        if any(word in reason for word in ("login", "log in", "sign in", "sign-in", "private", "age-restricted", "age restricted", "members-only")):
            code, message = "loginRequired", (_INSTAGRAM_LOGIN_MESSAGE if site == "instagram" else
                                             "This media requires sign-in. Other apps' login sessions are not automatically shared with Downloader.")
        elif "429" in reason or "rate limit" in reason:
            code, message = "rateLimited", "The site is limiting requests. Try again later."
        elif any(word in reason for word in ("this video is unavailable", "video unavailable", "video is not available", "has been removed", "has been deleted")):
            code, message = "mediaUnavailable", "This media is unavailable or has been removed from the site."
        else:
            code, message = "mediaResolutionFailed", "The site could not provide this media. It may be unavailable, require sign-in, or its API may have changed."
        return json.dumps({"ok": False, "code": code, "error": message})
    finally:
        sys.settrace(previous_trace)
