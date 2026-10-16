import Foundation
import Combine
import UniformTypeIdentifiers

// Exercise the product share model and NSItemProvider loading. Only the task
// center is replaced: no network, App Group or Photos permission is needed.
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published var jobs: [DownloadJob] = []
    var requests: [(String, DownloadDestination)] = []
    var enqueueError: Error?
    var suspendEnqueue = false
    var continuation: CheckedContinuation<Void, Never>?
    var retries: [UUID] = []

    func enqueue(_ source: String, destination: DownloadDestination) async throws -> UUID {
        requests.append((source, destination))
        if suspendEnqueue { await withCheckedContinuation { continuation = $0 } }
        if let enqueueError { throw enqueueError }
        let job = DownloadJob(id: UUID(), sourceURL: try DownloadSource.url(from: source),
                              title: "Fixture", destination: destination, phase: .queued,
                              progress: nil, error: nil, outputFiles: [], createdAt: Date(),
                              savedMediaIDs: [], resolved: nil)
        jobs.append(job)
        return job.id
    }

    func cancel(_ id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].phase = .cancelled }
    }

    func retry(_ id: UUID) async {
        retries.append(id)
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].phase = .queued }
    }
}

private final class ShareFixtureContext: NSExtensionContext {
    private let items: [NSExtensionItem]
    override var inputItems: [Any] { items }
    init(_ items: [NSExtensionItem]) {
        self.items = items
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used by this fixture") }
}

@main
@MainActor
enum ShareDownloadModelTests {
    static func main() async {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            precondition(condition, label)
        }
        let instagram = "https://www.instagram.com/p/Dd8s5QOCeql/"
        let x = "https://x.com/example/status/12345"
        func context(url: String) -> NSExtensionContext {
            let item = NSExtensionItem()
            item.attachments = [NSItemProvider(item: URL(string: url)! as NSURL,
                                               typeIdentifier: UTType.url.identifier)]
            return ShareFixtureContext([item])
        }
        func context(text: String) -> NSExtensionContext {
            let item = NSExtensionItem()
            item.attachments = [NSItemProvider(item: text as NSString,
                                               typeIdentifier: UTType.plainText.identifier)]
            return ShareFixtureContext([item])
        }

        let center = DownloadCenter()
        let model = ShareDownloadModel(center: center)
        await model.load(context(url: instagram))
        expect(center.requests.count == 1 && center.requests[0].0 == instagram,
               "URL sharing automatically enqueues without a confirmation action")
        expect(center.requests[0].1 == .photos, "Sharing saves to Photos")
        expect(!model.loading && !model.starting && model.job != nil, "Share displays the enqueued job")
        await model.load(context(url: x))
        expect(center.requests.count == 1, "Repeated lifecycle loading cannot enqueue another job")
        await model.retry()
        expect(center.retries.isEmpty, "An active job cannot be retried")
        model.cancel()
        expect(model.job?.phase == .cancelled, "Cancel still cancels the real job")
        let id = model.job!.id
        await model.retry()
        expect(center.retries == [id] && model.job?.phase == .queued,
               "Retry reuses the cancelled job instead of creating a duplicate")
        center.jobs[0].phase = .completed
        expect(model.status == "已保存到照片。", "Completion displays a Photos status")

        let textCenter = DownloadCenter()
        let textModel = ShareDownloadModel(center: textCenter)
        await textModel.load(context(text: "Check this post: \(x)"))
        expect(textCenter.requests.count == 1 && textModel.source == x,
               "Plain-text links automatically start")

        let fallbackCenter = DownloadCenter()
        let fallback = ShareDownloadModel(center: fallbackCenter)
        let invalidItem = NSExtensionItem()
        invalidItem.attachments = [NSItemProvider(item: "https://example.com/" as NSString,
                                                 typeIdentifier: UTType.plainText.identifier)]
        invalidItem.attributedContentText = NSAttributedString(string: instagram)
        let secondItem = NSExtensionItem()
        secondItem.attributedContentText = NSAttributedString(string: x)
        await fallback.load(ShareFixtureContext([invalidItem, secondItem]))
        expect(fallbackCenter.requests.count == 1 && fallback.source == instagram,
               "Skips unsupported attachments and enqueues only the first supported link")

        let invalidCenter = DownloadCenter()
        let invalid = ShareDownloadModel(center: invalidCenter)
        await invalid.load(context(text: "https://example.com/"))
        await invalid.retry()
        expect(invalidCenter.requests.isEmpty && invalid.error != nil && !invalid.loading,
               "Invalid input reports an error without downloading")
        let missing = ShareDownloadModel(center: invalidCenter)
        await missing.load(nil)
        expect(missing.error != nil && !missing.loading, "Missing extension input reports an error")

        let failingCenter = DownloadCenter()
        failingCenter.enqueueError = NSError(domain: "ShareFixture", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "Photos authorization failed"])
        let failing = ShareDownloadModel(center: failingCenter)
        await failing.load(context(url: instagram))
        expect(failing.job == nil && failing.error == "Photos authorization failed" && !failing.starting,
               "Pre-job authorization failure remains visible and retryable")
        failingCenter.enqueueError = nil
        await failing.retry()
        expect(failingCenter.requests.count == 2 && failing.job != nil && failing.error == nil,
               "Retry works even when initial enqueue failed before creating a job")

        let suspendedCenter = DownloadCenter()
        suspendedCenter.suspendEnqueue = true
        let suspended = ShareDownloadModel(center: suspendedCenter)
        let load = Task { await suspended.load(context(url: instagram)) }
        while suspendedCenter.continuation == nil { await Task.yield() }
        await suspended.load(context(url: x))
        await suspended.retry()
        expect(suspendedCenter.requests.count == 1 && suspended.starting && !suspended.loading,
               "Pending authorization cannot trigger a second enqueue or hide startup progress")
        suspendedCenter.continuation?.resume()
        await load.value
        expect(suspended.job != nil && !suspended.starting, "Pending automatic startup finishes normally")
        print("\(checks) share auto-download checks passed")
    }
}
