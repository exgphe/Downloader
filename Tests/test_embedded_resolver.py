"""Offline tests for the real bootstrap's carousel/format/security behavior."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Dependencies/PythonPackages"))
spec = importlib.util.spec_from_file_location(
    "downloader_resolver", ROOT / "Shared (Extension)/Resources/Python/downloader_resolver.py")
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


def video(identifier="123", height=720, **overrides):
    result = {"id": identifier, "url": f"https://video.twimg.com/{identifier}.mp4", "height": height}
    result.update(overrides)
    return result


class FakeYDL:
    def __init__(self, nested=None):
        self.nested = nested
        self.calls = []
    def extract_info(self, address, **kwargs):
        self.calls.append((address, kwargs))
        return self.nested


class ResolverTests(unittest.TestCase):
    def items(self, info, site="x", ydl=None):
        return resolver._video_items(info, ydl or FakeYDL(), lambda: None, site)

    def test_progressive_max_quality_without_hls(self):
        info = {"id": "123", "formats": [video("low", 480), video("high", 1080),
                video("hls", 2160, protocol="m3u8_native"), video("audio", 0, vcodec="none")]}
        self.assertEqual(self.items(info)[0]["url"], "https://video.twimg.com/high.mp4")

    def test_multiple_videos_and_instagram_stills(self):
        info = {"_type": "playlist", "entries": [video("1"),
                {"id": "photo", "formats": [], "thumbnails": [{"url": "https://x/image.jpg"}]}, video("2")]}
        self.assertEqual(len(self.items(info, site="instagram")), 2)

    def test_unsupported_video_fails_whole_post(self):
        with self.assertRaises(resolver.ResolutionError) as failure:
            self.items({"_type": "playlist", "entries": [video(), video(protocol="m3u8_native")]})
        self.assertEqual(failure.exception.code, "unsupportedVideo")

    def test_no_transcoding_or_separate_audio_merge(self):
        formats = [video(acodec="none"), video("audio", vcodec="none", ext="m4a")]
        with self.assertRaises(resolver.ResolutionError):
            self.items({"formats": formats})
        # Instagram explicitly marks intentionally silent MP4s with acodec=none.
        self.assertEqual(len(self.items({"formats": [video(acodec="none")]})), 1)

    def test_cdns_and_containers_are_restricted(self):
        for address in ["https://attacker.example/movie.mp4", "http://video.twimg.com/movie.mp4",
                        "https://user:secret@video.twimg.com/movie.mp4", "https://video.twimg.com:8080/movie.mp4",
                        "https://video.twimg.com/stream.m3u8", "https://video.twimg.com/movie.mp4#fragment"]:
            with self.subTest(address=address), self.assertRaises(resolver.ResolutionError):
                self.items(video(url=address))

    def test_nested_instagram_post_uses_extract_only(self):
        ydl = FakeYDL(video())
        self.assertEqual(len(self.items({"_type": "url", "ie_key": "Instagram",
                "url": "https://instagram.com/p/AbC/"}, "instagram", ydl)), 1)
        self.assertEqual(ydl.calls[0][1], {"download": False, "process": False})
        with self.assertRaises(resolver.ResolutionError):
            self.items({"_type": "url", "url": "https://youtube.com/watch?v=anything"})

    def test_all_media_entries_are_bounded(self):
        with self.assertRaises(resolver.ResolutionError) as failure:
            self.items({"_type": "playlist", "entries": [video(str(i)) for i in range(21)]})
        self.assertEqual(failure.exception.code, "tooManyVideos")
        with self.assertRaises(resolver.ResolutionError):
            self.items({"_type": "playlist", "entries": [
                {"_type": "playlist", "entries": [video(str(i)) for i in range(11)]},
                {"_type": "playlist", "entries": [video(str(i)) for i in range(11, 22)]}]})

    def test_canonical_post_restrictions(self):
        for address in ["https://x.com/example/status/123", "https://x.com/i/web/status/123",
                        "https://www.instagram.com/p/AbC_123/"]:
            self.assertIn(resolver._post_site(address), ("x", "instagram"))
        for address in ["https://evil.example/example/status/123", "https://x.com/example/status/123?cookie=value",
                        "https://www.instagram.com/stories/example/123", "http://x.com/example/status/123"]:
            envelope = json.loads(resolver.resolve_json(address))
            self.assertFalse(envelope["ok"])
            self.assertEqual(envelope["code"], "invalidPost")

    def test_real_ytdlp_library_api_and_trace_restoration(self):
        import yt_dlp
        previous = sys.gettrace()
        with patch.object(yt_dlp.YoutubeDL, "extract_info", return_value=video()) as extraction:
            envelope = json.loads(resolver.resolve_json("https://x.com/example/status/123"))
        self.assertTrue(envelope["ok"], envelope)
        self.assertEqual(len(envelope["media"]), 1)
        extraction.assert_called_once_with("https://x.com/example/status/123", download=False, process=False)
        self.assertIs(sys.gettrace(), previous)

    def test_deadline_errors_are_actionable(self):
        with patch.object(resolver, "EXTRACTION_SECONDS", -1):
            envelope = json.loads(resolver.resolve_json("https://x.com/example/status/123"))
        self.assertEqual(envelope["code"], "videoResolutionTimeout")

    def test_extractor_failures_do_not_expose_secrets(self):
        import yt_dlp
        with patch.object(yt_dlp.YoutubeDL, "extract_info", side_effect=RuntimeError("secret-authenticated-url")):
            result = resolver.resolve_json("https://x.com/example/status/123")
        self.assertNotIn("secret-authenticated-url", result)
        self.assertEqual(json.loads(result)["code"], "videoResolutionFailed")

    def test_login_failure_is_actionable_without_leaking_url(self):
        import yt_dlp
        with patch.object(yt_dlp.YoutubeDL, "extract_info", side_effect=RuntimeError("Private video at secret-url; login required")):
            result = resolver.resolve_json("https://x.com/example/status/123")
        self.assertNotIn("secret-url", result)
        self.assertEqual(json.loads(result)["code"], "loginRequired")


if __name__ == "__main__":
    unittest.main()
