import Foundation

@main
enum DownloadSourcePolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }

        // Real share-sheet forms must select one video and remove tracking or playlist context.
        let video = "BaW_jenozKc"
        let canonical = "https://www.youtube.com/watch?v=" + video
        let shares: [(String, String)] = [
            ("  https://youtu.be/\(video)?si=sharing&t=4  ", canonical),
            ("Watch this video: https://m.youtube.com/watch?v=\(video)&list=PLcontext", canonical),
            ("https://www.youtube.com/shorts/\(video)", canonical),
            ("https://youtube.com/live/\(video)?feature=share", canonical),
            ("https://www.youtube.com/embed/\(video)", canonical),
            ("看看这个帖子 💾\nhttps://www.instagram.com/p/AbC_123/?igsh=tracking", "https://www.instagram.com/p/AbC_123/"),
            ("https://instagram.com/reels/AbC_123/?igsh=tracking", "https://www.instagram.com/reel/AbC_123/"),
            ("https://www.instagram.com/share/p/SharedToken/?igsh=tracking", "https://www.instagram.com/share/p/SharedToken/"),
            ("https://www.instagram.com/share/reel/SharedToken/?igsh=tracking", "https://www.instagram.com/share/reel/SharedToken/"),
            ("https://www.instagram.com/stories/imwinter/4013638722465314116/?utm_source=ig_story_item_share&rpxt=MXZhMmc5bWZibmoweA%3D%3D", "https://www.instagram.com/stories/imwinter/4013638722465314116/"),
            ("看看这个 Story https://instagram.com/stories/some.user/4013638722465314116?igsh=tracking", "https://www.instagram.com/stories/some.user/4013638722465314116/"),
            ("https://x.com/example/status/123456?s=20", "https://x.com/example/status/123456")
        ]
        for (input, expected) in shares {
            expect(try DownloadSource.url(from: input).absoluteString == expected, "Share input did not select the expected post: \(input)")
        }
        for input in [
            "https://www.youtube.com/playlist?list=PLcontext", "https://youtu.be/not-an-id",
            "https://youtube.com.attacker.example/watch?v=\(video)",
            "https://user:secret@youtube.com/watch?v=\(video)",
            "http://youtu.be/\(video)", "https://www.instagram.com/accounts/login/",
            "https://www.instagram.com/stories/imwinter/", "https://www.instagram.com/stories/imwinter/not-an-id/",
            "https://www.instagram.com/stories/highlights/123/", "https://www.instagram.com/stories/imwinter/123/extra",
            "file:///tmp/video.mp4", "https://localhost/watch?v=\(video)", "Ordinary shared text"
        ] {
            do { _ = try DownloadSource.url(from: input); preconditionFailure("Unsupported share accepted: \(input)") }
            catch { checks += 1 }
        }

        // Native adaptive-video URLs need the same credential-free HTTPS boundary as photos.
        for location in ["https://rr1---sn-example.googlevideo.com/videoplayback?sig=123",
                         "https://scontent.cdninstagram.com/image.jpg", "https://video.twimg.com/video.mp4"] {
            expect(DownloadURLPolicy.allows(URL(string: location)!), "Supported media CDN rejected")
        }
        for location in ["https://googlevideo.com.attacker.example/videoplayback",
                         "https://evilgooglevideo.com/videoplayback", "https://127.0.0.1/video.mp4",
                         "https://user:secret@rr1.googlevideo.com/videoplayback",
                         "https://rr1.googlevideo.com:8443/videoplayback", "http://rr1.googlevideo.com/videoplayback"] {
            expect(!DownloadURLPolicy.allows(URL(string: location)!), "Untrusted native media URL accepted")
        }
        let stream = ResolvedStream(url: URL(string: "https://rr1.googlevideo.com/videoplayback")!,
                                    headers: ["User-Agent": "Downloader test", "Referer": "https://www.youtube.com/",
                                              "Authorization": "Bearer secret", "Cookie": "session=secret",
                                              "Origin": "https://www.youtube.com\r\nInjected: value", "X-Unrelated": "no"],
                                    role: .combined, container: "mp4")
        let request = try DownloadURLPolicy.request(for: stream)
        expect(request.value(forHTTPHeaderField: "User-Agent") == "Downloader test", "Required extractor user agent lost")
        expect(request.value(forHTTPHeaderField: "Referer") == "https://www.youtube.com/", "Required media referrer lost")
        expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil,
               "Extractor credentials must not enter background CDN requests")
        expect(request.value(forHTTPHeaderField: "Origin") == nil && request.value(forHTTPHeaderField: "X-Unrelated") == nil,
               "Injected or unrelated headers must be removed")
        print("Download source and adaptive-media policy: \(checks) checks passed.")
    }
}
