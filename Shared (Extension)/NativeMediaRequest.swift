import Foundation

struct MediaSaveError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

enum MediaKind: String { case image, video }

/// Validation is repeated natively: page code is not a trust boundary.
struct NativeMediaRequest {
    let url: URL
    let kind: MediaKind
    let filename: String?
    let referrer: URL
    let policy: MediaURLPolicy

    init(_ message: [String: Any]) throws {
        guard let item = message["item"] as? [String: Any],
              let address = item["url"] as? String, address.count <= 16_384,
              let url = URL(string: address),
              let kindString = item["kind"] as? String, let kind = MediaKind(rawValue: kindString),
              let post = message["referrer"] as? String, let referrer = Self.postURL(post) else {
            throw MediaSaveError(code: "invalidRequest", message: "The media URL, media type, or post URL is invalid.")
        }
        let policy = MediaURLPolicy()
        guard policy.allows(url) else {
            throw MediaSaveError(code: "unsafeURL", message: "The media URL is outside the supported Instagram and X media locations.")
        }
        self.url = url
        self.kind = kind
        self.referrer = referrer
        self.policy = policy
        // The supplied name is metadata only. It never becomes a local path.
        filename = (item["filename"] as? String).map { String(($0 as NSString).lastPathComponent.prefix(180)) }
    }

    static func postURL(_ value: String) -> URL? {
        guard value.count <= 2_048, var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        let valid: Bool
        switch host {
        case "instagram.com", "www.instagram.com":
            valid = parts.count == 2 && ["p", "reel", "tv"].contains(parts[0])
                && parts[1].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        case "x.com", "www.x.com", "twitter.com", "www.twitter.com":
            valid = (parts.count == 3 && parts[1] == "status"
                     && parts[0].range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
                     && parts[2].range(of: "^[0-9]+$", options: .regularExpression) != nil)
                || (parts.count == 4 && parts[0] == "i" && parts[1] == "web" && parts[2] == "status"
                    && parts[3].range(of: "^[0-9]+$", options: .regularExpression) != nil)
        default: valid = false
        }
        guard valid else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func downloadRequest() -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue(kind == .image ? "image/*" : "video/mp4,video/quicktime,application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }
}

struct MediaURLPolicy {
    func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host?.lowercased() else { return false }
        guard components.scheme?.lowercased() == "https", components.port == nil || components.port == 443 else { return false }
        return host == "cdninstagram.com" || host.hasSuffix(".cdninstagram.com")
            || host == "fbcdn.net" || host.hasSuffix(".fbcdn.net")
            || host == "video.twimg.com" || host == "pbs.twimg.com"
    }

    func allowsRedirect(from source: URL, to target: URL) -> Bool {
        allows(source) && allows(target)
    }
}
