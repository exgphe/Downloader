# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Bounded checks for Apple runtime slice and framework loader packaging."""
import importlib.util
import argparse
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packaging = script("package_runtime")
bootstrap = script("bootstrap_runtime")


def runtime_inputs(stdlib: Path, packages: Path) -> None:
    for relative in ("encodings/__init__.py", "ssl.py"):
        destination = stdlib / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"stdlib fixture")
    for relative in (
        "yt_dlp/__init__.py", "gallery_dl/__init__.py", "certifi/__init__.py", "certifi/cacert.pem",
        "requests/__init__.py", "urllib3/__init__.py", "idna/__init__.py", "charset_normalizer/__init__.py",
        "yt_dlp_ejs/__init__.py", "yt_dlp_ejs/yt/solver/core.min.js", "yt_dlp_ejs/yt/solver/lib.min.js",
    ):
        destination = packages / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"package fixture")


class RuntimePackagingTests(unittest.TestCase):
    def test_xcode_signed_build_uses_parent_certificate_for_every_embedded_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dependencies = root / "Dependencies"
            xcframework = dependencies / "Python/macOS/Python.xcframework"
            framework = xcframework / "macos-universal/Python.framework"
            version = framework / "Versions/3.13"
            stdlib = version / "lib/python3.13/lib-dynload"
            stdlib.mkdir(parents=True)
            (stdlib / "_ssl.so").write_bytes(b"native module fixture")
            (version / "lib/libssl.3.dylib").write_bytes(b"dependency fixture")
            (version / "Python").write_bytes(b"interpreter fixture")
            (xcframework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
                "LibraryIdentifier": "macos-universal", "LibraryPath": "Python.framework",
                "SupportedPlatform": "macos", "SupportedArchitectures": ["arm64"],
            }]}))
            runtime_inputs(stdlib.parent, dependencies / "PythonPackages")
            app = root / "Downloader.app"
            extension = app / "Contents/PlugIns/Downloader.appex/Contents"
            (extension / "Resources").mkdir(parents=True)
            (extension / "MacOS").mkdir()
            (extension / "MacOS/Downloader").write_bytes(b"executable fixture")
            (extension / "MacOS/Downloader.debug.dylib").write_bytes(b"debug library fixture")
            (extension / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.downloader.extension", "CFBundleExecutable": "Downloader",
            }))
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.downloader", "CFBundleExecutable": "Downloader",
            }))
            share = app / "Contents/PlugIns/Share.appex/Contents"
            (share / "Resources").mkdir(parents=True)
            (share / "MacOS").mkdir()
            (share / "MacOS/Share").write_bytes(b"share executable fixture")
            (share / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.downloader.share", "CFBundleExecutable": "Share",
            }))
            args = argparse.Namespace(platform="macosx", dependencies=dependencies, architectures=["arm64"],
                                      inspect=False, bundle=app)
            certificate = "0123456789ABCDEF0123456789ABCDEF01234567"
            environment = {"CODE_SIGNING_ALLOWED": "YES", "EXPANDED_CODE_SIGN_IDENTITY": certificate}
            with patch.dict(packaging.os.environ, environment, clear=True), \
                    patch.object(packaging, "thin"), patch.object(packaging, "run") as commands:
                packaging.package(args)
            signatures = [call.args for call in commands.call_args_list if call.args[0] == "/usr/bin/codesign"]
            self.assertEqual(len(signatures), 6)
            self.assertTrue(all(command[command.index("--sign") + 1] == certificate for command in signatures))
            self.assertEqual(Path(signatures[-1][-1]), share.parent.resolve())
            self.assertIn("--preserve-metadata=identifier,entitlements,flags", signatures[-1])
            for resources in (app / "Contents/Resources", extension / "Resources", share / "Resources"):
                for name in ("downloader_resolver.py", "app_resolver.py", "apple_jsc_provider.py"):
                    packaging.require_exact_file(resources, "python-bootstrap/" + name)
                packaging.require_exact_file(resources, "python/lib/python3.13/encodings/__init__.py")
            environment["CODE_SIGNING_ALLOWED"] = "NO"
            with patch.dict(packaging.os.environ, environment, clear=True), \
                    patch.object(packaging, "thin"), patch.object(packaging, "run") as commands:
                packaging.package(args)
            signatures = [call.args for call in commands.call_args_list if call.args[0] == "/usr/bin/codesign"]
            self.assertTrue(signatures)
            self.assertTrue(all(command[command.index("--sign") + 1] == "-" for command in signatures))
            # A stale complete output must not hide an incomplete input on an
            # incremental build. Missing gallery-dl must stop packaging.
            (dependencies / "PythonPackages/gallery_dl/__init__.py").unlink()
            with patch.dict(packaging.os.environ, environment, clear=True), \
                    patch.object(packaging, "thin"), patch.object(packaging, "run"):
                with self.assertRaisesRegex(FileNotFoundError, "gallery_dl/__init__.py"):
                    packaging.package(args)
            with patch.dict(packaging.os.environ, {"CODE_SIGNING_ALLOWED": "YES"}, clear=True), \
                    patch.object(packaging, "run") as commands:
                with self.assertRaisesRegex(ValueError, "EXPANDED_CODE_SIGN_IDENTITY is empty"):
                    packaging.package(args)
                commands.assert_not_called()

    def test_macos_module_maps_use_versioned_framework_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            xcframework = Path(temporary)
            framework = xcframework / "macos-universal/Python.framework"
            (framework / "Versions/3.13").mkdir(parents=True)
            (framework / "Versions/Current").symlink_to("3.13", target_is_directory=True)
            (xcframework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
                "LibraryIdentifier": "macos-universal", "LibraryPath": "Python.framework",
            }]}))
            bootstrap.module_maps(xcframework)
            self.assertTrue((framework / "Modules").is_symlink())
            self.assertEqual((framework / "Modules").readlink(), Path("Versions/Current/Modules"))
            self.assertIn('framework module Python', (framework / "Versions/3.13/Modules/module.modulemap").read_text())
            bootstrap.module_maps(xcframework)
            self.assertTrue((framework / "Modules").is_symlink())

    def test_slice_selection_uses_metadata_platform_and_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            framework = Path(temporary)
            metadata = {"AvailableLibraries": [
                {"LibraryIdentifier": "a-name-with-no-platform-prefix", "SupportedPlatform": "ios",
                 "SupportedPlatformVariant": "simulator", "SupportedArchitectures": ["arm64", "x86_64"]},
                {"LibraryIdentifier": "physical-device", "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]},
            ]}
            (framework / "Info.plist").write_bytes(plistlib.dumps(metadata))
            self.assertEqual(packaging.select_slice(framework, "iphonesimulator", ["arm64"])["LibraryIdentifier"],
                             "a-name-with-no-platform-prefix")
            self.assertEqual(packaging.select_slice(framework, "iphoneos", ["arm64"])["LibraryIdentifier"], "physical-device")
            with self.assertRaises(ValueError):
                packaging.select_slice(framework, "iphoneos", ["x86_64"])
            with self.assertRaises(ValueError):
                packaging.select_slice(framework, "xrsimulator", ["arm64"])

    def test_framework_and_origin_pointers_resolve_from_extension_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Downloader.app"
            extension = app / "PlugIns/Downloader.appex"
            executable = extension / "Downloader"
            base = extension / "python/lib/python3.13/lib-dynload"
            base.mkdir(parents=True)
            source = base / "_ssl.cpython-313-iphoneos.so"
            source.write_bytes(b"fake Mach-O fixture")
            source.with_name("_ssl.xcprivacy").write_bytes(b"upstream privacy fixture")
            frameworks = app / "Frameworks"
            frameworks.mkdir()
            template = app / "template.plist"
            template.write_bytes(plistlib.dumps({"CFBundlePackageType": "FMWK"}))
            with patch.object(packaging, "run", return_value="arm64"):
                framework = packaging.mobile_module(source, base, executable, frameworks, template,
                                                     "test.downloader", ["arm64"], None)
            marker = source.with_suffix(".fwork")
            binary = framework / "_ssl"
            self.assertEqual((executable.parent / marker.read_text().strip()).resolve(), binary.resolve())
            origin = binary.with_name("_ssl.origin").read_text().strip()
            self.assertEqual((executable.parent / origin).resolve(), marker.resolve())
            self.assertTrue(marker.read_text().startswith("../../Frameworks/"))
            self.assertFalse((extension / "Frameworks").exists())
            self.assertFalse(source.exists())
            self.assertEqual((framework / "PrivacyInfo.xcprivacy").read_bytes(), b"upstream privacy fixture")
            self.assertEqual(plistlib.loads((framework / "Info.plist").read_bytes())["CFBundleExecutable"], "_ssl")

    def test_checksum_mismatch_and_offline_missing_archives_fail_without_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            path = cache / "fixture.whl"
            path.write_bytes(b"tampered wheel")
            with self.assertRaises(ValueError):
                bootstrap.verify(path, "0" * 64)
            with patch.object(bootstrap.urllib.request, "urlopen", side_effect=AssertionError("No network")):
                with self.assertRaises(FileNotFoundError):
                    bootstrap.archive({"filename": "missing.whl"}, cache, True)

    def test_app_and_two_extensions_share_mobile_frameworks_with_correct_loader_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dependencies = root / "Dependencies"
            xcframework = dependencies / "Python/iOS/Python.xcframework"
            slice_path = xcframework / "ios-arm64"
            framework = slice_path / "Python.framework"
            framework.mkdir(parents=True)
            (framework / "Python").write_bytes(b"interpreter fixture")
            (xcframework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
                "LibraryIdentifier": "ios-arm64", "LibraryPath": "Python.framework",
                "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"],
            }]}))
            (xcframework / "build").mkdir()
            (xcframework / "build/iOS-dylib-Info-template.plist").write_bytes(plistlib.dumps({
                "CFBundlePackageType": "FMWK",
            }))
            stdlib = slice_path / "lib-arm64/python3.13/lib-dynload"
            stdlib.mkdir(parents=True)
            (stdlib / "_ssl.cpython-313-iphoneos.so").write_bytes(b"native fixture")
            runtime_inputs(stdlib.parent, dependencies / "PythonPackages")
            license_source = dependencies / "FFmpeg/ios-arm64/COPYING.LGPLv2.1"
            license_source.parent.mkdir(parents=True)
            license_source.write_text("LGPL fixture")
            app = root / "Downloader.app"
            consumers = [app, app / "PlugIns/Safari.appex", app / "PlugIns/Share.appex"]
            for index, consumer in enumerate(consumers):
                consumer.mkdir(parents=True, exist_ok=True)
                (consumer / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "test.downloader" if index == 0 else f"test.downloader.extension{index}",
                    "CFBundleExecutable": "Downloader",
                }))
                (consumer / "Downloader").write_bytes(b"executable fixture")
                # Reproduce Xcode copying the old capitalized bootstrap folder
                # before the build phase runs on a case-insensitive Mac volume.
                (consumer / "Python").mkdir()
                (consumer / "Python/old-bootstrap.py").write_bytes(b"old bootstrap fixture")
            args = argparse.Namespace(platform="iphoneos", dependencies=dependencies, architectures=["arm64"],
                                      inspect=False, bundle=app)
            with patch.dict(packaging.os.environ, {"CODE_SIGNING_ALLOWED": "NO"}, clear=True), \
                    patch.object(packaging, "thin"), patch.object(packaging, "run"):
                packaging.package(args)
            binary = app / "Frameworks/_ssl.framework/_ssl"
            self.assertTrue(binary.is_file())
            metadata = plistlib.loads((binary.parent / "Info.plist").read_bytes())
            self.assertEqual(metadata["CFBundleIdentifier"], "test.downloader.python.-ssl")
            self.assertEqual(len(list((app / "Frameworks").glob("_ssl.framework"))), 1)
            for index, consumer in enumerate(consumers):
                marker = next((consumer / "python").rglob("*.fwork"))
                pointer = marker.read_text().strip()
                self.assertTrue(pointer.startswith("Frameworks/" if index == 0 else "../../Frameworks/"))
                self.assertEqual((consumer / pointer).resolve(), binary.resolve())
                origin = binary.with_name("_ssl.origin").read_text().strip()
                self.assertEqual((consumer / origin).resolve(), marker.resolve())
                self.assertFalse(list((consumer / "python").rglob("*.so")))
                names = {child.name for child in consumer.iterdir()}
                self.assertIn("python", names)
                self.assertIn("python-bootstrap", names)
                self.assertNotIn("Python", names)
                packaging.require_exact_file(consumer, "python-bootstrap/app_resolver.py")
                packaging.require_exact_file(consumer, "python-bootstrap/apple_jsc_provider.py")
                packaging.validate_runtime(consumer, "3.13")
                self.assertEqual((consumer / "Licenses/FFmpeg-LGPL-2.1.txt").read_text(), "LGPL fixture")
                if index:
                    self.assertFalse((consumer / "Frameworks").exists())

    def test_runtime_preflight_checks_real_spelling_at_every_path_level(self):
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary)
            runtime_inputs(resources / "python/lib/python3.13", resources / "python-packages")
            (resources / "python-bootstrap").mkdir()
            for name in packaging.BOOTSTRAP_SCRIPTS:
                (resources / "python-bootstrap" / name).write_bytes(b"script fixture")
            (resources / "python-runtime.json").write_text("{}")
            packaging.validate_runtime(resources, "3.13")
            # These renames remain accessible via the old spelling on normal
            # macOS disks. The explicit directory-entry check must reject them
            # before the bundle can be installed on an iPhone.
            for relative, wrong_name in (
                ("python", "Python"),
                ("python-bootstrap", "Python-Bootstrap"),
                ("python/lib/python3.13/encodings", "Encodings"),
                ("python-packages/yt_dlp/__init__.py", "__Init__.py"),
            ):
                with self.subTest(relative=relative):
                    original = resources / relative
                    renamed = original.with_name(wrong_name)
                    original.rename(renamed)
                    with self.assertRaisesRegex(FileNotFoundError, "different case"):
                        packaging.validate_runtime(resources, "3.13")
                    renamed.rename(original)
            (resources / "python-bootstrap/apple_jsc_provider.py").unlink()
            with self.assertRaisesRegex(FileNotFoundError, "apple_jsc_provider.py"):
                packaging.validate_runtime(resources, "3.13")

    def test_wheel_extraction_cannot_escape_staging_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wheel = root / "fixture.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr("../outside.py", "bad")
            with self.assertRaises(ValueError):
                bootstrap.extract_wheel(wheel, root / "packages")
            self.assertFalse((root / "outside.py").exists())


if __name__ == "__main__":
    unittest.main()
