import Foundation

// Exercise the actual background downloader and URLSession delegate, using a
// synthetic HTTPS response. No App Group, Instagram session or network is used.
private final class TransferFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var onStart: (() throws -> Void)?
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
    func allRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
    func beforeNextResponse(_ action: @escaping () throws -> Void) {
        lock.lock()
        onStart = action
        lock.unlock()
    }
    func runStartAction() throws {
        lock.lock()
        let action = onStart
        onStart = nil
        lock.unlock()
        try action?()
    }
}

private final class TransferFixtureProtocol: URLProtocol {
    static let state = TransferFixtureState()
    // Storage tests do not decode or import media into Photos.
    static let bytes = Data("Synthetic Instagram media bytes".utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "scontent.cdninstagram.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        do {
            try Self.state.runStartAction()
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/jpeg",
                                                      "Content-Length": request.url?.query ?? String(Self.bytes.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.first == 0 && values.last == 1
    }
}

@main
enum BackgroundDownloadStorageTests {
    static func main() async throws {
        let manager = FileManager.default
        // Existing ancestors are intentionally spelled /private/tmp. Foundation
        // may standardize an existing directory to /tmp while leaving a missing
        // descendant under /private/tmp; this was the real pre-transfer failure.
        let base = URL(fileURLWithPath: "/private/tmp/DownloaderBackgroundStorage-" + UUID().uuidString,
                       isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: base) }
        let root = base.appendingPathComponent("Group", isDirectory: true)
        let outside = base.appendingPathComponent("Group-neighbor", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)

        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            precondition(condition, label)
        }
        func canonical(_ url: URL) -> URL {
            guard let result = DownloadStoragePolicy.canonicalFileURL(url) else {
                preconditionFailure("Fixture could not be canonicalized")
            }
            return result
        }
        func fixtureSession(_ container: URL) -> BackgroundDownloadSession {
            BackgroundDownloadSession(containerURL: container, configurationProvider: { _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [TransferFixtureProtocol.self]
                return configuration
            })
        }
        func request() -> URLRequest {
            var request = URLRequest(url: URL(string: "https://scontent.cdninstagram.com/fixture.jpg")!)
            request.setValue("synthetic-session-only", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer synthetic-test-only", forHTTPHeaderField: "Authorization")
            request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
            return request
        }
        func accepted(_ session: BackgroundDownloadSession, _ target: URL, _ label: String) async throws {
            expect(!manager.fileExists(atPath: target.path), label + ": target begins absent")
            let progress = ProgressState()
            let job = UUID()
            let result = try await session.download(request: request(), destination: target, jobID: job,
                                                    progress: { progress.append($0) })
            expect(result == canonical(target), label + ": returns canonical destination")
            expect(try Data(contentsOf: result) == TransferFixtureProtocol.bytes,
                   label + ": delegate moved the real URLSession download file")
            expect(progress.finished, label + ": continuation receives finished progress")
            let completed = await session.completedTransfers()
            expect(completed.contains(where: { $0.jobID == job && $0.destination == result && $0.error == nil }),
                   label + ": delivered transfer is persisted")
            session.acknowledge(target)
            expect(!(await session.completedTransfers()).contains(where: { $0.jobID == job }),
                   label + ": acknowledgment accepts the caller's original alias")
        }
        func rejected(_ session: BackgroundDownloadSession, _ target: URL, _ label: String) async throws {
            let requests = TransferFixtureProtocol.state.count
            do {
                _ = try await session.download(request: request(), destination: target, jobID: UUID(), progress: { _ in })
                preconditionFailure(label + ": destination was accepted")
            } catch {
                expect(error.localizedDescription == "The media could not be saved to the download folder.",
                       label + ": rejected by the actual download storage boundary")
            }
            expect(TransferFixtureProtocol.state.count == requests, label + ": no request started")
        }

        let session = fixtureSession(root)
        let original = root.appendingPathComponent("Downloads/job/attempt/media-0.part")
        try await accepted(session, original, "Existing /private/tmp root with missing descendant")

        // Reverse aliases and different trailing separator representations still
        // point at one container; neither requires creating the output first.
        let alternateRoot = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        let alternateTarget = alternateRoot.appendingPathComponent("Downloads/job/attempt/media-1.part")
        try await accepted(session, alternateTarget, "Alias destination")
        try await accepted(fixtureSession(alternateRoot), root.appendingPathComponent("Downloads/job/attempt/media-2.part"),
                           "Alias container without trailing slash")

        let safeLink = root.appendingPathComponent("inside-link", isDirectory: true)
        try manager.createSymbolicLink(at: safeLink, withDestinationURL: root.appendingPathComponent("Downloads"))
        try await accepted(session, safeLink.appendingPathComponent("job/attempt/media-3.part"), "Internal symlink")

        try await rejected(session, outside.appendingPathComponent("media.part"), "Same-prefix neighbor")
        try await rejected(session, root.appendingPathComponent("Downloads/../../Group-neighbor/escape.part"), "Parent traversal")
        try await rejected(session, root, "Container directory")
        try await rejected(session, URL(string: "https://scontent.cdninstagram.com/not-a-file.jpg")!, "Non-file destination")
        let escapingLink = root.appendingPathComponent("escaping-link", isDirectory: true)
        try manager.createSymbolicLink(at: escapingLink, withDestinationURL: outside)
        try await rejected(session, escapingLink.appendingPathComponent("escape.part"), "External symlink")
        let danglingLink = root.appendingPathComponent("dangling-link", isDirectory: true)
        try manager.createSymbolicLink(at: danglingLink, withDestinationURL: outside.appendingPathComponent("absent-directory"))
        try await rejected(session, danglingLink.appendingPathComponent("escape.part"), "Dangling symlink")

        // The destination is valid when download() starts. Before delivering the
        // HTTP response, replace its existing parent with an external symlink.
        // This tests the delegate's second check, rather than only the first guard.
        let changingParent = root.appendingPathComponent("Downloads/in-flight", isDirectory: true)
        try manager.createDirectory(at: changingParent, withIntermediateDirectories: false)
        let changingTarget = changingParent.appendingPathComponent("escaped-during-transfer.part")
        let requestCount = TransferFixtureProtocol.state.count
        TransferFixtureProtocol.state.beforeNextResponse {
            try manager.removeItem(at: changingParent)
            try manager.createSymbolicLink(at: changingParent, withDestinationURL: outside)
        }
        let changedJob = UUID()
        do {
            _ = try await session.download(request: request(), destination: changingTarget,
                                           jobID: changedJob, progress: { _ in })
            preconditionFailure("Changed parent must not receive a downloaded file")
        } catch {
            expect(error.localizedDescription == "The media could not be saved to the download folder.",
                   "Delegate rechecks destination containment after the response")
        }
        expect(TransferFixtureProtocol.state.count == requestCount + 1,
               "Changed parent fixture passes the initial guard and starts a real transfer")
        expect(!manager.fileExists(atPath: outside.appendingPathComponent("escaped-during-transfer.part").path),
               "Downloaded bytes are never moved outside the container")
        expect((await session.completedTransfers()).contains(where: { $0.jobID == changedJob && $0.error != nil }),
               "Changed parent failure is persisted for recovery")

        let pending = root.appendingPathComponent("Downloads/not-created-yet/media.part")
        let before = DownloadStoragePolicy.destination(pending, within: root)
        try manager.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TransferFixtureProtocol.bytes.write(to: pending)
        let after = DownloadStoragePolicy.destination(pending, within: root)
        expect(before != nil && before == after, "Containment remains consistent before and after output creation")

        // An advertised size above both former caps must not cancel a transfer.
        // URLProtocol supplies a small body so this check needs no huge fixture.
        var largeRequest = request()
        largeRequest.url = URL(string: "https://scontent.cdninstagram.com/large.jpg?\(21 * Int64(1024 * 1024 * 1024))")!
        let largeTarget = root.appendingPathComponent("Downloads/large/media.part")
        let largeJob = UUID()
        let largeResult = try await session.download(request: largeRequest, destination: largeTarget,
                                                     jobID: largeJob, progress: { _ in })
        expect(try Data(contentsOf: largeResult) == TransferFixtureProtocol.bytes,
               "Advertised content length above 20 GB does not cancel or reject downloads")
        expect((await session.completedTransfers()).contains(where: { $0.jobID == largeJob && $0.error == nil }),
               "Large advertised transfer persists a successful result for recovery")
        session.acknowledge(largeResult)

        for request in TransferFixtureProtocol.state.allRequests() {
            expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil,
                   "Transfer request contains no login credentials")
            expect(!request.httpShouldHandleCookies, "Automatic cookies are disabled")
            expect(request.value(forHTTPHeaderField: "Referer") == "https://www.instagram.com/", "Safe CDN referer is preserved")
        }
        print("Background download storage: \(checks) checks passed.")
    }
}
