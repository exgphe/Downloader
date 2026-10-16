import Foundation

/// Exercises CPython → Swift → JavaScriptCore with the signed runtime layout,
/// then decodes the real app manifests without making network requests.
@main
enum EmbeddedMediaSmoke {
    struct Failure: Error { let message: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func main() async throws {
        if let flag = CommandLine.arguments.firstIndex(of: "--live-url"), CommandLine.arguments.indices.contains(flag + 1),
           let source = URL(string: CommandLine.arguments[flag + 1]) {
            for destination in DownloadDestination.allCases {
                let manifest = try await EmbeddedMediaResolver.resolve(sourceURL: source, destination: destination)
                guard let item = manifest.media.first else { throw Failure(message: "No media returned") }
                print("Live \(destination.rawValue) metadata: \(item.height ?? 0)p, \(item.container), " +
                      item.streams.map { ($0.videoCodec ?? $0.audioCodec ?? $0.role.rawValue) }.joined(separator: " + "))
            }
            return
        }
        let source = URL(string: "https://youtu.be/abcdefghijk")!
        let photos = try await EmbeddedMediaResolver.resolve(sourceURL: source, destination: .photos)
        try expect(photos.media.first?.height == 2160, "Photos chooses the highest compatible HEVC video")
        try expect(photos.media.first?.container == "mp4", "Photos adaptive streams remux to MP4")
        try expect(photos.media.first?.streams.last?.audioCodec == "mp4a.40.2", "Photos chooses AAC")
        let files = try await EmbeddedMediaResolver.resolve(sourceURL: source, destination: .files)
        try expect(files.media.first?.height == 4320, "Files keeps the highest AV1 video")
        try expect(files.media.first?.streams.last?.audioCodec == "opus", "Files preserves the best Opus audio")
        let carousel = try await EmbeddedMediaResolver.resolve(sourceURL: URL(string: "https://instagram.com/p/ABC/")!, destination: .photos)
        try expect(carousel.media.count == 2, "The real gallery-dl parser returns the whole mixed carousel")
        try expect(carousel.media[0].kind == .image && carousel.media[1].kind == .video, "Images and videos are classified")
        try expect(carousel.title == "Cookie bridge fixture verified", "Swift passes the Instagram-only third session argument into the real gallery-dl jar")
        async let first = EmbeddedMediaResolver.resolve(sourceURL: source, destination: .photos)
        async let second = EmbeddedMediaResolver.resolve(sourceURL: source, destination: .files)
        let concurrent = try await (first, second)
        try expect(concurrent.0.media.first?.height == 2160 && concurrent.1.media.first?.height == 4320, "Concurrent callers preserve destination policy")
        do {
            _ = try await EmbeddedMediaResolver.resolve(sourceURL: URL(string: "https://youtube.com/watch?v=private0000")!, destination: .photos)
            throw Failure(message: "A private video unexpectedly succeeded")
        } catch let error as MediaSaveError {
            try expect(error.code == "loginRequired", "Sign-in failures have an actionable code")
            try expect(!error.message.contains("smoke-secret"), "Errors hide authenticated URLs")
        }
        try expect(EmbeddedMediaResolver.status["available"] as? Bool == true, "A site error does not disable the engine")
        print("Embedded app runtime passed: CPython, JavaScriptCore EJS challenges, gallery-dl Safari cookie bridge, codec policy and concurrent manifests.")
    }
}
