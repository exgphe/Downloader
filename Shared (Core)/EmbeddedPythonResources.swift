import Foundation

/// Resource names must match on iOS's case-sensitive filesystem, even when the
/// app was assembled on a case-insensitive macOS build volume.
struct EmbeddedPythonResources {
    let home: URL
    let packages: URL
    let script: URL
    let executable: URL

    static func locate(resources: URL?, executable: URL?) throws -> Self {
        guard let resources else {
            throw missing("mediaResourcesMissing", "its resource folder")
        }
        guard let executable, FileManager.default.isReadableFile(atPath: executable.path) else {
            throw missing("mediaExecutableMissing", "its app or extension executable")
        }
        let required = [
            ("python/lib/python3.13/encodings/__init__.py", "pythonStdlibMissing", "the Python standard library"),
            ("python-packages/yt_dlp/__init__.py", "pythonPackagesMissing", "the yt-dlp package"),
            ("python-packages/gallery_dl/__init__.py", "pythonPackagesMissing", "the gallery-dl package"),
            ("python-bootstrap/downloader_resolver.py", "pythonBootstrapMissing", "the media scripts (python-bootstrap)"),
            ("python-bootstrap/app_resolver.py", "pythonBootstrapMissing", "the media scripts (python-bootstrap)"),
            ("python-bootstrap/apple_jsc_provider.py", "pythonBootstrapMissing", "the media scripts (python-bootstrap)"),
        ]
        for (path, code, component) in required where !containsExactFile(path, in: resources) {
            throw missing(code, component)
        }
        return Self(home: resources.appendingPathComponent("python", isDirectory: true),
                    packages: resources.appendingPathComponent("python-packages", isDirectory: true),
                    script: resources.appendingPathComponent("python-bootstrap", isDirectory: true),
                    executable: executable)
    }

    private static func containsExactFile(_ relativePath: String, in directory: URL) -> Bool {
        var current = directory
        for name in relativePath.split(separator: "/").map(String.init) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  entries.contains(name) else { return false }
            current.appendPathComponent(name)
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isReadableFile(atPath: current.path)
    }

    private static func missing(_ code: String, _ component: String) -> MediaSaveError {
        MediaSaveError(code: code, message: "The built-in media engine is missing \(component). Build and reinstall the Downloader app, then try again.")
    }
}
