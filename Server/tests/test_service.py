from dataclasses import replace
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from downloader_video_service.config import Config
from downloader_video_service.jobs import JobManager, QueueFull, ServiceError
from downloader_video_service.server import VideoHTTPServer, byte_range
from downloader_video_service.urls import InvalidPostURL, canonical_post_url
from downloader_video_service.worker import DownloadFailure, audio_expected, make_compatible, video_entries


TOKEN = "t" * 48
POST = "https://www.instagram.com/p/ABC_123/"


def fake_download(_post, directory, _config):
    (directory / "video-001.mp4").write_bytes(b"0123456789")
    return {"media": [{"filename": "video-001.mp4", "hasAudio": True}]}


def await_job(manager, job_id):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        result = manager.get(job_id)
        if result and result["state"] in {"complete", "failed"}:
            return result
        time.sleep(0.01)
    raise AssertionError("Job did not finish")


class URLTests(unittest.TestCase):
    def test_canonical_supported_posts(self):
        self.assertEqual(canonical_post_url("https://instagram.com/p/ABC_123?igsh=x"), POST)
        self.assertEqual(canonical_post_url("https://www.instagram.com/reel/ABC/"), "https://www.instagram.com/reel/ABC/")
        self.assertEqual(canonical_post_url("https://twitter.com/user/status/123?s=20"), "https://x.com/user/status/123")
        self.assertEqual(canonical_post_url("https://x.com/i/web/status/123"), "https://x.com/i/web/status/123")

    def test_reject_proxy_ssrf_and_non_posts(self):
        rejected = [
            "http://x.com/user/status/123", "https://127.0.0.1/p/ABC/", "file:///etc/passwd",
            "https://instagram.com.evil.test/p/ABC/", "https://instagram.com@evil.test/p/ABC/",
            "https://user:pass@instagram.com/p/ABC/", "https://www.instagram.com:8443/p/ABC/",
            "https://instagram.com/p/ABC/#secret", "https://x.com/home", "https://x.com/user/status/nope",
            "https://instagram.com/p/%2e%2e/", "https://instagram.com/p/ABC/../DEF/", "https://instagram.com/p/ABC/extra",
            "https://[invalid/p/ABC/", "https://x.com/user/status/123;anything", "https://instagram.com/p/ABC\\def/",
        ]
        for value in rejected:
            with self.subTest(value=value), self.assertRaises(InvalidPostURL):
                canonical_post_url(value)

    def test_token_is_required(self):
        with patch.dict("os.environ", {}, clear=True), self.assertRaises(ValueError):
            Config.from_env()
        with patch.dict("os.environ", {"DOWNLOADER_TOKEN": TOKEN}, clear=True):
            self.assertEqual(Config.from_env().host, "127.0.0.1")
            self.assertEqual(Config.from_env().max_media, 20)


class JobTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.config = Config(token=TOKEN, cache_dir=Path(self.temporary.name), workers=1, max_pending=1)
        self.managers = []

    def manager(self, runner=fake_download, **arguments):
        manager = JobManager(self.config, runner=runner, **arguments)
        self.managers.append(manager)
        return manager

    def tearDown(self):
        for manager in self.managers:
            manager.close()
        self.temporary.cleanup()

    def test_completed_job_and_registered_media_only(self):
        manager = self.manager()
        job = manager.submit(POST)
        self.assertEqual(job["state"], "queued")
        result = await_job(manager, job["id"])
        self.assertEqual(result["state"], "complete")
        self.assertTrue(result["media"][0]["hasAudio"])
        self.assertIsNotNone(manager.media_path(job["id"], "video-001.mp4"))
        self.assertIsNone(manager.media_path(job["id"], "../video-001.mp4"))
        self.assertIsNone(manager.media_path(job["id"], "request.json"))
        self.assertIsNone(manager.media_path(job["id"], "missing.mp4"))

    def test_failure_deletes_media_and_returns_actionable_error(self):
        def failure(_post, directory, _config):
            (directory / "partial.mp4").write_bytes(b"partial")
            raise ServiceError("Install ffmpeg and ffprobe.")

        manager = self.manager(failure)
        job = manager.submit(POST)
        result = await_job(manager, job["id"])
        self.assertEqual(result["state"], "failed")
        self.assertIn("ffmpeg", result["error"])
        self.assertFalse((self.config.cache_dir / job["id"]).exists())
        self.assertEqual(result["media"], [])

    def test_pending_jobs_are_bounded(self):
        release = threading.Event()

        def blocked(post, directory, config):
            release.wait(2)
            return fake_download(post, directory, config)

        manager = self.manager(blocked)
        job = manager.submit(POST)
        try:
            with self.assertRaises(QueueFull):
                manager.submit(POST)
        finally:
            release.set()
        await_job(manager, job["id"])

    def test_expiry_removes_job_and_files(self):
        now = [100.0]
        manager = self.manager(clock=lambda: now[0])
        job = manager.submit(POST)
        await_job(manager, job["id"])
        now[0] += self.config.ttl_seconds + 1
        self.assertIsNone(manager.get(job["id"]))
        self.assertFalse((self.config.cache_dir / job["id"]).exists())

    def test_worker_cannot_return_traversal_or_empty_output(self):
        manager = self.manager(lambda *_: {"media": [{"filename": "../other.mp4"}]})
        job = manager.submit(POST)
        self.assertEqual(await_job(manager, job["id"])["state"], "failed")

    def test_size_limit_is_enforced(self):
        self.config = replace(self.config, max_job_bytes=5)
        manager = self.manager()
        job = manager.submit(POST)
        result = await_job(manager, job["id"])
        self.assertEqual(result["state"], "failed")
        self.assertIn("size limit", result["error"])

    def test_two_services_cannot_share_an_active_cache(self):
        self.manager()
        with self.assertRaisesRegex(ServiceError, "already using"):
            JobManager(self.config, runner=fake_download)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        config = Config(token=TOKEN, cache_dir=Path(self.temporary.name))
        self.manager = JobManager(config, runner=fake_download)
        self.server = VideoHTTPServer(("127.0.0.1", 0), self.manager)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.manager.close()
        self.temporary.cleanup()

    def request(self, method, path, body=None, authenticated=True, headers=None):
        request_headers = {"Authorization": f"Bearer {TOKEN}"} if authenticated else {}
        if body is not None:
            request_headers["Content-Type"] = "application/json"
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
        request_headers.update(headers or {})
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request(method, path, body, request_headers)
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_authentication_required_for_every_route(self):
        for method, path in [("GET", "/health"), ("POST", "/v1/jobs"), ("GET", "/v1/jobs/unknown/media/video.mp4")]:
            status, _, _ = self.request(method, path, authenticated=False)
            self.assertEqual(status, 401)
        self.assertEqual(self.request("GET", "/health", headers={"Authorization": "Bearer wrong"})[0], 401)

    def test_job_lifecycle_and_authenticated_range_download(self):
        status, _, data = self.request("POST", "/v1/jobs", {"postURL": POST})
        self.assertEqual(status, 202)
        job = json.loads(data)
        result = await_job(self.manager, job["id"])
        self.assertEqual(self.request("GET", f'/v1/jobs/{job["id"]}')[0], 200)
        media_url = result["media"][0]["url"]
        status, headers, body = self.request("GET", media_url, headers={"Range": "bytes=2-5"})
        self.assertEqual(status, 206)
        self.assertEqual(body, b"2345")
        self.assertEqual(headers["Content-Range"], "bytes 2-5/10")
        self.assertEqual(self.request("GET", media_url, authenticated=False)[0], 401)
        self.assertEqual(self.request("GET", media_url, headers={"Range": "bytes=99-"})[0], 416)
        self.assertEqual(self.request("HEAD", media_url)[2], b"")

    def test_bad_requests_and_traversal(self):
        self.assertEqual(self.request("POST", "/v1/jobs", {"postURL": "https://localhost/private"})[0], 400)
        self.assertEqual(self.request("POST", "/v1/jobs", b"not json")[0], 400)
        self.assertEqual(self.request("POST", "/v1/jobs", {"postURL": 123})[0], 400)
        self.assertEqual(self.request("POST", "/v1/jobs", b"{}", headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("POST", "/v1/jobs", b"x" * 8193)[0], 413)
        job = self.manager.submit(POST)
        await_job(self.manager, job["id"])
        base = f'/v1/jobs/{job["id"]}/media/'
        for filename in ["%2e%2e%2frequest.json", "request.json", "%2e%2e.mp4", "missing.mp4"]:
            self.assertEqual(self.request("GET", base + filename)[0], 404)


class WorkerTests(unittest.TestCase):
    def test_mixed_carousel_returns_all_videos_and_skips_images(self):
        information = {
            "extractor_key": "Instagram", "_type": "playlist", "entries": [
                {"ext": "jpg", "url": "https://cdn.test/image.jpg"},
                {"ext": "jpg", "formats": [{"url": "https://cdn.test/image.jpg", "ext": "jpg"}]},
                {"id": "first", "formats": [{"url": "https://cdn.test/1.mp4", "ext": "mp4"}]},
                {"id": "second", "formats": [{"url": "https://cdn.test/2.mp4", "ext": "mp4"}]},
            ],
        }
        self.assertEqual([entry["id"] for entry in video_entries(information, 20)], ["first", "second"])
        with self.assertRaises(DownloadFailure):
            video_entries(information, 1)

    def test_other_extractors_and_unavailable_entries_fail(self):
        with self.assertRaises(DownloadFailure):
            video_entries({"extractor_key": "Generic", "formats": [{}]}, 20)
        with self.assertRaises(DownloadFailure):
            video_entries({"extractor_key": "Instagram", "entries": [None]}, 20)

    def test_audio_cannot_disappear_silently(self):
        self.assertTrue(audio_expected({"formats": [{"acodec": "aac"}, {"acodec": "none"}]}))
        self.assertTrue(audio_expected({"formats": [{}]}))
        self.assertFalse(audio_expected({"formats": [{"acodec": "none"}]}))
        with patch("downloader_video_service.worker.probe", return_value=({"codec_name": "h264"}, None)):
            with self.assertRaisesRegex(DownloadFailure, "without its audio"):
                make_compatible(Path("source.mp4"), Path("target.mp4"), "ffmpeg", "ffprobe", True)

    def test_ranges(self):
        self.assertEqual(byte_range("bytes=2-5", 10), (2, 5))
        self.assertEqual(byte_range("bytes=-3", 10), (7, 9))
        self.assertEqual(byte_range("bytes=5-", 10), (5, 9))
        for value in ["bytes=20-", "bytes=-0", "bytes=5-1", "bytes=1-2,4-5", "bytes=-"]:
            with self.assertRaises(ValueError):
                byte_range(value, 10)


if __name__ == "__main__":
    unittest.main()
