import Foundation

// Compile with NativeMediaRequest.swift; this checks the native boundary without Photos permission.
@main
enum NativeMediaPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            precondition(value, label)
        }
        let direct = MediaURLPolicy(service: nil)
        for address in ["https://scontent.cdninstagram.com/image.jpg?stp=123", "https://scontent.xx.fbcdn.net/movie.mp4",
                        "https://video.twimg.com/movie.mp4", "https://pbs.twimg.com/media/photo.jpg"] {
            expect(direct.allows(URL(string: address)!), "Allowed CDN: \(address)")
        }
        for address in ["http://video.twimg.com/movie.mp4", "https://video.twimg.com:8443/movie.mp4",
                        "https://evilcdninstagram.com/image.jpg", "https://cdninstagram.com.attacker.example/image.jpg",
                        "https://attacker.example/movie.mp4", "https://user:secret@video.twimg.com/movie.mp4",
                        "file:///tmp/movie.mp4", "https://video.twimg.com/movie.mp4#secret", "https://other.twimg.com/movie.mp4"] {
            expect(!direct.allows(URL(string: address)!), "Rejected CDN: \(address)")
        }
        let uuid = "01234567-89ab-cdef-0123-456789abcdef"
        let service = try ResolverService(["url": "https://resolver.example/downloader/", "token": "secret-token"])
        let policy = MediaURLPolicy(service: service)
        let media = URL(string: "https://resolver.example/downloader/v1/jobs/\(uuid)/media/0.mp4")!
        expect(policy.isResolverURL(media), "Configured resolver media route")
        expect(policy.isResolverURL(URL(string: "https://resolver.example:443/downloader/v1/jobs/\(uuid)/media/0.mp4")!), "Equivalent default port")
        for address in ["https://attacker.example/downloader/v1/jobs/\(uuid)/media/0.mp4",
                        "https://resolver.example:444/downloader/v1/jobs/\(uuid)/media/0.mp4",
                        "http://resolver.example/downloader/v1/jobs/\(uuid)/media/0.mp4",
                        "https://resolver.example/downloader/v1/jobs/not-a-uuid/media/0.mp4",
                        "https://resolver.example/downloader/v1/jobs/\(uuid)/media/../secret",
                        "https://resolver.example/downloader/v1/jobs/\(uuid)/media/%2e%2e",
                        "https://resolver.example/downloader/v1/jobs/\(uuid)/media/x%2fy",
                        "https://resolver.example/downloader/v1/jobs/\(uuid)/media/x%5cy",
                        "https://resolver.example/v1/jobs/\(uuid)/media/0.mp4",
                        "https://resolver.example/downloader/v1/jobs/\(uuid)/media/0.mp4/extra"] {
            expect(!policy.isResolverURL(URL(string: address)!), "Rejected resolver: \(address)")
        }
        let cdn = URL(string: "https://video.twimg.com/movie.mp4")!
        expect(!policy.allowsRedirect(from: media, to: cdn), "Resolver cannot redirect credentials to a CDN")
        expect(!policy.allowsRedirect(from: cdn, to: media), "CDN cannot solicit configured resolver credentials")
        expect(policy.allowsRedirect(from: media, to: media), "Same-origin resolver redirect")
        let request = try NativeMediaRequest(["item": ["url": media.absoluteString, "kind": "video", "filename": "../../clip.mp4"],
                                             "referrer": "https://x.com/example/status/123456", "service": ["url": service.baseURL.absoluteString, "token": "secret-token"]])
        expect(request.downloadRequest().value(forHTTPHeaderField: "Authorization") == "Bearer secret-token", "Resolver token is attached")
        expect(request.filename == "clip.mp4", "Original filename cannot be a local path")
        let directRequest = try NativeMediaRequest(["item": ["url": cdn.absoluteString, "kind": "video"],
                                                   "referrer": "https://x.com/example/status/123456", "service": ["url": service.baseURL.absoluteString, "token": "secret-token"]])
        expect(directRequest.downloadRequest().value(forHTTPHeaderField: "Authorization") == nil, "Resolver token never attached to CDN")
        expect(NativeMediaRequest.postURL("https://www.instagram.com/p/AbC_123/?igsh=123")?.query == nil, "Instagram canonical post URL")
        expect(NativeMediaRequest.postURL("https://x.com/i/web/status/123456") != nil, "X canonical web post URL")
        expect(NativeMediaRequest.postURL("https://attacker.example/example/status/123456") == nil, "Unsupported referrer")
        let loopback = try ResolverService(["url": "http://127.0.0.1:8765"])
        expect(loopback.baseURL.scheme == "http", "HTTP allowed for local development only")
        let invalidConfigurations: [[String: Any]] = [["url": "http://remote.example"], ["url": "https://user:secret@resolver.example"],
                                                       ["url": "https://resolver.example?token=secret"], ["url": "https://resolver.example", "token": "bad\r\nheader"]]
        for configuration in invalidConfigurations {
            do {
                _ = try ResolverService(configuration)
                preconditionFailure("Unsafe resolver configuration accepted")
            } catch {
                checks += 1
            }
        }
        print("Native media policy: \(checks) checks passed.")
    }
}
