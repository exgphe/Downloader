import Foundation
import AppIntents
import UniformTypeIdentifiers

@available(macOS 13.0, iOS 16.0, visionOS 1.0, *)
enum ShortcutDownloadDestination: String, AppEnum {
    case photos, files
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Save to"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .photos: "Photos · compatible quality",
        .files: "Files · best available quality"
    ]
}

@available(macOS 13.0, iOS 16.0, visionOS 1.0, *)
struct DownloadMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Download media"
    static var description = IntentDescription("Download a YouTube video, Instagram post or Story, or X post locally. Short downloads can finish without opening the app; use the app for longer jobs. Files are returned to the next Shortcuts action, such as Save File.")
    static var openAppWhenRun = false
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Link") var link: String
    @Parameter(title: "Save to", default: .photos) var destination: ShortcutDownloadDestination
    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$link) to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let center = DownloadCenter.shared
        let id = try await center.enqueue(link, destination: destination == .photos ? .photos : .files)
        return try await withTaskCancellationHandler(operation: {
            while true {
                try Task.checkCancellation()
                guard let job = center.jobs.first(where: { $0.id == id }) else {
                    throw intentError("The download could not be found. Open Downloader to check its status.")
                }
                switch job.phase {
                case .completed:
                    let files = job.destination == .files ? job.outputFiles.map { IntentFile(fileURL: $0) } : []
                    let dialog: IntentDialog = job.destination == .photos
                        ? "Saved to Photos."
                        : "Downloaded. Use Save File to choose where to keep the returned files."
                    return IntentResultContainer<[IntentFile], Never, Never, IntentDialog>.result(value: files, dialog: dialog)
                case .failed: throw intentError(job.error ?? "The download failed.")
                case .cancelled: throw CancellationError()
                default: try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }, onCancel: {
            Task { @MainActor in center.cancel(id) }
        })
    }

    private func intentError(_ message: String) -> NSError {
        NSError(domain: "Downloader.Shortcuts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// URL routing does not grant arbitrary file or media access; the normal source policy
/// still validates every link before the DownloadCenter creates a job.
@MainActor
enum DownloadIncomingURL {
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        var text = url.absoluteString
        var destination = DownloadDestination.photos
        if url.scheme?.lowercased() == "downloader" {
            guard url.host == "download", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let link = components.queryItems?.first(where: { $0.name == "url" })?.value else { return false }
            text = link
            if components.queryItems?.first(where: { $0.name == "destination" })?.value == "files" { destination = .files }
        }
        guard let source = try? DownloadSource.url(from: text) else { return false }
        Task { _ = try? await DownloadCenter.shared.enqueue(source.absoluteString, destination: destination) }
        return true
    }
}
