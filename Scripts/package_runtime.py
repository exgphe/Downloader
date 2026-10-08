# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Package already bootstrapped Python into a containing app and its Safari extension.

Called after Embed PlugIns by the app target. This script never accesses the network.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {
    "macosx": ("macOS", "macos", None),
    "iphoneos": ("iOS", "ios", None),
    "iphonesimulator": ("iOS", "ios", "simulator"),
    "xros": ("visionOS", "xros", None),
    "xrsimulator": ("visionOS", "xros", "simulator"),
}
EXCLUDED = {"__pycache__", "test", "tests", "idlelib", "turtledemo", "ensurepip", "site-packages"}


def run(*command: str) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()


def select_slice(xcframework: Path, platform_name: str, architectures: list[str]) -> dict:
    _, supported_platform, variant = PLATFORMS[platform_name]
    metadata = plistlib.loads((xcframework / "Info.plist").read_bytes())
    matches = [
        item for item in metadata["AvailableLibraries"]
        if item["SupportedPlatform"] == supported_platform
        and item.get("SupportedPlatformVariant") == variant
        and set(architectures).issubset(item["SupportedArchitectures"])
    ]
    if len(matches) != 1:
        raise ValueError(f"No unambiguous Python slice for {platform_name} / {' '.join(architectures)}. "
                         "Check the pinned xcframework's supported architectures.")
    return matches[0]


def ignored(directory: str, names: list[str]) -> set[str]:
    result = {
        name for name in names
        if name in EXCLUDED or name.startswith("config-")
        or name.endswith((".pyc", ".pyo", ".a"))
        or (name.startswith(("_test", "xx")) and name.endswith((".so", ".py")))
    }
    if Path(directory).name == "PythonPackages":
        result.update(name for name in names if name.endswith(".data"))
    return result


def copy_tree(source: Path, destination: Path, *, fresh: bool = False, framework: bool = False) -> None:
    if fresh and destination.exists():
        shutil.rmtree(destination)
    def exclusions(directory: str, names: list[str]) -> set[str]:
        excluded = ignored(directory, names)
        if framework:
            excluded.update(name for name in names if name in {
                "Headers", "include", "bin", "_CodeSignature", "Python.app", "pkgconfig",
            })
            if Path(directory).name == "lib":
                excluded.update(name for name in names if name.startswith("python") or name.startswith("libpython"))
        else:
            excluded.update(name for name in names if name.startswith("libpython") and name.endswith(".dylib"))
        return excluded
    shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=True, ignore=exclusions)


def thin(binary: Path, architectures: list[str]) -> None:
    current = run("xcrun", "lipo", "-archs", str(binary)).split()
    if not set(architectures).issubset(current):
        raise ValueError(f"{binary.name} has {current}, but Xcode requested {architectures}")
    if set(current) == set(architectures):
        return
    temporary = binary.with_name(binary.name + ".downloader-thin")
    try:
        if len(architectures) == 1:
            run("xcrun", "lipo", str(binary), "-thin", architectures[0], "-output", str(temporary))
        else:
            command = ["xcrun", "lipo", str(binary)]
            for arch in architectures:
                command.extend(["-extract", arch])
            run(*command, "-output", str(temporary))
        temporary.replace(binary)
    finally:
        temporary.unlink(missing_ok=True)


def sign(path: Path, identity: str | None, *, preserve: bool = False) -> None:
    if not identity:
        return
    command = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none"]
    if preserve:
        command.append("--preserve-metadata=identifier,entitlements,flags")
    run(*command, str(path))


def mobile_module(module: Path, base: Path, extension_executable: Path, frameworks: Path,
                  template: Path, bundle_id: str, architectures: list[str], identity: str | None) -> Path:
    relative = module.relative_to(base)
    module_name = ".".join((*relative.parts[:-1], relative.name.split(".")[0]))
    if not re.fullmatch(r"[A-Za-z0-9_.]+", module_name):
        raise ValueError(f"Unsupported Python extension module name: {module_name}")
    framework = frameworks / f"{module_name}.framework"
    if framework.exists():
        shutil.rmtree(framework)
    framework.mkdir()
    binary = framework / module_name
    shutil.move(str(module), str(binary))
    metadata = plistlib.loads(template.read_bytes())
    metadata["CFBundleExecutable"] = module_name
    metadata["CFBundleIdentifier"] = f"{bundle_id}.python.{module_name}".replace("_", "-")
    (framework / "Info.plist").write_bytes(plistlib.dumps(metadata))
    privacy = module.with_name(relative.name.split(".")[0] + ".xcprivacy")
    if privacy.exists():
        shutil.move(str(privacy), str(framework / "PrivacyInfo.xcprivacy"))
    marker = module.with_suffix(".fwork")
    # AppleFrameworkLoader joins BOTH pointers against dirname(sys.executable).
    marker.write_text(os.path.relpath(binary, extension_executable.parent) + "\n")
    binary.with_name(module_name + ".origin").write_text(os.path.relpath(marker, extension_executable.parent) + "\n")
    thin(binary, architectures)
    sign(framework, identity)
    return framework


def package(args: argparse.Namespace) -> None:
    if args.platform not in PLATFORMS:
        raise ValueError(f"Unsupported PLATFORM_NAME: {args.platform}")
    family, _, _ = PLATFORMS[args.platform]
    lock = json.loads((ROOT / "Dependencies/runtime-lock.json").read_text())
    abi = lock["python"]["abiVersion"]
    xcframework = args.dependencies / "Python" / family / "Python.xcframework"
    if not (xcframework / "Info.plist").is_file():
        raise FileNotFoundError(f"Missing {xcframework}. Run uv run --no-project --script Scripts/bootstrap_runtime.py first.")
    slice_info = select_slice(xcframework, args.platform, args.architectures)
    slice_path = xcframework / slice_info["LibraryIdentifier"]
    if args.inspect:
        print(json.dumps({"platform": args.platform, "slice": slice_info["LibraryIdentifier"],
                          "architectures": args.architectures}))
        return
    app = args.bundle.resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError(f"Containing app must already exist after Embed PlugIns: {app}")
    contents = app / "Contents" if family == "macOS" else app
    extensions = sorted((contents / "PlugIns").glob("*.appex"))
    if len(extensions) != 1:
        raise ValueError(f"Expected one Safari extension in {contents / 'PlugIns'}, found {len(extensions)}")
    extension = extensions[0]
    resources = extension / "Contents/Resources" if family == "macOS" else extension
    info_path = extension / "Contents/Info.plist" if family == "macOS" else extension / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    executable = extension / "Contents/MacOS" / info["CFBundleExecutable"] if family == "macOS" else extension / info["CFBundleExecutable"]
    if os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY")
        if not identity:
            raise ValueError("CODE_SIGNING_ALLOWED=YES but EXPANDED_CODE_SIGN_IDENTITY is empty")
    else:
        identity = "-" if family == "macOS" else None
    frameworks = contents / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    source_framework = slice_path / slice_info["LibraryPath"]
    embedded_framework = frameworks / "Python.framework"
    copy_tree(source_framework, embedded_framework, fresh=True, framework=True)
    # Versioned macOS frameworks allow symlinks at the root for Modules.
    # Normalize older locally bootstrapped assets before codesign sealing.
    if (embedded_framework / "Versions/Current").is_dir():
        root_modules = embedded_framework / "Modules"
        version_modules = embedded_framework / "Versions/Current/Modules"
        if root_modules.is_dir() and not root_modules.is_symlink():
            if version_modules.exists():
                copy_tree(root_modules, version_modules)
                shutil.rmtree(root_modules)
            else:
                shutil.move(str(root_modules), str(version_modules))
        if not root_modules.exists():
            root_modules.symlink_to("Versions/Current/Modules", target_is_directory=True)
    python_home = resources / "python"
    if python_home.exists():
        shutil.rmtree(python_home)
    stdlib = python_home / "lib" / f"python{abi}"
    if family == "macOS":
        copy_tree(source_framework / "Versions" / abi / "lib" / f"python{abi}", stdlib)
    else:
        shared = xcframework / "lib" / f"python{abi}"
        if shared.exists():
            copy_tree(shared, stdlib)
        specific_libraries = []
        for arch in args.architectures:
            specific = slice_path / f"lib-{arch}" / f"python{abi}"
            if not specific.exists():
                specific = slice_path / "lib" / f"python{abi}"
            if not specific.exists():
                raise FileNotFoundError(f"No standard library for {slice_info['LibraryIdentifier']} / {arch}")
            copy_tree(specific, stdlib)
            specific_libraries.append(specific)
        # Some simulator xcframeworks have one .so per architecture, unlike their
        # universal Python.framework binary. Merge those when Xcode builds both.
        if len(args.architectures) > 1:
            for module in stdlib.glob("lib-dynload/*.so"):
                relative = module.relative_to(stdlib)
                sources = list(dict.fromkeys(source / relative for source in specific_libraries if (source / relative).is_file()))
                if len(sources) > 1:
                    temporary = module.with_name(module.name + ".downloader-universal")
                    try:
                        run("xcrun", "lipo", "-create", *(str(source) for source in sources), "-output", str(temporary))
                        temporary.replace(module)
                    finally:
                        temporary.unlink(missing_ok=True)
    packages = resources / "python-packages"
    copy_tree(args.dependencies / "PythonPackages", packages, fresh=True)
    bootstrap_source = ROOT / "Shared (Extension)/Resources/Python/downloader_resolver.py"
    if not bootstrap_source.is_file():
        raise FileNotFoundError(f"Missing Python resolver source: {bootstrap_source}")
    (resources / "Python").mkdir(exist_ok=True)
    shutil.copy2(bootstrap_source, resources / "Python/downloader_resolver.py")
    generated = [embedded_framework]
    dynamic_modules = list(stdlib.glob("lib-dynload/*.so")) + list(packages.rglob("*.so"))
    if family == "macOS":
        for module in dynamic_modules:
            thin(module, args.architectures)
            sign(module, identity)
        for library in embedded_framework.rglob("*.dylib"):
            if not library.is_symlink():
                thin(library, args.architectures)
                sign(library, identity)
    else:
        template_name = "iOS" if family == "iOS" else "xrOS"
        template = xcframework / "build" / f"{template_name}-dylib-Info-template.plist"
        for module in dynamic_modules:
            base = stdlib / "lib-dynload" if module.is_relative_to(stdlib) else packages
            generated.append(mobile_module(module, base, executable, frameworks, template,
                                          info["CFBundleIdentifier"], args.architectures, identity))
    framework_binary = embedded_framework / ("Versions/" + abi + "/Python" if family == "macOS" else "Python")
    thin(framework_binary, args.architectures)
    sign(embedded_framework, identity)
    versions = {"pythonVersion": lock["python"]["version"],
                "ytDlpVersion": next(entry["version"] for entry in lock["packages"] if entry["name"] == "yt-dlp"),
                "slice": slice_info["LibraryIdentifier"],
                "frameworks": [str(path.relative_to(app)) for path in generated]}
    (resources / "python-runtime.json").write_text(json.dumps(versions, indent=2) + "\n")
    if executable.is_file():
        # ENABLE_DEBUG_DYLIB produces native sibling libraries even when the
        # outer extension target was built with CODE_SIGNING_ALLOWED=NO.
        for native_library in executable.parent.glob("*.dylib"):
            if not native_library.is_symlink():
                sign(native_library, identity, preserve=True)
        sign(extension, identity, preserve=True)
    elif identity and os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
        raise FileNotFoundError(f"Extension executable is missing: {executable}")
    print(f"Packaged Python {versions['pythonVersion']} + yt-dlp {versions['ytDlpVersion']} "
          f"for {args.platform} ({slice_info['LibraryIdentifier']}); {len(dynamic_modules)} native modules.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", default=os.environ.get("PLATFORM_NAME", "macosx"), choices=PLATFORMS)
    default_bundle = Path(os.environ.get("TARGET_BUILD_DIR", ".")) / os.environ.get("FULL_PRODUCT_NAME", "")
    parser.add_argument("--bundle", type=Path, default=default_bundle)
    parser.add_argument("--dependencies", type=Path, default=ROOT / "Dependencies")
    parser.add_argument("--arch", action="append", dest="architectures")
    parser.add_argument("--inspect", action="store_true", help="Validate and print the selected slice without packaging")
    args = parser.parse_args()
    args.architectures = args.architectures or os.environ.get("ARCHS", platform.machine()).split()
    args.dependencies = args.dependencies.resolve()
    try:
        package(args)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        details = error.output if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"error: Embedded Python packaging failed: {details}\n")


if __name__ == "__main__":
    main()
