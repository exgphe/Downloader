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
        let converted = try await EmbeddedMediaResolver.resolve(sourceURL: source, destination: .photos, allowAV1: true)
        try expect(converted.media.first?.height == 4320 && converted.media.first?.streams.last?.audioCodec?.hasPrefix("mp4a") == true,
                   "The native conversion option selects high-resolution AV1 with AAC for Photos")
        try expect(files.media.first?.height == 4320, "Files keeps the highest AV1 video")
        try expect(files.media.first?.streams.last?.audioCodec == "opus", "Files preserves the best Opus audio")
        let carousel = try await EmbeddedMediaResolver.resolve(sourceURL: URL(string: "https://instagram.com/p/ABC/")!, destination: .photos)
        try expect(carousel.media.count == 2, "The real gallery-dl parser returns the whole mixed carousel")
        try expect(carousel.media[0].kind == .image && carousel.media[1].kind == .video, "Images and videos are classified")
        try expect(carousel.title == "Cookie bridge fixture verified", "Swift passes the Instagram-only third session argument into the real gallery-dl jar")
        let storyURL = URL(string: "https://www.instagram.com/stories/imwinter/4013638722465314116/?utm_source=ig_story_item_share&rpxt=tracking")!
        let story = try await EmbeddedMediaResolver.resolve(sourceURL: storyURL, destination: .photos)
        try expect(story.media.count == 1 && story.media[0].kind == .image && story.media[0].id == "4013638722465314116",
                   "The bundled gallery-dl Story path selects exactly the shared image and preserves its large ID")
        try expect(story.sourceURL.query == nil && story.title == "Instagram Story · imwinter", "Story tracking is stripped and the owner is displayed")
        let videoStory = try await EmbeddedMediaResolver.resolve(sourceURL: URL(string: "https://instagram.com/stories/imwinter/4013638722465314117/")!, destination: .files)
        try expect(videoStory.media.count == 1 && videoStory.media[0].kind == .video && videoStory.media[0].container == "mp4",
                   "A video Story uses the real gallery parser rather than its poster image")
        do {
            _ = try await EmbeddedMediaResolver.resolve(sourceURL: URL(string: "https://instagram.com/stories/imwinter/111/")!, destination: .photos)
            throw Failure(message: "A missing Story unexpectedly selected other media")
        } catch let error as MediaSaveError {
            try expect(error.code == "storyUnavailable", "Deleted or expired Stories have an actionable error")
        }
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
        print("Embedded app runtime passed: CPython, JavaScriptCore EJS challenges, gallery-dl posts and Stories, Safari cookie bridge, codec policy and concurrent manifests.")
    }
}
