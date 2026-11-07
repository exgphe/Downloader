import Foundation

enum HEVCQuality: String, Codable, CaseIterable, Sendable {
    case compact, balanced, high
    var bitsPerPixel: Double {
        switch self {
        case .compact: return 0.025
        case .balanced: return 0.05
        case .high: return 0.08
        }
    }
}

enum HEVCResolution: String, Codable, CaseIterable, Sendable {
    case original, hd, uhd
    var maximumHeight: Int? {
        switch self {
        case .original: return nil
        case .hd: return 1080
        case .uhd: return 2160
        }
    }
}

/// Snapshotted in each job so recovery and retries use the same conversion policy.
struct HEVCConversionSettings: Codable, Equatable, Sendable {
    var enabled = false
    var quality: HEVCQuality = .balanced
    var resolution: HEVCResolution = .original
    var customBitrate = false
    var bitrateMbps = 20

    func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(resolution.maximumHeight ?? height) / Double(max(1, height)))
        return (max(2, Int(Double(width) * scale) / 2 * 2),
                max(2, Int(Double(height) * scale) / 2 * 2))
    }

    func bitrate(width: Int, height: Int, frameRate: Double) -> Int64 {
        if customBitrate { return Int64(min(200, max(1, bitrateMbps))) * 1_000_000 }
        let fps = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        return Int64(min(200_000_000, max(250_000, Double(width) * Double(height) * fps * quality.bitsPerPixel)))
    }

    static func isYouTube(_ url: URL) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"]
            .contains(url.host?.lowercased() ?? "")
    }

    func shouldConvert(source: URL, media: ResolvedMedia) -> Bool {
        enabled && Self.isYouTube(source) && media.kind == .video && media.streams.contains {
            let codec = $0.videoCodec?.lowercased() ?? ""
            return codec == "av1" || codec == "av01" || codec.hasPrefix("av01.") || codec.hasPrefix("av1.")
        }
    }
}

enum HEVCConversionPreferences {
    static let key = "youtubeHEVCConversion"
    static let appGroup = "group.wang.xiaolin.Downloader"
    static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load(from defaults: UserDefaults = sharedDefaults) -> HEVCConversionSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(HEVCConversionSettings.self, from: data) else {
            return HEVCConversionSettings()
        }
        return settings
    }

    static func save(_ settings: HEVCConversionSettings, to defaults: UserDefaults = sharedDefaults) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}
