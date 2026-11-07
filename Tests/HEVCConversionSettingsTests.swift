import Foundation

@main
enum HEVCConversionSettingsTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) { checks += 1; precondition(condition, label) }
        let domain = "Downloader-HEVC-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var settings = HEVCConversionPreferences.load(from: defaults)
        expect(!settings.enabled, "Conversion is opt-in by default")
        settings.enabled = true
        settings.quality = .high
        settings.resolution = .hd
        settings.customBitrate = true
        settings.bitrateMbps = 17
        HEVCConversionPreferences.save(settings, to: defaults)
        expect(HEVCConversionPreferences.load(from: defaults) == settings, "All options survive persistence")
        let dimensions = settings.dimensions(width: 3840, height: 2160)
        expect(dimensions.width == 1920 && dimensions.height == 1080, "1080p downsizes while preserving aspect ratio")
        let small = settings.dimensions(width: 1280, height: 720)
        expect(small.width == 1280 && small.height == 720, "Small videos are never upscaled")
        expect(settings.bitrate(width: 3840, height: 2160, frameRate: 60) == 17_000_000, "Manual Mbps maps to encoder bits per second")
        settings.customBitrate = false
        settings.quality = .compact
        let compact = settings.bitrate(width: 1920, height: 1080, frameRate: 30)
        settings.quality = .balanced
        let balanced = settings.bitrate(width: 1920, height: 1080, frameRate: 30)
        settings.quality = .high
        let high = settings.bitrate(width: 1920, height: 1080, frameRate: 30)
        expect(compact < balanced && balanced < high, "Quality presets change the actual target bitrate")
        expect(settings.bitrate(width: 1920, height: 1080, frameRate: .nan) == high, "Unknown frame rate uses a finite default")
        let av1 = ResolvedStream(url: URL(string: "https://video.googlevideo.com/video")!, headers: [:],
                                 role: .video, container: "webm", videoCodec: "av01.0.16M.10")
        var media = ResolvedMedia(id: "sample", kind: .video, filename: "sample.mkv", container: "mkv", streams: [av1])
        let youtube = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!
        expect(settings.shouldConvert(source: youtube, media: media), "YouTube AV1 is converted when enabled")
        expect(!settings.shouldConvert(source: URL(string: "https://x.com/example/status/123")!, media: media), "Other sites are unaffected")
        for codec in ["avc1", "hvc1", "vp09", "unknown", "av1-not-a-codec"] {
            media.streams[0].videoCodec = codec
            expect(!settings.shouldConvert(source: youtube, media: media), "Non-AV1 codecs stay untouched: " + codec)
        }
        media.streams[0] = av1
        settings.enabled = false
        expect(!settings.shouldConvert(source: youtube, media: media), "Disabling conversion preserves original AV1")
        defaults.set(Data("invalid settings".utf8), forKey: HEVCConversionPreferences.key)
        expect(!HEVCConversionPreferences.load(from: defaults).enabled, "Unreadable settings safely default to disabled")
        var job = DownloadJob(id: UUID(), sourceURL: youtube, title: "Video", destination: .photos,
                              phase: .converting, progress: 0.4, error: nil, outputFiles: [], createdAt: Date(),
                              savedMediaIDs: [], resolved: nil, hevcConversion: settings)
        let decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        expect(decoded.phase == .converting && decoded.hevcConversion == settings, "Conversion and settings survive job recovery")
        job.hevcConversion = nil
        let legacy = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        expect(legacy.hevcConversion == nil, "Jobs without conversion settings remain readable")
        print("\(checks) HEVC policy, settings persistence and job compatibility checks passed")
    }
}
