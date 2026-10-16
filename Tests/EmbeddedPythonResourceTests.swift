import Foundation

@main
enum EmbeddedPythonResourceTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloaderResources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Downloader Share.appex")
        let executable = resources.appendingPathComponent("Downloader Share")
        let paths = ["python/lib/python3.13/encodings/__init__.py",
                     "python-packages/yt_dlp/__init__.py", "python-packages/gallery_dl/__init__.py",
                     "python-bootstrap/downloader_resolver.py", "python-bootstrap/app_resolver.py",
                     "python-bootstrap/apple_jsc_provider.py", "Downloader Share"]
        for path in paths {
            let file = resources.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let valid = try EmbeddedPythonResources.locate(resources: resources, executable: executable)
        expect(valid.script.lastPathComponent == "python-bootstrap", "Bootstrap must be separate from Python home")
        expect(valid.home.lastPathComponent == "python", "Python home uses exact lowercase spelling")

        func rejects(_ code: String) throws {
            do {
                _ = try EmbeddedPythonResources.locate(resources: resources, executable: executable)
                preconditionFailure("Invalid runtime layout was accepted")
            } catch let failure as MediaSaveError {
                expect(failure.code == code, "Missing components have a useful diagnostic")
                expect(!failure.message.contains(resources.path), "Diagnostics do not expose full device paths")
            }
        }
        let bootstrap = valid.script
        let renamed = resources.appendingPathComponent("Python-Bootstrap")
        let staging = resources.appendingPathComponent("bootstrap-staging")
        // A two-step rename changes real directory entries on case-insensitive APFS too.
        try FileManager.default.moveItem(at: bootstrap, to: staging)
        try FileManager.default.moveItem(at: staging, to: renamed)
        try rejects("pythonBootstrapMissing")
        try FileManager.default.moveItem(at: renamed, to: staging)
        try FileManager.default.moveItem(at: staging, to: bootstrap)

        // Reproduce the old iPhone layout: all scripts merged into python/, with
        // no separately named bootstrap directory. macOS existence checks hid this.
        for name in ["downloader_resolver.py", "app_resolver.py", "apple_jsc_provider.py"] {
            try FileManager.default.copyItem(at: bootstrap.appendingPathComponent(name), to: valid.home.appendingPathComponent(name))
        }
        try FileManager.default.moveItem(at: bootstrap, to: staging)
        try rejects("pythonBootstrapMissing")
        try FileManager.default.moveItem(at: staging, to: bootstrap)

        let gallery = valid.packages.appendingPathComponent("gallery_dl/__init__.py")
        try FileManager.default.removeItem(at: gallery)
        try rejects("pythonPackagesMissing")
        try Data("fixture".utf8).write(to: gallery)
        let stdlib = valid.home.appendingPathComponent("lib/python3.13/encodings/__init__.py")
        try FileManager.default.removeItem(at: stdlib)
        try rejects("pythonStdlibMissing")
        try Data("fixture".utf8).write(to: stdlib)
        try FileManager.default.removeItem(at: executable)
        try rejects("mediaExecutableMissing")
        print("Embedded Python resource checks passed: exact case, old iPhone layout and missing-component diagnostics.")
    }
}
