# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Offline native smoke test of the actual packaged CPython/yt-dlp runtime.

Run after bootstrapping dependencies:
    uv run --no-project --script Scripts/test_embedded_runtime.py

No network is used. Fixtures modify only copies in a temporary app bundle;
the production resolver and the Xcode project are never modified.
"""
from __future__ import annotations

import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SUCCESS_FIXTURE = r'''
# Offline fixture appended only to the temporary smoke-test bundle.
import ssl as _smoke_ssl
import certifi as _smoke_certifi
from yt_dlp import YoutubeDL as _SmokeYDL
from yt_dlp.networking._helper import make_ssl_context as _smoke_ssl_context
assert _smoke_ssl.OPENSSL_VERSION.startswith("OpenSSL")
assert _smoke_ssl_context().cert_store_stats()["x509_ca"] > 100
assert _smoke_certifi.where()

def _smoke_extract(self, url, *, download, process):
    assert download is False and process is False
    assert self.params["postprocessors"] == []
    assert self.params["js_runtimes"] == {}
    assert self.params["remote_components"] == set()
    assert self.params["noplaylist"] is False
    if url.rstrip("/").endswith("/999"):
        raise RuntimeError("Private video; login required: smoke-secret-authenticated-url")
    entries = [
        {"id": "first", "formats": [
            {"url": "https://video.twimg.com/first-low.mp4", "height": 480},
            {"url": "https://video.twimg.com/first-high.mp4", "height": 1080},
            {"url": "https://video.twimg.com/live.m3u8", "height": 2160, "protocol": "m3u8_native"},
        ]},
        {"id": "second", "formats": [{"url": "https://video.twimg.com/second.mp4", "height": 720}]},
    ]
    if "instagram.com" in url:
        entries.insert(1, {"id": "photo", "formats": [], "thumbnails": [{"url": "https://scontent.cdninstagram.com/photo.jpg"}]})
    return {"_type": "playlist", "entries": entries}

_SmokeYDL.extract_info = _smoke_extract
'''
FAILURE_FIXTURE = '\nraise RuntimeError("smoke-secret-initialization-failure")\n'


def run(*command: str) -> None:
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("This native smoke test requires macOS and the Xcode command-line tools.")
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        raise SystemExit(f"Unsupported macOS architecture: {arch}")
    framework_parent = ROOT / "Dependencies/Python/macOS/Python.xcframework/macos-arm64_x86_64"
    headers = framework_parent / "Python.framework/Headers/Python.h"
    if not headers.is_file() or not (ROOT / "Dependencies/PythonPackages/yt_dlp/__init__.py").is_file():
        raise SystemExit("Bundled dependencies are missing. Run uv run --no-project --script Scripts/bootstrap_runtime.py first.")
    with tempfile.TemporaryDirectory(prefix="Downloader-embedded-runtime-") as temporary:
        work = Path(temporary)
        app = work / "RuntimeSmoke.app"
        extension = app / "Contents/PlugIns/RuntimeSmoke.appex/Contents"
        executable = extension / "MacOS/RuntimeSmoke"
        executable.parent.mkdir(parents=True)
        (extension / "Resources").mkdir()
        (extension / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.Downloader.RuntimeSmoke",
            "CFBundleExecutable": "RuntimeSmoke", "CFBundleName": "RuntimeSmoke",
            "CFBundlePackageType": "XPC!",
        }))
        # Import the unmodified actual C headers without relying on a developer's
        # global Python installation or a previously generated Xcode module map.
        module = work / "CModule"
        module.mkdir()
        (module / "module.modulemap").write_text(
            f'module Python [system] {{ umbrella header {json.dumps(str(headers))} export * }}\n')
        print("Compiling the real Swift embedded-runtime helper…", flush=True)
        run("xcrun", "swiftc", "-module-cache-path", str(work / "ModuleCache"),
            "-I", str(module), "-F", str(framework_parent), "-framework", "Python",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks",
            str(ROOT / "Shared (Extension)/EmbeddedPython.swift"),
            str(ROOT / "Shared (Extension)/NativeMediaRequest.swift"),
            str(ROOT / "Tests/EmbeddedPythonSmoke.swift"), "-o", str(executable))

        production = (ROOT / "Shared (Extension)/Resources/Python/downloader_resolver.py").read_text()
        for mode, fixture in (("success", SUCCESS_FIXTURE), ("failure", FAILURE_FIXTURE)):
            print(f"Packaging and running the {mode} fixture with actual Python.framework…", flush=True)
            run(sys.executable, str(ROOT / "Scripts/package_runtime.py"), "--platform", "macosx",
                "--arch", arch, "--bundle", str(app))
            bootstrap = extension / "Resources/Python/downloader_resolver.py"
            bootstrap.write_text(production + fixture)
            # Use a new process for failure: CPython is initialized once, and its
            # cached startup failure is deliberately permanent in that process.
            arguments = ("--failure",) if mode == "failure" else ()
            run(str(executable), *arguments)
        print("Offline native embedded-runtime smoke tests passed.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
