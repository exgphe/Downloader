import Foundation

@main
enum NativeMediaPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        let policy = MediaURLPolicy()
        for address in ["https://scontent.cdninstagram.com/image.jpg?stp=123", "https://scontent.xx.fbcdn.net/movie.mp4",
                        "https://video.twimg.com/movie.mp4", "https://pbs.twimg.com/media/photo.jpg"] {
            expect(policy.allows(URL(string: address)!), "Allowed CDN: \(address)")
        }
        for address in ["http://video.twimg.com/movie.mp4", "https://video.twimg.com:8443/movie.mp4",
                        "https://evilcdninstagram.com/image.jpg", "https://cdninstagram.com.attacker.example/image.jpg",
                        "https://attacker.example/movie.mp4", "https://user:secret@video.twimg.com/movie.mp4",
                        "file:///tmp/movie.mp4", "https://video.twimg.com/movie.mp4#secret", "https://other.twimg.com/movie.mp4",
                        "http://127.0.0.1:8787/video.mp4", "https://resolver.example/v1/jobs/test/media/movie.mp4"] {
            expect(!policy.allows(URL(string: address)!), "Rejected media location: \(address)")
        }
        let cdn = URL(string: "https://video.twimg.com/movie.mp4")!
        expect(policy.allowsRedirect(from: cdn, to: URL(string: "https://scontent.xx.fbcdn.net/movie.mp4")!), "Supported CDN redirect")
        expect(!policy.allowsRedirect(from: cdn, to: URL(string: "https://attacker.example/movie.mp4")!), "External redirect rejected")
        expect(!policy.allowsRedirect(from: URL(string: "https://attacker.example/a")!, to: cdn), "External source rejected")
        let request = try NativeMediaRequest(["item": ["url": cdn.absoluteString, "kind": "video", "filename": "../../clip.mp4"],
                                             "referrer": "https://x.com/example/status/123456"])
        expect(request.filename == "clip.mp4", "Original filename cannot be a local path")
        expect(request.downloadRequest().value(forHTTPHeaderField: "Authorization") == nil, "CDN request has no bearer credentials")
        expect(request.downloadRequest().value(forHTTPHeaderField: "Referer") == "https://x.com/example/status/123456", "Post referrer attached")
        expect(NativeMediaRequest.postURL("https://www.instagram.com/p/AbC_123/?igsh=123")?.query == nil, "Instagram post canonicalization")
        expect(NativeMediaRequest.postURL("https://x.com/i/web/status/123456") != nil, "X canonical web post")
        for address in ["https://attacker.example/example/status/123456", "http://x.com/example/status/1",
                        "https://user:password@x.com/example/status/1", "https://www.instagram.com/stories/example/1",
                        "https://x.com/example/status/not-a-number", "https://x.com:8080/example/status/1"] {
            expect(NativeMediaRequest.postURL(address) == nil, "Unsupported post rejected")
        }
        for message: [String: Any] in [
            ["item": ["url": "https://attacker.example/movie.mp4", "kind": "video"], "referrer": "https://x.com/example/status/1"],
            ["item": ["url": cdn.absoluteString, "kind": "document"], "referrer": "https://x.com/example/status/1"],
            ["item": ["url": cdn.absoluteString, "kind": "video"], "referrer": "https://attacker.example/post/1"],
            ["referrer": "https://x.com/example/status/1"],
        ] {
            do { _ = try NativeMediaRequest(message); preconditionFailure("Invalid native request accepted") }
            catch { checks += 1 }
        }
        print("Native media policy: \(checks) checks passed.")
    }
}
