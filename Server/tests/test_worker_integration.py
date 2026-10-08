"""Real yt-dlp/FFmpeg pipeline against generated media, with no platform access."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from downloader_video_service.config import Config
from downloader_video_service.jobs import JobManager
from downloader_video_service.server import VideoHTTPServer
from downloader_video_service.worker import download, probe


AVAILABLE = bool(importlib.util.find_spec("yt_dlp") and shutil.which("ffmpeg") and shutil.which("ffprobe"))


@unittest.skipUnless(AVAILABLE, "Install yt-dlp and ffmpeg/ffprobe to run the media pipeline test")
class MediaPipelineTests(unittest.TestCase):
    def test_all_post_videos_pass_real_downloader_merge_and_mp4_verification(self):
        from yt_dlp.extractor.instagram import InstagramIE

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fixture.mp4"
            subprocess.run([
                shutil.which("ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "color=c=blue:s=32x32:r=5", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                "-t", "0.4", "-c:v", "libx264", "-c:a", "aac", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(source),
            ], check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            video_source = root / "video-only.mp4"
            audio_source = root / "audio-only.mp4"
            subprocess.run([
                shutil.which("ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(source),
                "-map", "0:v:0", "-c", "copy", "-an", str(video_source),
                "-map", "0:a:0", "-c", "copy", "-vn", str(audio_source),
            ], check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            def fixture_download(_post, directory, _config):
                for index, fixture in enumerate((source, video_source, audio_source), start=1):
                    shutil.copyfile(fixture, directory / f"video-{index:03d}.mp4")
                return {"media": [{"filename": f"video-{index:03d}.mp4", "hasAudio": True} for index in (1, 2, 3)]}

            config = Config(token="t" * 48, cache_dir=root / "cache")
            manager = JobManager(config, runner=fixture_download)
            server = VideoHTTPServer(("127.0.0.1", 0), manager)
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            try:
                from test_service import await_job
                job = manager.submit("https://www.instagram.com/p/ABC/")
                result = await_job(manager, job["id"])
                fixture_urls = [f"http://127.0.0.1:{server.server_port}{item['url']}" for item in result["media"]]
                headers = {"Authorization": f"Bearer {config.token}"}
                combined = {"url": fixture_urls[0], "format_id": "http", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "http_headers": headers}
                video_only = {"url": fixture_urls[1], "format_id": "video", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "http_headers": headers}
                audio_only = {"url": fixture_urls[2], "format_id": "audio", "ext": "m4a", "vcodec": "none", "acodec": "mp4a", "http_headers": headers}
                information = {
                    "_type": "playlist", "id": "post", "title": "Test carousel", "entries": [
                        {"id": "image", "formats": [], "thumbnails": [{"url": "https://cdn.test/image.jpg"}]},
                        {"id": "1", "title": "Combined tracks", "formats": [combined]},
                        {"id": "2", "title": "Separate video and audio", "formats": [video_only, audio_only]},
                        {"id": "3", "title": "Originally silent video", "formats": [video_only]},
                    ],
                }
                output = root / "output"
                output.mkdir()
                with patch.object(InstagramIE, "_real_extract", return_value=information):
                    result = download(output, {
                        "postURL": "https://www.instagram.com/p/ABC/", "maxMedia": 20,
                        "maxBytes": 1024 * 1024, "cookieFile": None,
                    })
                self.assertEqual(len(result["media"]), 3)
                for index, media in enumerate(result["media"], start=1):
                    video, audio = probe(output / media["filename"], shutil.which("ffprobe"))
                    self.assertEqual(video["codec_name"], "h264")
                    if index == 3:
                        self.assertIsNone(audio)
                        self.assertFalse(media["hasAudio"])
                    else:
                        self.assertEqual(audio["codec_name"], "aac")
                        self.assertTrue(media["hasAudio"])
                self.assertIn("no audio", result["warning"])
                self.assertFalse(list(output.glob("source-*")))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(2)
                manager.close()


if __name__ == "__main__":
    unittest.main()
