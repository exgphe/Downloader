import Foundation

enum DownloadDestination: String, Codable, CaseIterable, Sendable {
    case photos, files
}

enum DownloadPhase: String, Codable, Sendable {
    case queued, resolving, downloading, converting, saving, completed, failed, cancelled
    var isFinished: Bool { [.completed, .failed, .cancelled].contains(self) }
}

struct DownloadJob: Identifiable, Codable, Sendable {
    var id: UUID
    var sourceURL: URL
    var title: String
    var destination: DownloadDestination
    var phase: DownloadPhase
    var progress: Double?
    var error: String?
    var outputFiles: [URL]
    var createdAt: Date
    var savedMediaIDs: Set<String>
    var resolved: ResolvedDownload?
    var attemptID: UUID = UUID()
    var ownerProcessID: Int32? = nil
    var errorCode: String? = nil
    var hevcConversion: HEVCConversionSettings? = nil
}

struct ResolvedDownload: Codable, Sendable {
    var sourceURL: URL
    var title: String
    var media: [ResolvedMedia]
}

struct ResolvedMedia: Codable, Sendable {
    var id: String
    var kind: MediaKind
    var filename: String
    var container: String
    var streams: [ResolvedStream]
    var width: Int?
    var height: Int?
    var expectedBytes: Int64?
}

enum StreamRole: String, Codable, Sendable {
    case image, video, audio, combined
}

struct ResolvedStream: Codable, Sendable {
    var url: URL
    var headers: [String: String]
    var role: StreamRole
    var container: String
    var videoCodec: String?
    var audioCodec: String?
    var expectedBytes: Int64?
}

enum DownloadURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.fragment == nil, components.port == nil || components.port == 443,
              url.absoluteString.count <= 16_384, let host = components.host?.lowercased() else { return false }
        return MediaURLPolicy().allows(url) || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    static func request(for stream: ResolvedStream) throws -> URLRequest {
        guard allows(stream.url) else {
            throw MediaSaveError(code: "unsafeMedia", message: "The download points to an unsupported media location.")
        }
        var request = URLRequest(url: stream.url, timeoutInterval: 120)
        let allowed = Set(["user-agent", "referer", "origin", "accept", "accept-language"])
        for (name, value) in stream.headers where allowed.contains(name.lowercased()) {
            guard !value.contains("\r"), !value.contains("\n"), value.count < 8_192 else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

enum DownloadSource {
    static func url(from text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = detector.firstMatch(in: input, range: NSRange(input.startIndex..., in: input))?.url
            ?? URL(string: input)
        guard let candidate, candidate.absoluteString.count <= 2_048,
              let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443, let host = components.host?.lowercased() else {
            throw MediaSaveError(code: "invalidURL", message: "Enter a YouTube, Instagram or X post link.")
        }
        if let post = NativeMediaRequest.postURL(candidate.absoluteString) { return post }
        let parts = components.path.split(separator: "/").map(String.init)
        if ["instagram.com", "www.instagram.com"].contains(host) {
            if parts.count == 2, parts[0] == "reels",
               parts[1].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                return URL(string: "https://www.instagram.com/reel/\(parts[1])/")!
            }
            if parts.count == 3, parts[0] == "share", ["p", "reel"].contains(parts[1]),
               parts[2].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                return URL(string: "https://www.instagram.com/share/\(parts[1])/\(parts[2])/")!
            }
        }
        var identifier: String?
        if ["youtu.be", "www.youtu.be"].contains(host), parts.count == 1 { identifier = parts[0] }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if components.path == "/watch" { identifier = components.queryItems?.first(where: { $0.name == "v" })?.value }
            else if parts.count == 2 && ["shorts", "live", "embed"].contains(parts[0]) { identifier = parts[1] }
        }
        if let identifier, identifier.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
           let youtube = URL(string: "https://www.youtube.com/watch?v=\(identifier)") { return youtube }
        throw MediaSaveError(code: "invalidURL", message: "Enter a YouTube video, Instagram post or Story, or X post link. Playlists are not supported.")
    }
}
