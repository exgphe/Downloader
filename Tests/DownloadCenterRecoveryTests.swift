import Foundation

// Deterministic system boundaries: these tests exercise the real persistent center,
// without network transfers, PhotoKit permission prompts, or background scheduling.
final class BackgroundDownloadSession: @unchecked Sendable {
    static let shared = BackgroundDownloadSession()
    static let appGroup = "test.downloader"
    struct CompletedTransfer {
        var jobID: UUID
        var destination: URL
        var error: String?
    }
    var transfers: [CompletedTransfer] = []
    var recoveryHandler: (() async -> Void)?
    func reattachOwnedSession() {}
    func completedTransfers() async -> [CompletedTransfer] { transfers }
    func acknowledge(_ url: URL) { transfers.removeAll { $0.destination == url } }
    func cancel(jobID: UUID) {}
    func download(request: URLRequest, destination: URL, jobID: UUID, progress: @escaping (Double) -> Void) async throws -> URL {
        progress(0)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("downloaded-media".utf8).write(to: destination)
        progress(1)
        return destination
    }
}

@MainActor final class BackgroundExecution {
    static let shared = BackgroundExecution()
    var recoveryHandler: ((UUID) async -> Void)?
    func register() {}
    func begin(jobID: UUID, title: String, cancel: @escaping () -> Void) {}
    func update(jobID: UUID, progress: Double?, subtitle: String) {}
    func finish(jobID: UUID, success: Bool) {}
}

@MainActor enum NativePhotoSaver {
    static var saved: [String] = []
    static var reject = false
    static var delay: UInt64 = 0
    static func authorize() async throws {}
    static func saveFile(_ file: URL, kind: MediaKind, filename: String?, mimeType: String? = nil) async throws {
        if reject { throw MediaSaveError(code: "photosDenied", message: "Photos access denied") }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        saved.append(filename ?? "")
    }
}

@MainActor enum EmbeddedMediaResolver {
    static var manifest: ResolvedDownload!
    static var failure: MediaSaveError?
    static func resolve(sourceURL: URL, destination: DownloadDestination) async throws -> ResolvedDownload {
        if let failure { throw failure }
        return manifest
    }
}

@MainActor enum MediaRemux {
    static var beforeCopy: (() throws -> Void)?
    static func combine(_ inputs: [URL], into output: URL, container: String) async throws {
        try beforeCopy?()
        try inputs.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }.write(to: output)
    }
}

@main struct RecoveryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloaderRecovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(string: "https://www.instagram.com/p/Test123/")!
        let image = ResolvedStream(url: URL(string: "https://scontent.cdninstagram.com/test.jpg")!, headers: [:], role: .image, container: "jpg")
        let media = ["first", "second"].map { ResolvedMedia(id: $0, kind: .image, filename: $0 + ".jpg", container: "jpg", streams: [image]) }
        let manifest = ResolvedDownload(sourceURL: source, title: "Carousel", media: media)
        EmbeddedMediaResolver.manifest = manifest

        func job(_ phase: DownloadPhase, saved: Set<String> = []) -> DownloadJob {
            DownloadJob(id: UUID(), sourceURL: source, title: "Carousel", destination: .photos, phase: phase,
                        progress: nil, error: nil, outputFiles: [], createdAt: Date(), savedMediaIDs: saved, resolved: manifest)
        }
        func persist(_ job: DownloadJob) throws {
            try JSONEncoder().encode(job).write(to: root.appendingPathComponent(job.id.uuidString + ".json"), options: .atomic)
        }
        func stream(_ job: DownloadJob, _ index: Int) -> URL {
            root.appendingPathComponent(job.id.uuidString).appendingPathComponent(job.attemptID.uuidString)
                .appendingPathComponent("media-\(index)-stream-0.part")
        }
        func writeStream(_ job: DownloadJob, _ index: Int) throws {
            let file = stream(job, index)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("media".utf8).write(to: file)
        }
        let recovered = job(.downloading, saved: ["first"])
        try persist(recovered)
        try writeStream(recovered, 1)
        let cancelled = job(.cancelled)
        try persist(cancelled)
        try writeStream(cancelled, 0)
        try writeStream(cancelled, 1)
        let failed = job(.downloading)
        try persist(failed)
        BackgroundDownloadSession.shared.transfers = [.init(jobID: failed.id, destination: stream(failed, 0), error: "HTTP 403")]
        BackgroundDownloadSession.shared.transfers.append(.init(jobID: recovered.id, destination: stream(recovered, 1), error: nil))
        var stale = job(.downloading)
        let abandoned = stream(stale, 0)
        stale.attemptID = UUID()
        try persist(stale)
        BackgroundDownloadSession.shared.transfers.append(.init(jobID: stale.id, destination: abandoned, error: "old cancellation"))

        let center = DownloadCenter(storageRoot: root)
        await center.start()
        for _ in 0..<100 {
            if center.jobs.first(where: { $0.id == recovered.id })?.phase == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(center.jobs.first(where: { $0.id == recovered.id })?.phase == .completed)
        precondition(NativePhotoSaver.saved == ["second.jpg"], "Recovery must skip already saved media")
        precondition(center.jobs.first(where: { $0.id == cancelled.id })?.phase == .cancelled)
        precondition(center.jobs.first(where: { $0.id == failed.id })?.phase == .failed)
        precondition(center.jobs.first(where: { $0.id == stale.id })?.phase == .downloading, "Old transfer errors cannot fail a new attempt")
        center.cancel(stale.id)

        let denied = job(.downloading)
        try persist(denied)
        try writeStream(denied, 0)
        try writeStream(denied, 1)
        BackgroundDownloadSession.shared.transfers.append(contentsOf: (0...1).map { .init(jobID: denied.id, destination: stream(denied, $0), error: nil) })
        NativePhotoSaver.reject = true
        await center.recoverBackgroundTransfers()
        for _ in 0..<100 {
            if center.jobs.first(where: { $0.id == denied.id })?.phase == .failed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let deniedState = center.jobs.first(where: { $0.id == denied.id })!
        precondition(deniedState.phase == .failed && deniedState.savedMediaIDs.isEmpty)
        precondition(deniedState.errorCode == "photosDenied", "Typed failures must survive persistence")
        precondition(FileManager.default.fileExists(atPath: stream(denied, 0).path), "Failed imports retain media for recovery")
        NativePhotoSaver.reject = false
        await center.retry(denied.id)
        for _ in 0..<100 {
            if center.jobs.first(where: { $0.id == denied.id })?.phase == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retried = center.jobs.first(where: { $0.id == denied.id })!
        precondition(retried.phase == .completed && retried.savedMediaIDs == ["first", "second"])
        precondition(retried.errorCode == nil, "Successful retry must clear the login/error hint")
        precondition(retried.attemptID != denied.attemptID)
        precondition(NativePhotoSaver.saved == ["second.jpg", "first.jpg", "second.jpg"])

        let concurrent = job(.downloading)
        try persist(concurrent)
        for index in 0...1 { try writeStream(concurrent, index) }
        BackgroundDownloadSession.shared.transfers.append(contentsOf: (0...1).map { .init(jobID: concurrent.id, destination: stream(concurrent, $0), error: nil) })
        NativePhotoSaver.delay = 100_000_000
        let secondCenter = DownloadCenter(storageRoot: root)
        async let firstRecovery: Void = center.recoverBackgroundTransfers()
        async let secondRecovery: Void = secondCenter.start()
        _ = await (firstRecovery, secondRecovery)
        precondition(center.jobs.first(where: { $0.id == concurrent.id })?.phase == .completed)
        precondition(secondCenter.jobs.first(where: { $0.id == concurrent.id })?.phase == .completed)
        precondition(NativePhotoSaver.saved.count == 5, "Two processes recovering one job must not import duplicates")
        NativePhotoSaver.delay = 0

        var remotelyCancelled = job(.downloading)
        let video = ResolvedStream(url: URL(string: "https://scontent.cdninstagram.com/video.mp4")!, headers: [:], role: .video, container: "mp4")
        let audio = ResolvedStream(url: URL(string: "https://scontent.cdninstagram.com/audio.m4a")!, headers: [:], role: .audio, container: "m4a")
        remotelyCancelled.resolved = .init(sourceURL: source, title: "Video", media: [.init(id: "video", kind: .video, filename: "video.mp4", container: "mp4", streams: [video, audio])])
        try persist(remotelyCancelled)
        let videoFile = stream(remotelyCancelled, 0)
        try writeStream(remotelyCancelled, 0)
        let audioFile = videoFile.deletingLastPathComponent().appendingPathComponent("media-0-stream-1.part")
        try Data("audio".utf8).write(to: audioFile)
        BackgroundDownloadSession.shared.transfers.append(contentsOf: [videoFile, audioFile].map { .init(jobID: remotelyCancelled.id, destination: $0, error: nil) })
        MediaRemux.beforeCopy = {
            var cancelledOnDisk = remotelyCancelled
            cancelledOnDisk.phase = .cancelled
            try persist(cancelledOnDisk)
        }
        await center.recoverBackgroundTransfers()
        precondition(center.jobs.first(where: { $0.id == remotelyCancelled.id })?.phase == .cancelled)
        precondition(NativePhotoSaver.saved.count == 5, "Cross-process cancellation during remux must be checked before PhotoKit")
        EmbeddedMediaResolver.failure = MediaSaveError(code: "loginRequired", message: "Sync Instagram login from Safari")
        let loginID = try await center.enqueue(source.absoluteString, destination: .photos)
        for _ in 0..<100 {
            if center.jobs.first(where: { $0.id == loginID })?.phase == .failed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(center.jobs.first(where: { $0.id == loginID })?.errorCode == "loginRequired", "Login sync guide must be based on a persisted error code")
        EmbeddedMediaResolver.failure = nil
        await center.retry(loginID)
        for _ in 0..<100 {
            if center.jobs.first(where: { $0.id == loginID })?.phase == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let loggedInJob = center.jobs.first(where: { $0.id == loginID })!
        precondition(loggedInJob.phase == .completed && loggedInJob.errorCode == nil)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loggedInJob)) as! [String: Any]
        legacy.removeValue(forKey: "errorCode")
        let legacyJob = try JSONDecoder().decode(DownloadJob.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyJob.errorCode == nil, "Old task records must remain readable")
        print("DownloadCenter recovery, cancellation, Photos failure, login sync retry and concurrent saving passed")
    }
}
