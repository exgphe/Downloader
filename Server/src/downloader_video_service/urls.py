"""Only canonical post URLs may start a download; this is not a URL proxy."""

import re
from urllib.parse import urlsplit


class InvalidPostURL(ValueError):
    pass


def canonical_post_url(value: str) -> str:
    if not isinstance(value, str) or len(value) > 2048:
        raise InvalidPostURL("Provide an Instagram or X post URL.")
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError as error:
        raise InvalidPostURL("Invalid post URL.") from error
    if (
        parts.scheme != "https"
        or parts.username is not None
        or parts.password is not None
        or port not in (None, 443)
        or parts.fragment
    ):
        raise InvalidPostURL("Use an HTTPS Instagram or X post URL without credentials.")
    host = (parts.hostname or "").lower()
    if host in {"instagram.com", "www.instagram.com"}:
        match = re.fullmatch(r"/(p|reel|tv)/([A-Za-z0-9_-]{1,128})/?", parts.path)
        if match:
            return f"https://www.instagram.com/{match[1]}/{match[2]}/"
    if host in {"x.com", "www.x.com", "twitter.com", "www.twitter.com"}:
        match = re.fullmatch(r"/i/web/status/([0-9]{1,25})/?", parts.path)
        if match:
            return f"https://x.com/i/web/status/{match[1]}"
        match = re.fullmatch(r"/([A-Za-z0-9_]{1,15})/status/([0-9]{1,25})/?", parts.path)
        if match:
            return f"https://x.com/{match[1]}/status/{match[2]}"
    raise InvalidPostURL("Only Instagram posts/reels and X status URLs are supported.")
