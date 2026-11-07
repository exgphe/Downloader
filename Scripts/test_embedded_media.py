# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Offline actual-runtime test for app extraction and the JavaScriptCore bridge.

Optionally pass --player /path/to/a/YouTube/base.js to additionally exercise EJS
preprocessing of a captured real player. This test never fetches any URL.
"""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
# Appended to a temporary test copy, never the production runtime.
from pathlib import Path as _Path
import json as _json
import apple_jsc_provider as _apple
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeRequest as _Request, JsChallengeType as _Type,
    NChallengeInput as _N, SigChallengeInput as _S,
)
from yt_dlp.extractor.youtube.jsc._director import initialize_jsc_director as _director
from yt_dlp import YoutubeDL as _YDL
from yt_dlp.extractor.youtube import YoutubeIE as _IE
from gallery_dl.extractor.instagram import InstagramPostExtractor as _IG
from gallery_dl.extractor.instagram import InstagramAPI as _IGAPI
import ssl as _ssl
import certifi as _certifi
import requests as _requests
import time as _time
assert _ssl.OPENSSL_VERSION.startswith("OpenSSL") and _certifi.where()

class _FixtureIE:
    def get_param(self, key, default=None): return default
class _FixtureLogger:
    def debug(self, *args, **kwargs): pass
    def warning(self, *args, **kwargs): pass
provider = _apple.AppleJavaScriptCoreJCP(_FixtureIE(), _FixtureLogger(), {})
assert provider.is_available()
requests = [_Request(_Type.N, _N("https://www.youtube.com/s/player/test/base.js", ["abc"])),
            _Request(_Type.SIG, _S("https://www.youtube.com/s/player/test/base.js", ["xyz"]))]
# Use the actual bundled EJS library + core and invoke the real Swift callback.
prepared = '_result.n = (s) => s.split("").reverse().join(""); _result.sig = (s) => s.slice(1);'
result = _json.loads(provider._run_js_runtime(provider._construct_stdin(prepared, True, requests)))
assert result["responses"][0]["data"]["abc"] == "cba"
assert result["responses"][1]["data"]["xyz"] == "yz"
real_player = _Path(__file__).with_name("test-player.js")
if real_player.exists():
    result = _json.loads(provider._run_js_runtime(provider._construct_stdin(real_player.read_text(), False, requests)))
    assert all(response["type"] == "result" for response in result["responses"]), result
    print("Actual YouTube player n and signature solved through CPython → Swift → JavaScriptCore.", flush=True)
with _YDL({"quiet": True, "cachedir": False, "js_runtimes": {}, "remote_components": []}, auto_init=False) as ydl:
    director = _director(_IE(ydl))
    assert any(isinstance(p, _apple.AppleJavaScriptCoreJCP) and p.is_available() for p in director.providers.values())

def _format(name, height=None, video="none", audio="none", ext="mp4", abr=0):
    return {"url": f"https://rr1---sn-test.googlevideo.com/{name}", "ext": ext,
            "height": height, "vcodec": video, "acodec": audio, "abr": abr, "protocol": "https"}
def _extract(self, url, *, download, process):
    assert download is False and process is False
    assert self.params["postprocessors"] == [] and self.params["js_runtimes"] == {}
    assert self.params["remote_components"] == set() and self.params["noplaylist"] is True
    if "private0000" in url: raise RuntimeError("Private video: smoke-secret-authenticated-url")
    return {"id": "abcdefghijk", "title": "App smoke fixture", "formats": [
        _format("hevc", 2160, "hvc1.2.4.L153"),
        _format("av1", 4320, "av01.0.16M.10", ext="webm"),
        _format("aac", audio="mp4a.40.2", ext="m4a", abr=128),
        _format("opus", audio="opus", ext="webm", abr=256),
    ]}
_YDL.extract_info = _extract
def _posts(self):
    sessions = [cookie for cookie in self.cookies if cookie.name == "sessionid"]
    if sessions:
        assert self._logged_in and len(sessions) == 1
        assert sessions[0].secure and sessions[0].has_nonstandard_attr("HttpOnly")
        assert sessions[0].path == "/" and not sessions[0].is_expired()
        prepared = self.session.prepare_request(_requests.Request("GET", "https://www.instagram.com/api/v1/media/123/info/"))
        assert "sessionid=" + sessions[0].value in prepared.headers["Cookie"]
        external = self.session.prepare_request(_requests.Request("GET", "https://evil.instagram.com/"))
        assert "Cookie" not in external.headers
    return [{"pk": "123", "code": "ABC", "user": {"pk": "owner123", "username": "sample"}, "taken_at": 1700000000,
        "caption": {"text": "Cookie bridge fixture verified" if sessions else "Mixed carousel"}, "media_type": 8, "carousel_media": [
            {"pk": "image1", "code": "ABC", "media_type": 1, "image_versions2": {"candidates": [
                {"url": "https://scontent.cdninstagram.com/photo.jpg", "width": 1080, "height": 1080}]}},
            {"pk": "video1", "code": "ABC", "media_type": 2, "image_versions2": {"candidates": [
                {"url": "https://scontent.cdninstagram.com/poster.jpg", "width": 1080, "height": 1920}]},
             "video_versions": [{"url": "https://scontent.cdninstagram.com/video.mp4", "width": 1080, "height": 1920}]}]}]
_IG.posts = _posts

def _story_user(self, username):
    assert username == "imwinter" and self.extractor._logged_in
    assert any(cookie.name == "sessionid" for cookie in self.extractor.cookies)
    return {"id": "123"}
def _story_reels(self, ids):
    assert ids == ("123",)
    carousel = _posts(self.extractor)[0]
    image, video = carousel["carousel_media"]
    image = {**image, "pk": "4013638722465314116"}
    video = {**video, "pk": 4013638722465314117}
    return [{"id": "123", "user": {"pk": "123", "username": "imwinter"},
             "latest_reel_media": 1700000000, "items": [image, video]}]
_IGAPI.user = _story_user
_IGAPI.reels_media = _story_reels

# Validate the new argument and real Requests CookieJar inside bundled CPython,
# independently of the host uv interpreter and without writing credentials.
def _cookie_fixture(value):
    return [{"name": "sessionid", "value": value, "domain": "www.instagram.com", "path": "/",
             "secure": True, "httpOnly": True, "expires": _time.time() + 3600}]
for secret in ("embedded-first-session-secret", "embedded-second-session-secret"):
    payload = _json.dumps(_cookie_fixture(secret))
    result = resolve_json("https://www.instagram.com/p/ABC/", "photos", payload)
    assert _json.loads(result)["ok"] and secret not in result
    assert _json.loads(result)["download"]["title"] == "Cookie bridge fixture verified"
expired = _cookie_fixture("embedded-expired-secret")
expired[0]["expires"] = _time.time() - 1
result = resolve_json("https://www.instagram.com/p/ABC/", "photos", _json.dumps(expired))
assert _json.loads(result)["code"] == "instagramSessionExpired" and "embedded-expired-secret" not in result
'''

OFFLINE_SESSION_STORE = r'''
import Foundation
/// Test-only session source: no access to the user's Keychain.
enum InstagramSessionStore {
    static func resolverJSON() throws -> String {
        let cookies: [[String: Any]] = [[
            "name": "sessionid", "value": "native-smoke-session-secret", "domain": "www.instagram.com",
            "path": "/", "secure": true, "httpOnly": true, "expires": Date().timeIntervalSince1970 + 3600
        ]]
        return String(data: try JSONSerialization.data(withJSONObject: cookies), encoding: .utf8)!
    }
}
'''


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--player", type=Path)
    parser.add_argument("--debug-python", action="store_true", help="Print errors from the temporary test runtime only")
    parser.add_argument("--live-url", help="Also resolve real site metadata after offline tests; no media is downloaded")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This test requires macOS and Xcode command-line tools.")
    framework = ROOT / "Dependencies/Python/macOS/Python.xcframework/macos-arm64_x86_64"
    with tempfile.TemporaryDirectory(prefix="Downloader-app-runtime-") as temporary:
        work = Path(temporary)
        app = work / "RuntimeSmoke.app"
        extension = app / "Contents/PlugIns/RuntimeSmoke.appex/Contents"
        executable = extension / "MacOS/RuntimeSmoke"
        executable.parent.mkdir(parents=True)
        (extension / "Resources").mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.Downloader.RuntimeHost", "CFBundleExecutable": "RuntimeHost",
            "CFBundlePackageType": "APPL", "CFBundleName": "RuntimeHost"}))
        (extension / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.Downloader.RuntimeSmoke", "CFBundleExecutable": "RuntimeSmoke",
            "CFBundlePackageType": "XPC!", "CFBundleName": "RuntimeSmoke"}))
        swift_source = ROOT / "Shared (Core)/EmbeddedPython.swift"
        if args.debug_python:
            debug_source = work / "EmbeddedPython.swift"
            debug_source.write_text(swift_source.read_text().replace("PyErr_Clear()", "PyErr_Print()"))
            swift_source = debug_source
        session_source = ROOT / "Shared (Core)/InstagramSessionStore.swift"
        if not args.live_url:
            session_source = work / "InstagramSessionStore.swift"
            session_source.write_text(OFFLINE_SESSION_STORE)
        print("Compiling the actual embedded media runtime…", flush=True)
        run("xcrun", "swiftc", "-module-cache-path", str(work / "Modules"), "-F", str(framework),
            "-framework", "Python", "-framework", "JavaScriptCore",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks",
            str(swift_source), str(ROOT / "Shared (Core)/EmbeddedPythonResources.swift"),
            str(session_source),
            str(ROOT / "Shared (Core)/NativeMediaRequest.swift"),
            str(ROOT / "Shared (Core)/HEVCConversionSettings.swift"), str(ROOT / "Shared (Core)/DownloadModels.swift"), str(ROOT / "Tests/EmbeddedMediaSmoke.swift"), "-o", str(executable))
        run(sys.executable, str(ROOT / "Scripts/package_runtime.py"), "--platform", "macosx",
            "--arch", platform.machine(), "--bundle", str(app))
        scripts = extension / "Resources/python-bootstrap"
        if args.live_url:
            production = (ROOT / "Shared (Extension)/Resources/Python/app_resolver.py").read_text()
            if args.debug_python:
                production = production.replace('reason = str(error).lower()', 'print(type(error).__name__, str(error), file=sys.stderr, flush=True)\n        reason = str(error).lower()')
            (scripts / "app_resolver.py").write_text(production)
            run(str(executable), "--live-url", args.live_url)
        else:
            with (scripts / "app_resolver.py").open("a") as script:
                script.write(FIXTURE)
            if args.player:
                shutil.copy2(args.player, scripts / "test-player.js")
            run(str(executable))


if __name__ == "__main__":
    main()
