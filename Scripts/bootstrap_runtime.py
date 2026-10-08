# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Download and verify the pinned Apple Python runtimes before opening Xcode.

This is an explicit setup command. Xcode packaging never downloads dependencies.
Run with: uv run --no-project --script Scripts/bootstrap_runtime.py
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def verify(path: Path, digest: str) -> None:
    with path.open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    if actual != digest:
        raise ValueError(f"Checksum mismatch for {path.name}: expected {digest}, got {actual}")


def archive(entry: dict, cache: Path, offline: bool) -> Path:
    path = cache / entry["filename"]
    if not path.exists():
        if offline:
            raise FileNotFoundError(f"Missing {path}. Run bootstrap again without --offline.")
        print(f"Downloading {entry['filename']}", flush=True)
        request = urllib.request.Request(entry["url"], headers={"User-Agent": "Downloader-runtime-bootstrap/1"})
        with urllib.request.urlopen(request, timeout=120) as response, tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            temporary = Path(output.name)
            try:
                shutil.copyfileobj(response, output)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        try:
            verify(temporary, entry["sha256"])
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    verify(path, entry["sha256"])
    return path


def extract_wheel(path: Path, destination: Path) -> None:
    with zipfile.ZipFile(path) as wheel:
        for member in wheel.infolist():
            target = destination / member.filename
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError(f"Unsafe wheel entry: {member.filename}")
        wheel.extractall(destination)


def replace_tree(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.move(str(source), str(destination))


def module_maps(xcframework: Path) -> None:
    metadata = plistlib.loads((xcframework / "Info.plist").read_bytes())
    for entry in metadata["AvailableLibraries"]:
        framework = xcframework / entry["LibraryIdentifier"] / entry["LibraryPath"]
        if (framework / "Versions/Current").is_dir():
            modules = framework / "Versions/Current/Modules"
            modules.mkdir(exist_ok=True)
            root_modules = framework / "Modules"
            if root_modules.is_symlink():
                root_modules.unlink()
            elif root_modules.exists():
                shutil.rmtree(root_modules)
            root_modules.symlink_to("Versions/Current/Modules", target_is_directory=True)
        else:
            modules = framework / "Modules"
        modules.mkdir(exist_ok=True)
        (modules / "module.modulemap").write_text(
            'framework module Python [system] {\n'
            '    umbrella header "Python.h"\n'
            '    export *\n'
            '    module * { export * }\n'
            '}\n'
        )


def bootstrap(args: argparse.Namespace) -> None:
    lock = json.loads((ROOT / "Dependencies/runtime-lock.json").read_text())
    destination = args.destination.resolve()
    cache = (args.archive_dir or destination / ".downloads").resolve()
    cache.mkdir(parents=True, exist_ok=True)
    selected = list(dict.fromkeys(args.platform or lock["python"]["frameworks"]))
    # Validate every selected archive before replacing any existing dependency tree.
    frameworks = [(platform, archive(lock["python"]["frameworks"][platform], cache, args.offline)) for platform in selected]
    wheels = [(entry, archive(entry, cache, args.offline)) for entry in lock["packages"]]
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="runtime-bootstrap-", dir=destination) as scratch:
        staging = Path(scratch)
        for platform, path in frameworks:
            output = staging / platform
            output.mkdir()
            with tarfile.open(path, "r:gz") as bundle:
                bundle.extractall(output, filter="data")
            if not (output / "Python.xcframework/Info.plist").is_file():
                raise ValueError(f"{path.name} does not contain the expected Python.xcframework")
            module_maps(output / "Python.xcframework")
        packages = staging / "PythonPackages"
        packages.mkdir()
        for _, path in wheels:
            extract_wheel(path, packages)
        for platform, _ in frameworks:
            replace_tree(staging / platform, destination / "Python" / platform)
        replace_tree(packages, destination / "PythonPackages")
    (destination / ".runtime-lock-installed.json").write_text(json.dumps(lock, indent=2) + "\n")
    print(f"Verified runtime dependencies installed in {destination}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["macOS", "iOS", "visionOS"], action="append")
    parser.add_argument("--destination", type=Path, default=ROOT / "Dependencies")
    parser.add_argument("--archive-dir", type=Path, help="Use archives cached in this directory")
    parser.add_argument("--offline", action="store_true", help="Require existing archives; never access the network")
    args = parser.parse_args()
    try:
        bootstrap(args)
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Runtime bootstrap failed: {error}\n")


if __name__ == "__main__":
    main()
