"""Offline tests for destination/codec policy and actual gallery-dl integration."""
import importlib.util
import json
from pathlib import Path
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Dependencies/PythonPackages"))
sys.path.insert(0, str(ROOT / "Shared (Extension)/Resources/Python"))
import app_resolver as resolver
import apple_jsc_provider


def fmt(name, *, height=None, video="none", audio="none", container="mp4", **kwargs):
    result = {"format_id": name, "url": f"https://rr1---sn-test.googlevideo.com/{name}",
              "ext": container, "vcodec": video, "acodec": audio, "protocol": "https"}
    if height:
        result.update(height=height, width=height * 16 // 9)
    result.update(kwargs)
    return result


def youtube():
    return {"id": "abcdefghijk", "title": "Quality policy fixture", "formats": [
        fmt("avc-1080", height=1080, video="avc1.640028", acodec="none", fps=30),
        fmt("hevc-2160", height=2160, video="hvc1.2.4.L153", acodec="none", fps=60),
        fmt("av1-4320", height=4320, video="av01.0.16M.10", container="webm", fps=60),
        fmt("aac", audio="mp4a.40.2", container="m4a", abr=128, filesize=200),
        fmt("opus", audio="opus", container="webm", abr=256, filesize=300),
        fmt("progressive", height=720, video="avc1.64001f", audio="mp4a.40.2"),
    ]}


def session(value="test-session-cookie", domain=".instagram.com", **overrides):
    cookie = {"name": "sessionid", "value": value, "domain": domain, "path": "/",
              "secure": True, "httpOnly": True, "expires": time.time() + 3600}
    cookie.update(overrides)
    return cookie


def image_post():
    return {"pk": "123", "code": "ABC", "user": {"pk": "owner", "username": "sample"},
            "taken_at": 1700000000, "caption": None, "media_type": 1,
            "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/photo.jpg", "width": 1080, "height": 1080}]}}


STORY_URL = "https://www.instagram.com/stories/imwinter/4013638722465314116/"
STORY_ID = "4013638722465314116"


def story_reel(kind="image", *, pk=STORY_ID):
    selected = {**image_post(), "pk": pk}
    selected["image_versions2"]["candidates"] = [
        {"url": "https://scontent.cdninstagram.com/low.jpg", "width": 320, "height": 480},
        {"url": "https://scontent.cdninstagram.com/story.jpg", "width": 1080, "height": 1920}]
    if kind == "video":
        selected["media_type"] = 2
        selected["video_versions"] = [
            {"url": "https://scontent.cdninstagram.com/story.mp4", "width": 1080, "height": 1920},
            {"url": "https://scontent.cdninstagram.com/low.mp4", "width": 320, "height": 480}]
    return {"id": "123", "user": {"pk": "123", "username": "imwinter"},
            "latest_reel_media": 1700000000, "items": [image_post(), selected, {**image_post(), "pk": "456"}]}


class AppResolverTests(unittest.TestCase):
    def setUp(self):
        # Host tests do not execute JS. The separate native runtime smoke test
        # exercises the actual Python → Swift → JavaScriptCore callback.
        self.native = patch.object(apple_jsc_provider, "evaluate_javascript", lambda script: "{}")
        self.native.start()
        self.addCleanup(self.native.stop)

    def test_photos_highest_compatible_video_and_audio(self):
        media = resolver._youtube_media(youtube(), "photos")[0]
        self.assertEqual(media["height"], 2160)
        self.assertEqual(media["container"], "mp4")
        self.assertEqual([stream["role"] for stream in media["streams"]], ["video", "audio"])
        self.assertEqual(media["streams"][0]["videoCodec"], "hvc1.2.4.L153")
        self.assertEqual(media["streams"][1]["audioCodec"], "mp4a.40.2")

    def test_files_preserves_highest_av1_and_opus_quality(self):
        media = resolver._youtube_media(youtube(), "files")[0]
        self.assertEqual(media["height"], 4320)
        self.assertEqual(media["container"], "mkv")
        self.assertEqual(media["streams"][0]["videoCodec"], "av01.0.16M.10")
        self.assertEqual(media["streams"][1]["audioCodec"], "opus")

    def test_photos_can_select_av1_only_when_conversion_is_enabled(self):
        media = resolver._youtube_media(youtube(), "photos", allow_av1=True)[0]
        self.assertEqual(media["height"], 4320)
        self.assertEqual(media["container"], "mkv")
        self.assertEqual(media["streams"][0]["videoCodec"], "av01.0.16M.10")
        self.assertEqual(media["streams"][1]["audioCodec"], "mp4a.40.2")
        self.assertEqual(resolver._youtube_media(youtube(), "photos")[0]["height"], 2160)

    def test_conversion_never_allows_vp9_or_incompatible_audio_in_photos(self):
        info = youtube()
        info["formats"] = [fmt("vp9", height=4320, video="vp09"), info["formats"][3]]
        with self.assertRaises(resolver.ResolutionError):
            resolver._youtube_media(info, "photos", allow_av1=True)
        info["formats"] = [fmt("av1", height=4320, video="av01"), fmt("opus", audio="opus", container="webm")]
        with self.assertRaises(resolver.ResolutionError):
            resolver._youtube_media(info, "photos", allow_av1=True)

    def test_original_audio_language_is_preserved_before_quality(self):
        info = youtube()
        info["formats"][3]["language_preference"] = 10
        info["formats"][4]["language_preference"] = -1
        media = resolver._youtube_media(info, "files")[0]
        self.assertEqual(media["streams"][1]["audioCodec"], "mp4a.40.2")

    def test_progressive_original_without_remux(self):
        info = youtube()
        info["formats"] = [info["formats"][-1]]
        media = resolver._youtube_media(info, "files")[0]
        self.assertEqual(media["container"], "mp4")
        self.assertEqual(len(media["streams"]), 1)
        self.assertEqual(media["streams"][0]["role"], "combined")

    def test_rejects_missing_compatible_audio_without_silent_success(self):
        info = youtube()
        info["formats"] = [info["formats"][0], info["formats"][4]]
        with self.assertRaises(resolver.ResolutionError) as failure:
            resolver._youtube_media(info, "photos")
        self.assertEqual(failure.exception.code, "noCompatibleAudio")

    def test_rejects_unknown_codec_drm_segments_and_unapproved_urls(self):
        for overrides in ({"vcodec": "vp09"}, {"vcodec": "unknown"}, {"has_drm": True},
                          {"protocol": "m3u8_native"}, {"fragments": [{}]},
                          {"url": "https://evil.example/video.mp4"},
                          {"url": "https://user:secret@video.googlevideo.com/media"},
                          {"url": "https://video.googlevideo.com:8080/media"}):
            item = fmt("reject", height=4320, video="avc1", audio="mp4a.40.2")
            item.update(overrides)
            with self.subTest(overrides=overrides), self.assertRaises(resolver.ResolutionError):
                resolver._youtube_media({"formats": [item]}, "photos")

    def test_live_and_playlist_rejected(self):
        for attributes in ({"_type": "playlist"}, {"is_live": True}, {"live_status": "is_upcoming"}):
            with self.subTest(attributes=attributes), self.assertRaises(resolver.ResolutionError):
                resolver._youtube_media({**youtube(), **attributes}, "files")

    def test_exact_sizes_only_and_headers_filtered(self):
        info = {"id": "abcdefghijk", "http_headers": {"Cookie": "secret", "Referer": "https://www.youtube.com/"},
                "formats": [fmt("one", height=720, video="avc1", audio="mp4a.40.2", filesize_approx=500,
                                http_headers={"Authorization": "secret", "User-Agent": "one\nInjected: yes"})]}
        media = resolver._youtube_media(info, "photos")[0]
        self.assertNotIn("expectedBytes", media)
        self.assertNotIn("expectedBytes", media["streams"][0])
        self.assertEqual(media["streams"][0]["headers"], {"Referer": "https://www.youtube.com/"})

    def test_shared_urls_canonicalized_and_parameters_removed(self):
        for address in ("https://youtu.be/abcdefghijk?si=secret", "https://m.youtube.com/watch?v=abcdefghijk&t=5",
                        "https://www.youtube.com/shorts/abcdefghijk", "https://youtube.com/live/abcdefghijk"):
            self.assertEqual(resolver._source_url(address), ("youtube", "https://www.youtube.com/watch?v=abcdefghijk"))
        self.assertEqual(resolver._source_url("https://www.instagram.com/p/ABC/?igsh=secret"),
                         ("instagram", "https://www.instagram.com/p/ABC/"))
        self.assertEqual(resolver._source_url(STORY_URL + "?utm_source=ig_story_item_share&rpxt=tracking"),
                         ("instagram", STORY_URL))
        for address in ("https://instagram.com/stories/imwinter/", "https://instagram.com/stories/imwinter/no/",
                        "https://instagram.com/stories/highlights/123/", "https://instagram.com/stories/imwinter/123/extra",
                        "https://instagram.com.evil.test/stories/imwinter/123/", "http://instagram.com/stories/imwinter/123/"):
            self.assertEqual(json.loads(resolver.resolve_json(address, "photos"))["code"], "invalidSource")
        for address in ("https://www.youtube.com/playlist?list=anything", "https://evil.example/abcdefghijk",
                        "http://youtu.be/abcdefghijk", "https://user@youtu.be/abcdefghijk",
                        "https://youtu.be/notvalid"):
            self.assertEqual(json.loads(resolver.resolve_json(address, "files"))["code"], "invalidSource")

    def test_real_ytdlp_api_is_extract_only_and_restores_trace(self):
        import yt_dlp
        previous = sys.gettrace()
        with patch.object(yt_dlp.YoutubeDL, "extract_info", return_value=youtube()) as extraction:
            result = json.loads(resolver.resolve_json("https://youtu.be/abcdefghijk", "files"))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["download"]["media"][0]["height"], 4320)
        extraction.assert_called_once_with("https://www.youtube.com/watch?v=abcdefghijk", download=False, process=False)
        self.assertIs(previous, sys.gettrace())

    def test_errors_are_actionable_and_do_not_leak_site_urls(self):
        import yt_dlp
        for reason, code in (("Private video with secret-authenticated-url", "loginRequired"),
                             ("HTTP Error 429 secret-authenticated-url", "rateLimited"),
                             ("This video is unavailable secret-authenticated-url", "mediaUnavailable"),
                             ("Unexpected secret-authenticated-url", "mediaResolutionFailed")):
            with patch.object(yt_dlp.YoutubeDL, "extract_info", side_effect=RuntimeError(reason)):
                result = resolver.resolve_json("https://youtu.be/abcdefghijk", "photos")
            self.assertEqual(json.loads(result)["code"], code)
            self.assertNotIn("secret-authenticated-url", result)

    def test_deadline_and_destination_validation(self):
        with patch.object(resolver, "EXTRACTION_SECONDS", -1):
            result = json.loads(resolver.resolve_json("https://youtu.be/abcdefghijk", "files"))
        self.assertEqual(result["code"], "mediaResolutionTimeout")
        self.assertEqual(json.loads(resolver.resolve_json("https://youtu.be/abcdefghijk", "bad"))["code"], "invalidDestination")
        with patch.object(apple_jsc_provider, "evaluate_javascript", None):
            self.assertEqual(json.loads(resolver.resolve_json("https://youtu.be/abcdefghijk", "files"))["code"], "javascriptEngineUnavailable")

    def test_actual_gallery_carousel_is_complete_and_chooses_highest_quality(self):
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        post = {"pk": "123", "code": "ABC", "user": {"pk": "owner123", "username": "sample"}, "taken_at": 1700000000,
                "caption": {"text": "Mixed carousel"}, "media_type": 8,
                "carousel_media": [
                    {"pk": "image1", "code": "ABC", "media_type": 1,
                     "image_versions2": {"candidates": [
                         {"url": "https://scontent.cdninstagram.com/low.jpg", "width": 320, "height": 320},
                         {"url": "https://scontent.cdninstagram.com/high.jpg", "width": 1080, "height": 1080}]}},
                    {"pk": "video1", "code": "ABC", "media_type": 2,
                     "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/poster.jpg", "width": 1080, "height": 1920}]},
                     "video_versions": [
                         {"url": "https://scontent.cdninstagram.com/high.mp4", "width": 1080, "height": 1920},
                         {"url": "https://scontent.cdninstagram.com/low.mp4", "width": 320, "height": 480}]}]}
        with patch.object(InstagramPostExtractor, "posts", return_value=[post]):
            result = json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "photos"))
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(result["download"]["media"]), 2)
        self.assertEqual(result["download"]["media"][0]["streams"][0]["url"], "https://scontent.cdninstagram.com/high.jpg")
        self.assertEqual(result["download"]["media"][1]["streams"][0]["url"], "https://scontent.cdninstagram.com/high.mp4")

    def test_story_selects_only_requested_item_and_preserves_large_ids(self):
        from gallery_dl.extractor.instagram import InstagramAPI
        for kind, pk in (("image", STORY_ID), ("video", int(STORY_ID)), ("image", STORY_ID + "_123")):
            with self.subTest(kind=kind, pk=pk), \
                    patch.object(InstagramAPI, "user", return_value={"id": "123"}) as owner, \
                    patch.object(InstagramAPI, "reels_media", return_value=[story_reel(kind, pk=pk)]) as reels:
                result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps([session()])))
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["download"]["title"], "Instagram Story · imwinter")
            media = result["download"]["media"]
            self.assertEqual(len(media), 1)
            self.assertEqual(media[0]["id"], STORY_ID)
            self.assertEqual(media[0]["kind"], kind)
            self.assertEqual(media[0]["streams"][0]["url"],
                             "https://scontent.cdninstagram.com/story." + ("mp4" if kind == "video" else "jpg"))
            owner.assert_called_once_with("imwinter")
            reels.assert_called_once_with(("123",))

    def test_story_requires_synced_login_before_network_and_never_uses_cookie_files(self):
        from gallery_dl.extractor.instagram import InstagramAPI
        with patch.object(InstagramAPI, "user") as owner:
            result = json.loads(resolver.resolve_json(STORY_URL, "photos"))
        self.assertEqual(result["code"], "loginRequired")
        owner.assert_not_called()

        def user(api, username):
            extractor = api.extractor
            self.assertTrue(extractor._logged_in)
            self.assertEqual(extractor.config("user-cache"), "memory")
            self.assertEqual(extractor.config("videos"), "merged")
            self.assertIsNone(extractor.config("cookies"))
            self.assertEqual([cookie.value for cookie in extractor.cookies if cookie.name == "sessionid"], ["story-session-secret"])
            return {"id": "123"}
        with patch.object(InstagramAPI, "user", user), \
                patch.object(InstagramAPI, "reels_media", return_value=[story_reel()]):
            result = resolver.resolve_json(STORY_URL, "files", json.dumps([session("story-session-secret")]))
        self.assertTrue(json.loads(result)["ok"])
        self.assertNotIn("story-session-secret", result)

    def test_expired_deleted_or_wrong_owner_story_never_downloads_another_item(self):
        from gallery_dl.extractor.instagram import InstagramAPI
        for reels in ([], [story_reel(pk="111")], [{**story_reel(), "id": "999"}]):
            with self.subTest(reels=reels), patch.object(InstagramAPI, "user", return_value={"id": "123"}), \
                    patch.object(InstagramAPI, "reels_media", return_value=reels):
                result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps([session()])))
            self.assertEqual(result["code"], "storyUnavailable")
            self.assertIn("expired", result["error"])
            self.assertNotIn("download", result)

    def test_missing_story_media_and_video_are_errors_instead_of_thumbnail_success(self):
        from gallery_dl.extractor.instagram import InstagramAPI
        for kind, field, code in (("image", "image_versions2", "incompletePost"),
                                  ("video", "video_versions", "unsupportedMedia")):
            reel = story_reel(kind)
            del reel["items"][1][field]
            with patch.object(InstagramAPI, "user", return_value={"id": "123"}), \
                    patch.object(InstagramAPI, "reels_media", return_value=[reel]):
                result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps([session()])))
            self.assertEqual(result["code"], code)
            self.assertNotIn("download", result)

    def test_story_auth_and_rate_limit_errors_are_actionable(self):
        from gallery_dl import exception
        from gallery_dl.extractor.instagram import InstagramAPI
        for error, code in ((exception.AuthRequired("cookies"), "loginRequired"),
                            (exception.HttpError("HTTP", SimpleNamespace(status_code=429)), "rateLimited"),
                            (exception.HttpError("HTTP", SimpleNamespace(status_code=404)), "storyUnavailable")):
            with patch.object(InstagramAPI, "user", side_effect=error):
                result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps([session()])))
            self.assertEqual(result["code"], code)

    def test_real_story_api_uses_scoped_cookies_and_local_cache(self):
        import requests
        from gallery_dl import cache
        from gallery_dl.extractor.instagram import InstagramAPI
        from gallery_dl.extractor.common import CACHE_MEMORY
        before = dict(CACHE_MEMORY)
        calls = []
        def response(url, payload):
            result = requests.Response()
            result.status_code = 200
            result.url = url
            result._content = json.dumps(payload).encode()
            return result
        def request(extractor, url, **kwargs):
            calls.append(url)
            prepared = extractor.session.prepare_request(requests.Request("GET", url))
            if "www.instagram.com" in url:
                self.assertIn("sessionid=real-story-fixture", prepared.headers["Cookie"])
            if "topsearch" in url:
                return response(url, {"users": [{"user": {"id": "123", "pk": "123", "username": "imwinter"}}]})
            if url.endswith("/graphql/query"):
                self.assertEqual(kwargs["headers"]["X-CSRFToken"], "synced-story-csrf")
                self.assertEqual(kwargs["data"]["fb_dtsg"], "fixture-dtsg")
                variables = json.loads(kwargs["data"]["variables"])
                self.assertEqual(variables["reel_ids"], ["123"])
                return response(url, {"data": {"xdt_api__v1__feed__reels_media__connection":
                    {"edges": [{"node": story_reel("video")}], "page_info": {"has_next_page": False}}}})
            result = response(url, {})
            result._content = b'<script id="__eqmc">{"l":"fixture-lsd","f":"fixture-dtsg"}</script>'
            return result
        imported = [session("real-story-fixture"), session("synced-story-csrf", name="csrftoken", httpOnly=False)]
        with patch.object(resolver, "SOCKET_SECONDS", 1), \
                patch("gallery_dl.extractor.instagram.InstagramExtractor.request", request), \
                patch.object(cache, "database", side_effect=AssertionError("Story extraction must not read or write a SQLite cache")):
            result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps(imported)))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["download"]["media"][0]["kind"], "video")
        self.assertIn("https://www.instagram.com/graphql/query", calls)
        self.assertEqual(CACHE_MEMORY, before)

    def test_story_graphql_login_error_is_not_reported_as_expired(self):
        import requests
        from gallery_dl.extractor.instagram import InstagramAPI
        def request(extractor, url, **kwargs):
            response = requests.Response()
            response.status_code = 200
            response.url = url
            response._content = b'{"login_required":true,"message":"login_required"}'
            return response
        def reels(api, ids):
            api.extractor.request("https://www.instagram.com/graphql/query", method="POST")
            return []
        with patch.object(InstagramAPI, "user", return_value={"id": "123"}), \
                patch.object(InstagramAPI, "reels_media", reels), \
                patch("gallery_dl.extractor.instagram.InstagramExtractor.request", request):
            result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps([session()])))
        self.assertEqual(result["code"], "loginRequired")

    def test_story_graphql_api_failure_is_not_reported_as_expired(self):
        import requests
        from gallery_dl.extractor.instagram import InstagramAPI
        for body in (b'{"errors":[{"message":"API failure"}]}', b'{"data":null}', b'<html>unavailable</html>'):
            def request(extractor, url, **kwargs):
                response = requests.Response()
                response.status_code = 200
                response.url = url
                response._content = body
                return response
            def reels(api, ids):
                api.extractor.request("https://www.instagram.com/graphql/query", method="POST")
                return []
            with self.subTest(body=body), patch.object(InstagramAPI, "user", return_value={"id": "123"}), \
                    patch.object(InstagramAPI, "reels_media", reels), \
                    patch("gallery_dl.extractor.instagram.InstagramExtractor.request", request):
                result = json.loads(resolver.resolve_json(STORY_URL, "photos", json.dumps([session()])))
            self.assertEqual(result["code"], "mediaResolutionFailed")

    def test_gallery_auth_unavailable_and_partial_errors_are_not_success(self):
        from gallery_dl import exception
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        for error, code in ((exception.AuthRequired("cookies"), "loginRequired"),
                            (exception.NotFoundError("post"), "postUnavailable")):
            with patch.object(InstagramPostExtractor, "posts", side_effect=error):
                result = json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "photos"))
            self.assertFalse(result["ok"])
            self.assertEqual(result["code"], code)
        with patch.object(InstagramPostExtractor, "posts", return_value=[]):
            self.assertEqual(json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "files"))["code"], "postUnavailable")

    def test_gallery_missing_carousel_media_fails_instead_of_partial_success(self):
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        post = {"pk": "123", "code": "ABC", "user": {"pk": "owner", "username": "sample"},
                "taken_at": 1700000000, "caption": None, "media_type": 8,
                "carousel_media_count": 2, "carousel_media": [
                    {"pk": "first", "code": "ABC", "media_type": 1,
                     "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/first.jpg", "width": 1080, "height": 1080}]}},
                    {"pk": "missing", "code": "ABC", "media_type": 1}]}
        with patch.object(InstagramPostExtractor, "posts", return_value=[post]):
            result = json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "photos"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "incompletePost")
        self.assertNotIn("download", result)

    def test_session_cookie_metadata_preserved_in_real_cookiejar(self):
        import requests
        cookies = resolver._instagram_cookies(json.dumps([session()]))
        jar = requests.cookies.RequestsCookieJar()
        jar.set_cookie(cookies[0])
        stored = next(iter(jar))
        self.assertEqual(stored.name, "sessionid")
        self.assertEqual(stored.domain, "instagram.com")
        self.assertEqual(stored.path, "/")
        self.assertTrue(stored.secure)
        self.assertTrue(stored.has_nonstandard_attr("HttpOnly"))
        self.assertGreater(stored.expires, time.time())
        prepared = requests.Request("GET", "https://www.instagram.com/api/v1/media/123/info/").prepare()
        prepared.prepare_cookies(jar)
        self.assertIn("sessionid=test-session-cookie", prepared.headers["Cookie"])
        session_cookie = resolver._instagram_cookies(json.dumps([session(expires=None)]))[0]
        self.assertIsNone(session_cookie.expires)
        self.assertTrue(session_cookie.discard)

    def test_invalid_cookie_domain_path_name_flags_and_values_rejected(self):
        invalid = [{"domain": "evil.instagram.com"}, {"domain": "instagram.com.evil.example"},
                   {"domain": "scontent.cdninstagram.com"}, {"domain": "..instagram.com"},
                   {"path": "/accounts/"}, {"name": "unknown"}, {"value": ""},
                   {"value": "test-secret\r\nInjected: yes"}, {"value": "test-secret; injected=yes"},
                   {"value": "test-secret\x00"}, {"value": "test secret"}, {"value": "x" * 8193},
                   {"secure": False}, {"secure": "true"}, {"httpOnly": 1},
                   {"expires": float("nan")}, {"expires": float("inf")}, {"expires": True}]
        for overrides in invalid:
            with self.subTest(overrides=overrides), self.assertRaises(resolver.ResolutionError) as failure:
                resolver._instagram_cookies(json.dumps([session(**overrides)]))
            self.assertEqual(failure.exception.code, "instagramSessionInvalid")
            self.assertNotIn("test-secret", str(failure.exception))
        for payload in ("not json test-secret", "{}", '["test-secret"]', "[" + " " * 65_536 + "]"):
            with self.subTest(payload=payload[:40]), self.assertRaises(resolver.ResolutionError) as failure:
                resolver._instagram_cookies(payload)
            self.assertEqual(failure.exception.code, "instagramSessionInvalid")
            self.assertNotIn("test-secret", str(failure.exception))
        oversized = [session("x" * 8192, name=name) for name in ("sessionid", "csrftoken", "ds_user_id", "mid", "ig_did")]
        with self.assertRaises(resolver.ResolutionError):
            resolver._instagram_cookies(json.dumps(oversized))

    def test_expired_or_conflicting_sessions_are_not_accepted_as_logged_in(self):
        with self.assertRaises(resolver.ResolutionError) as expired:
            resolver._instagram_cookies(json.dumps([session(expires=time.time() - 1)]))
        self.assertEqual(expired.exception.code, "instagramSessionExpired")
        for cookies in ([session("first"), session("second", "www.instagram.com")],
                        [session(), session()],
                        [session(name="csrftoken", httpOnly=False)]):
            with self.subTest(cookies=cookies), self.assertRaises(resolver.ResolutionError) as failure:
                resolver._instagram_cookies(json.dumps(cookies))
            self.assertEqual(failure.exception.code, "instagramSessionInvalid")
        self.assertEqual(resolver._instagram_cookies("[]"), [])
        same_session = resolver._instagram_cookies(json.dumps([session("same-session"), session("same-session", "www.instagram.com")]))
        self.assertEqual(len(same_session), 2)
        self.assertEqual({cookie.value for cookie in same_session}, {"same-session"})

    def test_imported_session_and_csrf_used_by_actual_gallery_login_flow(self):
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        import requests
        imported = [session(domain="www.instagram.com"), session("synced-csrf", name="csrftoken", httpOnly=False)]
        observed = []

        def posts(extractor):
            self.assertTrue(extractor._logged_in)
            self.assertEqual(extractor.csrf_token, "synced-csrf")
            self.assertEqual(extractor.config("cookies"), None)
            self.assertEqual(extractor.config("cookies-update"), False)
            self.assertFalse(extractor.session.trust_env)
            stored = [cookie for cookie in extractor.cookies if cookie.name == "sessionid"]
            self.assertEqual(len(stored), 1)
            self.assertTrue(stored[0].has_nonstandard_attr("HttpOnly"))
            prepared = extractor.session.prepare_request(requests.Request("GET", "https://www.instagram.com/api/v1/media/123/info/"))
            self.assertIn("sessionid=test-session-cookie", prepared.headers["Cookie"])
            self.assertIn("csrftoken=synced-csrf", prepared.headers["Cookie"])
            observed.append(extractor.cookies)
            return [image_post()]

        with patch.object(InstagramPostExtractor, "posts", posts), patch.object(InstagramPostExtractor, "_login_impl", side_effect=AssertionError("Password login called")):
            result = json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "photos", json.dumps(imported)))
        self.assertTrue(result["ok"], result)
        self.assertNotIn("test-session-cookie", json.dumps(result))
        self.assertNotIn("synced-csrf", json.dumps(result))
        self.assertFalse(observed[0], "The closed instance clears its cookie jar")

    def test_www_cookie_precedence_is_order_independent_and_matches_csrf_header(self):
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        import requests
        root = session("parent-csrf-secret", name="csrftoken", httpOnly=False)
        www = session("www-csrf-secret", domain="www.instagram.com", name="csrftoken", httpOnly=False)
        for csrf in ([root, www], [www, root]):
            imported = [session(), session(domain="www.instagram.com"), *csrf]

            def posts(extractor):
                self.assertTrue(extractor._logged_in)
                self.assertEqual(extractor.csrf_token, "www-csrf-secret")
                self.assertEqual([(cookie.name, cookie.domain) for cookie in extractor.cookies],
                                 [("sessionid", "www.instagram.com"), ("csrftoken", "www.instagram.com")])
                prepared = extractor.session.prepare_request(requests.Request(
                    "GET", "https://www.instagram.com/api/v1/media/123/info/",
                    headers={"X-CSRFToken": extractor.csrf_token}))
                self.assertEqual(prepared.headers["X-CSRFToken"], "www-csrf-secret")
                self.assertEqual(prepared.headers["Cookie"].count("csrftoken="), 1)
                self.assertEqual(prepared.headers["Cookie"].count("sessionid="), 1)
                self.assertIn("csrftoken=www-csrf-secret", prepared.headers["Cookie"])
                self.assertNotIn("parent-csrf-secret", prepared.headers["Cookie"])
                return [image_post()]

            with self.subTest(order=csrf), patch.object(InstagramPostExtractor, "posts", posts):
                result = json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "photos", json.dumps(imported)))
            self.assertTrue(result["ok"], result)

        with self.assertRaises(resolver.ResolutionError):
            resolver._instagram_effective_cookies(resolver._instagram_cookies(json.dumps([
                session("root-account"), session("www-account", domain="www.instagram.com")])))

    def test_cookie_and_auth_headers_never_sent_to_external_or_subdomain_hosts(self):
        import requests
        scoped = resolver._scoped_instagram_session(requests.Session())
        scoped.cookies.set_cookie(resolver._instagram_cookies(json.dumps([session()]))[0])
        scoped.headers.update({"X-CSRFToken": "test-csrf-secret", "Authorization": "test-auth-secret"})
        for address in ("https://scontent.cdninstagram.com/photo.jpg", "https://evil.instagram.com/",
                        "http://www.instagram.com/api/", "https://www.instagram.com:8443/api/",
                        "https://youtube.com/"):
            prepared = scoped.prepare_request(requests.Request("GET", address))
            self.assertNotIn("Cookie", prepared.headers)
            self.assertNotIn("Authorization", prepared.headers)
            self.assertNotIn("X-CSRFToken", prepared.headers)
        prepared = scoped.prepare_request(requests.Request("GET", "https://www.instagram.com/api/"))
        self.assertIn("sessionid=test-session-cookie", prepared.headers["Cookie"])
        self.assertNotIn("Authorization", prepared.headers)
        scoped.close()

    def test_requests_redirects_recheck_cookie_scope(self):
        import requests
        from requests.adapters import BaseAdapter
        calls = []

        class FakeAdapter(BaseAdapter):
            def send(self, request, **kwargs):
                calls.append(dict(request.headers))
                response = requests.Response()
                response.url, response.request = request.url, request
                response._content = b"fixture"
                response.status_code = 302 if len(calls) == 1 else 200
                if response.status_code == 302:
                    response.headers["Location"] = "https://evil.instagram.com/redirect-target"
                return response
            def close(self): pass

        scoped = resolver._scoped_instagram_session(requests.Session())
        scoped.cookies.set_cookie(resolver._instagram_cookies(json.dumps([session()]))[0])
        scoped.headers["X-CSRFToken"] = "test-csrf-secret"
        scoped.mount("https://", FakeAdapter())
        scoped.get("https://www.instagram.com/api/", allow_redirects=True)
        self.assertEqual(len(calls), 2)
        self.assertIn("sessionid=test-session-cookie", calls[0]["Cookie"])
        self.assertNotIn("Cookie", calls[1])
        self.assertNotIn("X-CSRFToken", calls[1])
        scoped.close()

    def test_two_gallery_requests_do_not_share_cookies(self):
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        observed = []

        def posts(extractor):
            observed.append((id(extractor.session), [cookie.value for cookie in extractor.cookies if cookie.name == "sessionid"]))
            return [image_post()]

        with patch.object(InstagramPostExtractor, "posts", posts):
            for value in ("first-session-secret", "second-session-secret", None):
                payload = json.dumps([session(value)]) if value else "[]"
                result = json.loads(resolver.resolve_json("https://instagram.com/p/ABC/", "photos", payload))
                self.assertTrue(result["ok"], result)
        self.assertEqual([values for _, values in observed], [["first-session-secret"], ["second-session-secret"], []])

    def test_auth_failure_after_cookie_import_guides_sync_without_secrets(self):
        from gallery_dl import exception
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        imported = json.dumps([session("never-log-this-session-secret")])
        with patch.object(InstagramPostExtractor, "posts", side_effect=exception.AuthRequired(message="Private never-log-this-session-secret")):
            result = resolver.resolve_json("https://instagram.com/p/ABC/", "photos", imported)
        envelope = json.loads(result)
        self.assertEqual(envelope["code"], "loginRequired")
        self.assertIn("Safari", envelope["error"])
        self.assertIn("sync", envelope["error"])
        self.assertNotIn("never-log-this-session-secret", result)

    def test_http200_login_and_challenge_failures_guide_safari_sync(self):
        from gallery_dl.extractor.instagram import InstagramPostExtractor
        for reason in ("login_required", "challenge_required", "checkpoint_required"):
            with patch.object(InstagramPostExtractor, "request_json", return_value={
                    "status": "fail", "message": reason, "debug_secret": "never-log-this-session-secret"}):
                result = resolver.resolve_json("https://instagram.com/p/ABC/", "photos", json.dumps([session("never-log-this-session-secret")]))
            envelope = json.loads(result)
            self.assertEqual(envelope["code"], "loginRequired")
            self.assertIn("Safari", envelope["error"])
            self.assertIn("sync", envelope["error"])
            self.assertNotIn("never-log-this-session-secret", result)

    def test_instagram_session_payload_ignored_for_youtube_and_x(self):
        import yt_dlp
        with patch.object(yt_dlp.YoutubeDL, "extract_info", return_value=youtube()):
            result = json.loads(resolver.resolve_json("https://youtu.be/abcdefghijk", "files", "malformed-secret-session-json"))
        self.assertTrue(result["ok"], result)
        with patch.object(resolver, "_x", return_value=("X video", [])) as x:
            result = json.loads(resolver.resolve_json("https://x.com/user/status/123", "photos", "malformed-secret-session-json"))
        self.assertTrue(result["ok"], result)
        x.assert_called_once_with("https://x.com/user/status/123")


if __name__ == "__main__":
    unittest.main()
