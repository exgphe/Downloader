import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class ShareDownloadModel: ObservableObject {
    @Published private(set) var source = ""
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published private(set) var job: DownloadJob?
    @Published private(set) var starting = false
    @Published private(set) var retrying = false
    private let center: DownloadCenter
    private var hasLoadedInput = false
    private var jobID: UUID?
    private var observation: AnyCancellable?

    init(center: DownloadCenter? = nil) {
        let center = center ?? .shared
        self.center = center
        observation = center.$jobs.sink { [weak self] jobs in
            guard let self, let id = self.jobID else { return }
            self.job = jobs.first { $0.id == id }
        }
    }

    func load(_ context: NSExtensionContext?) async {
        // View lifecycle callbacks can overlap while an item provider or Photos
        // authorization is pending. A share invocation must enqueue only once.
        guard !hasLoadedInput else { return }
        hasLoadedInput = true
        defer { loading = false }
        guard let items = context?.inputItems as? [NSExtensionItem] else {
            error = String(localized: "No download link was shared.")
            return
        }
        for item in items.prefix(4) {
            for provider in (item.attachments ?? []).prefix(4) {
                for type in [UTType.url.identifier, UTType.plainText.identifier]
                    where provider.hasItemConformingToTypeIdentifier(type) {
                    guard let value = try? await load(provider, type: type) else { continue }
                    if let url = try? DownloadSource.url(from: value) {
                        source = url.absoluteString
                        loading = false
                        await start()
                        return
                    }
                }
            }
            if let text = item.attributedContentText?.string,
               let url = try? DownloadSource.url(from: text) {
                source = url.absoluteString
                loading = false
                await start()
                return
            }
        }
        error = String(localized: "Share a link to a YouTube video, an Instagram post or Story, or an X post.")
    }

    private func load(_ provider: NSItemProvider, type: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
                else if let string = item as? String { continuation.resume(returning: string) }
                else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: NSError(domain: "Downloader.Share", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not read the shared link.")]))
                }
            }
        }
    }

    private func start() async {
        guard !source.isEmpty, !starting, jobID == nil else { return }
        starting = true
        error = nil
        defer { starting = false }
        do {
            let id = try await center.enqueue(source, destination: .photos)
            jobID = id
            job = center.jobs.first { $0.id == id }
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        if let jobID { center.cancel(jobID) }
    }

    func retry() async {
        guard !retrying, !starting else { return }
        // Permission or storage failures can occur before a job exists.
        guard let jobID else { await start(); return }
        guard let job, job.phase == .failed || job.phase == .cancelled else { return }
        retrying = true
        error = nil
        defer { retrying = false }
        await center.retry(jobID)
    }

    var status: String {
        guard let job else { return "" }
        switch job.phase {
        case .queued: return String(localized: "Queued")
        case .resolving: return String(localized: "Finding the best media…")
        case .downloading: return String(localized: "Downloading…")
        case .converting: return String(localized: "Converting AV1 to HEVC…")
        case .saving: return String(localized: "Saving to Photos…")
        case .completed: return String(localized: "Saved to Photos.")
        case .failed: return job.error.map(MediaSaveError.localizedMessage) ?? String(localized: "Download failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}
