import Foundation

// The real Safari downloader streams a generated response larger than its old
// cap to disk. The fixture uses one reusable chunk; no network or media decode.
private final class LargeMediaFixtureProtocol: URLProtocol {
    static let chunk = Data(repeating: 0x5a, count: 1_024 * 1_024)
    static let chunkCount = 513
    static let size = chunk.count * chunkCount

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "scontent.cdninstagram.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let empty = request.url?.lastPathComponent == "empty.mp4"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "video/mp4",
                                                      "Content-Length": String(empty ? 0 : Self.size)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !empty {
            for _ in 0..<Self.chunkCount { client?.urlProtocol(self, didLoad: Self.chunk) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum MediaDownloadSizeTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LargeMediaFixtureProtocol.self]
        func item(_ filename: String) throws -> NativeMediaRequest {
            try NativeMediaRequest([
                "item": ["url": "https://scontent.cdninstagram.com/\(filename)", "kind": "video"],
                "referrer": "https://www.instagram.com/p/Dd8s5QOCeql/"
            ])
        }
        let result = try await MediaDownload.download(item("large.mp4"), configuration: configuration)
        defer { try? FileManager.default.removeItem(at: result.directory) }
        let bytes = try result.file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(bytes == LargeMediaFixtureProtocol.size, "All 513 MiB must reach the downloaded file")
        precondition(result.mimeType == "video/mp4", "MIME type is retained")
        let file = try FileHandle(forReadingFrom: result.file)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(LargeMediaFixtureProtocol.size - 1))
        let lastByte = try file.read(upToCount: 1)
        precondition(lastByte == Data([0x5a]), "The last byte was streamed to disk")
        do {
            _ = try await MediaDownload.download(item("empty.mp4"), configuration: configuration)
            preconditionFailure("An empty download must still fail")
        } catch let error as MediaSaveError {
            precondition(error.code == "emptyMedia", "Empty-file validation is preserved")
        }
        print("Safari download: 513 MiB streamed successfully; empty media rejected.")
    }
}
