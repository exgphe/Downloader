import Foundation

/// Compiled by Scripts/test_embedded_runtime.py into a temporary macOS .appex.
/// The real packaged CPython/yt-dlp run against offline extraction fixtures.
@main
enum EmbeddedPythonSmoke {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw CheckFailure(description: label) }
    }

    static func main() async throws {
        let status = EmbeddedVideoResolver.status
        try expect(status["available"] as? Bool == true, "Packaged runtime resources are present")
        try expect(!(status["version"] as? String ?? "").isEmpty, "Packaged yt-dlp version is available")
        try expect(!(status["pythonVersion"] as? String ?? "").isEmpty, "Packaged CPython version is available")
        let post = URL(string: "https://x.com/example/status/123")!

        if CommandLine.arguments.contains("--failure") {
            for _ in 0..<2 {
                do {
                    _ = try await EmbeddedVideoResolver.resolve(postURL: post)
                    throw CheckFailure(description: "Broken bootstrap was accepted")
                } catch let error as MediaSaveError {
                    try expect(error.code == "videoEngineUnavailable", "Initialization failure has an actionable code")
                    try expect(!error.message.contains("smoke-secret"), "Initialization error does not expose Python details")
                    let failed = EmbeddedVideoResolver.status
                    try expect(failed["available"] as? Bool == false, "Failed initialization is reflected in status")
                    try expect(failed["code"] as? String == error.code, "Status preserves the cached failure code")
                }
            }
            print("Embedded runtime failure smoke passed: initialization cleanup, cached retry, status and error privacy.")
            return
        }

        do {
            _ = try await EmbeddedVideoResolver.resolve(postURL: URL(string: "https://attacker.example/post/123")!)
            throw CheckFailure(description: "Unsupported post was accepted")
        } catch let error as MediaSaveError {
            try expect(error.code == "invalidPost", "Swift validates the post before extraction")
        }

        let first = try await EmbeddedVideoResolver.resolve(postURL: post)
        try expect(first.count == 2, "Every X video is returned")
        try expect(first.first?["url"] as? String == "https://video.twimg.com/first-high.mp4", "Highest-quality progressive MP4 is selected")
        let instagram = try await EmbeddedVideoResolver.resolve(postURL: URL(string: "https://instagram.com/p/Test/")!)
        try expect(instagram.count == 2, "Instagram mixed carousel stills do not hide its videos")

        async let left = EmbeddedVideoResolver.resolve(postURL: URL(string: "https://x.com/example/status/456")!)
        async let right = EmbeddedVideoResolver.resolve(postURL: URL(string: "https://x.com/example/status/789")!)
        let pair = try await (left, right)
        try expect(pair.0.count == 2 && pair.1.count == 2, "Concurrent requests are serialized with correct GIL ownership")

        do {
            _ = try await EmbeddedVideoResolver.resolve(postURL: URL(string: "https://x.com/example/status/999")!)
            throw CheckFailure(description: "Authenticated fixture unexpectedly succeeded")
        } catch let error as MediaSaveError {
            try expect(error.code == "loginRequired", "Authorization failures retain an actionable code")
            try expect(!error.message.contains("smoke-secret"), "Extractor errors do not expose authenticated details")
        }
        try expect(EmbeddedVideoResolver.status["available"] as? Bool == true, "A site error does not mark the runtime unavailable")
        let repeated = try await EmbeddedVideoResolver.resolve(postURL: post)
        try expect(repeated.count == 2, "Interpreter remains usable after a site error")
        print("Embedded runtime success smoke passed: CPython, _ssl/certifi, real yt-dlp, X/Instagram carousels, repeated and concurrent GIL access.")
    }
}
