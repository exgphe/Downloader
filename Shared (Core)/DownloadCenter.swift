import Foundation
import Combine
import Darwin

/// Each job has its own atomic record so a share process cannot overwrite other jobs.
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var jobs: [DownloadJob] = []
    private var started = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var fractions: [UUID: [String: Double]] = [:]
    private let storageRoot: URL?
    private let conversionDefaults: UserDefaults?

    init(storageRoot: URL? = nil, conversionDefaults: UserDefaults? = nil) {
        self.storageRoot = storageRoot
        self.conversionDefaults = conversionDefaults
    }

    private var root: URL? {
        storageRoot ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BackgroundDownloadSession.appGroup)?
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    func start() async {
        guard !started else { return }
        started = true
        reload()
        BackgroundDownloadSession.shared.recoveryHandler = { [weak self] in
            await self?.recoverBackgroundTransfers()
        }
        BackgroundExecution.shared.recoveryHandler = { [weak self] _ in
            await self?.recoverBackgroundTransfers()
        }
        BackgroundExecution.shared.register()
        BackgroundDownloadSession.shared.reattachOwnedSession()
        await recoverBackgroundTransfers()
    }

    @discardableResult
    func enqueue(_ text: String, destination: DownloadDestination) async throws -> UUID {
        let source = try DownloadSource.url(from: text)
        let conversion = HEVCConversionPreferences.load(from: conversionDefaults ?? HEVCConversionPreferences.sharedDefaults)
        await start()
        guard root != nil else { throw failure("The shared download folder is unavailable. Check the app's App Group signing and reopen Downloader.") }
        if destination == .photos { try await NativePhotoSaver.authorize() }
        let job = DownloadJob(id: UUID(), sourceURL: source, title: source.host ?? "Download",
                              destination: destination, phase: .queued, progress: nil, error: nil,
                              outputFiles: [], createdAt: Date(), savedMediaIDs: [], resolved: nil,
                              ownerProcessID: getpid(),
                              hevcConversion: conversion.enabled && HEVCConversionSettings.isYouTube(source) ? conversion : nil)
        try store(job)
        launch(job.id, resolve: true)
        return job.id
    }

    func cancel(_ id: UUID) {
        guard var job = read(id) ?? jobs.first(where: { $0.id == id }), !job.phase.isFinished else { return }
        job.phase = .cancelled
        job.error = nil
        job.errorCode = nil
        try? store(job)
        tasks[id]?.cancel()
        BackgroundDownloadSession.shared.cancel(jobID: id)
        BackgroundExecution.shared.finish(jobID: id, success: false)
    }

    func retry(_ id: UUID) async {
        guard tasks[id] == nil, var job = read(id), [.failed, .cancelled].contains(job.phase) else { return }
        do {
            if job.destination == .photos { try await NativePhotoSaver.authorize() }
            // Expiring CDN links are resolved again. A new folder isolates late callbacks
            // from an older cancelled transfer; successfully saved media are retained.
            BackgroundDownloadSession.shared.cancel(jobID: id)
            job.attemptID = UUID()
            job.ownerProcessID = getpid()
            job.phase = .queued
            job.progress = nil
            job.error = nil
            job.errorCode = nil
            job.resolved = nil
            try store(job)
            launch(id, resolve: true)
        } catch { markFailed(id, error: error) }
    }

    func recoverBackgroundTransfers() async {
        reload()
        let transfers = await BackgroundDownloadSession.shared.completedTransfers()
        var readyTasks: [Task<Void, Never>] = []
        for job in jobs {
            let related = transfers.filter { $0.jobID == job.id }
            if job.phase.isFinished {
                related.forEach { BackgroundDownloadSession.shared.acknowledge($0.destination) }
                BackgroundExecution.shared.finish(jobID: job.id, success: job.phase == .completed)
                continue
            }
            if let manifest = job.resolved {
                let pending = manifest.media.enumerated().filter { !job.savedMediaIDs.contains($0.element.id) }
                let complete = pending.allSatisfy { index, media in
                    media.streams.indices.allSatisfy {
                        let file = streamFile(job, media: index, stream: $0)
                        return nonempty(file) && related.contains { DownloadStoragePolicy.sameFile($0.destination, file) && $0.error == nil }
                    }
                }
                if complete {
                    if tasks[job.id] == nil { launch(job.id, resolve: false) }
                    if let task = tasks[job.id] { readyTasks.append(task) }
                } else if tasks[job.id] == nil, let failed = related.first(where: {
                    $0.error != nil && DownloadStoragePolicy.isDescendant($0.destination, of: attemptDirectory(job))
                }) {
                    markFailed(job.id, error: failure(failed.error ?? "The media transfer failed."))
                }
            } else if tasks[job.id] == nil, !ownerIsAlive(job) {
                // No media tasks existed yet, so resuming resolution cannot duplicate
                // a system-owned transfer or a live share extension's extraction.
                launch(job.id, resolve: true)
            }
        }
        // UIKit may suspend the host immediately after its background event
        // completion. Finish only the jobs whose transfers are already delivered.
        for task in readyTasks { await task.value }
    }

    private func launch(_ id: UUID, resolve: Bool) {
        guard tasks[id] == nil, let attempt = read(id)?.attemptID else { return }
        BackgroundExecution.shared.begin(jobID: id, title: read(id)?.title ?? "Download") { [weak self] in self?.cancel(id) }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                tasks.removeValue(forKey: id)
                fractions.removeValue(forKey: id)
                reload() // Publish cancellations or completion written by another process.
            }
            do {
                if resolve { try await prepareAndDownload(id, attempt: attempt) }
                guard read(id)?.attemptID == attempt else { throw CancellationError() }
                try await finishMedia(id)
            } catch is CancellationError {
                if read(id)?.attemptID == attempt { cancel(id) }
            } catch {
                if read(id)?.attemptID == attempt { markFailed(id, error: error) }
            }
        }
    }

    private func prepareAndDownload(_ id: UUID, attempt: UUID) async throws {
        var job = try activeJob(id)
        job.ownerProcessID = getpid()
        job.phase = .resolving
        job.progress = nil
        try store(job)
        BackgroundExecution.shared.update(jobID: id, progress: nil, subtitle: "Finding the best media…")
        let manifest = try await EmbeddedMediaResolver.resolve(sourceURL: job.sourceURL, destination: job.destination,
                                                              allowAV1: job.hevcConversion?.enabled == true)
        try Task.checkCancellation()
        job = try activeJob(id)
        guard job.attemptID == attempt else { throw CancellationError() }
        guard !manifest.media.isEmpty, manifest.media.count <= 100,
              Set(manifest.media.map(\.id)).count == manifest.media.count,
              manifest.media.allSatisfy({ (1...2).contains($0.streams.count) }) else {
            throw failure("The post did not contain a complete set of downloadable media.")
        }
        job.resolved = manifest
        job.title = manifest.title
        // Keep the share panel in its preparation stage until every stream has
        // been persisted and resumed; closing it earlier could omit audio/media.
        job.progress = nil
        try store(job) // Persist every destination before starting system-owned transfers.
        let pending = manifest.media.enumerated().filter { !job.savedMediaIDs.contains($0.element.id) }
        let streamCount = pending.reduce(0) { $0 + $1.element.streams.count }
        let attemptID = job.attemptID
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (mediaIndex, media) in pending {
                for (streamIndex, stream) in media.streams.enumerated() {
                    let request = try DownloadURLPolicy.request(for: stream)
                    let destination = streamFile(job, media: mediaIndex, stream: streamIndex)
                    let key = "\(mediaIndex)-\(streamIndex)"
                    group.addTask { [self] in
                        _ = try await BackgroundDownloadSession.shared.download(request: request, destination: destination, jobID: id) { progress in
                            Task { @MainActor in self.report(id, attempt: attemptID, key: key, progress: progress, count: streamCount) }
                        }
                    }
                }
            }
            while try await group.next() != nil {}
        }
        try Task.checkCancellation()
    }

    private func finishMedia(_ id: UUID) async throws {
        let initial = try activeJob(id)
        // Completion events may reach the host while a share extension is also saving.
        // An advisory lock prevents both processes importing the same media concurrently.
        let directory = attemptDirectory(initial)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.deletingLastPathComponent().appendingPathComponent("saving.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw failure("The download record could not be locked for saving.") }
        var locked = false
        defer { if locked { flock(descriptor, LOCK_UN) }; close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw failure("The download record could not be locked for saving.") }
            // Keep this recovery alive until the other process publishes its result.
            // A suspended share process can resume, or release its lock on termination.
            try await Task.sleep(nanoseconds: 500_000_000)
            if let latest = read(id), latest.phase.isFinished {
                reload()
                BackgroundExecution.shared.finish(jobID: id, success: latest.phase == .completed)
                return
            }
            guard read(id)?.attemptID == initial.attemptID else { throw CancellationError() }
        }
        locked = true
        var job = try activeJob(id)
        guard job.attemptID == initial.attemptID, let manifest = job.resolved else { throw CancellationError() }
        job.phase = .saving
        job.ownerProcessID = getpid()
        job.progress = 0.9
        try store(job)
        BackgroundExecution.shared.update(jobID: id, progress: job.progress, subtitle: job.destination == .photos ? "Saving to Photos…" : "Preparing files…")
        for (index, media) in manifest.media.enumerated() {
            job = try activeJob(id)
            guard job.attemptID == initial.attemptID else { throw CancellationError() }
            if job.savedMediaIDs.contains(media.id) { continue }
            let streams = media.streams.indices.map { streamFile(job, media: index, stream: $0) }
            guard streams.allSatisfy(nonempty) else { throw failure("Some media files are missing. Retry to download them again.") }
            let conversion = job.hevcConversion
            let shouldConvert = conversion?.shouldConvert(source: job.sourceURL, media: media) == true
            let container = shouldConvert ? (job.destination == .photos ? "mp4" : "mkv") : media.container
            let filename = shouldConvert ? (safeFilename(media) as NSString).deletingPathExtension + "-hevc." + container : safeFilename(media)
            let output = directory.appendingPathComponent("\(index + 1)-" + filename)
            let original = directory.appendingPathComponent("\(index + 1)-conversion-input.mkv")
            defer { try? FileManager.default.removeItem(at: original) }
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            do {
                if media.streams.count == 2 {
                    let sorted = media.streams.enumerated().sorted { $0.element.role == .video && $1.element.role != .video }
                    guard sorted.map(\.element.role) == [.video, .audio] else { throw failure("The video and audio streams could not be matched.") }
                    try await MediaRemux.combine(sorted.map { streams[$0.offset] }, into: shouldConvert ? original : output,
                                                 container: shouldConvert ? "mkv" : media.container)
                } else if !shouldConvert {
                    try FileManager.default.copyItem(at: streams[0], to: output)
                }
            }
            if shouldConvert, let conversion {
                job.phase = .converting
                job.progress = nil
                try store(job)
                BackgroundExecution.shared.update(jobID: id, progress: nil, subtitle: "Converting AV1 to HEVC…")
                let attempt = job.attemptID
                try await HEVCTranscoder.convert(media.streams.count == 2 ? original : streams[0], into: output,
                                                 container: container, settings: conversion) { [self] fraction in
                    Task { @MainActor in
                        guard var current = read(id), current.attemptID == attempt, current.phase == .converting else { return }
                        current.progress = fraction
                        try? store(current)
                        BackgroundExecution.shared.update(jobID: id, progress: fraction, subtitle: "Converting AV1 to HEVC…")
                    }
                }
                job = try activeJob(id)
                job.phase = .saving
                job.progress = nil
                try store(job)
            }
            try Task.checkCancellation()
            let beforeSave = try activeJob(id)
            guard beforeSave.attemptID == job.attemptID else { throw CancellationError() }
            if job.destination == .photos {
                try await NativePhotoSaver.saveFile(output, kind: media.kind, filename: filename)
            } else {
                let exported = try keepFile(output, job: job)
                job.outputFiles.append(exported)
            }
            // Only record success after PhotoKit or the file copy actually succeeds.
            job.savedMediaIDs.insert(media.id)
            job.progress = 0.9 + 0.1 * Double(manifest.media.filter { job.savedMediaIDs.contains($0.id) }.count) / Double(manifest.media.count)
            if var latest = read(id), latest.phase == .cancelled || latest.attemptID != job.attemptID {
                latest.savedMediaIDs.insert(media.id)
                if job.destination == .files, let file = job.outputFiles.last, !latest.outputFiles.contains(file) { latest.outputFiles.append(file) }
                try store(latest)
                throw CancellationError()
            }
            try store(job)
            BackgroundExecution.shared.update(jobID: id, progress: job.progress, subtitle: job.destination == .photos ? "Saving to Photos…" : "Preparing files…")
            for stream in streams {
                BackgroundDownloadSession.shared.acknowledge(stream)
                try? FileManager.default.removeItem(at: stream)
            }
            if job.destination == .photos { try? FileManager.default.removeItem(at: output) }
        }
        job = try activeJob(id)
        job.phase = .completed
        job.progress = 1
        job.error = nil
        job.errorCode = nil
        try store(job)
        BackgroundExecution.shared.finish(jobID: id, success: true)
    }

    private func keepFile(_ file: URL, job: DownloadJob) throws -> URL {
        if Bundle.main.bundleURL.pathExtension == "appex" { return file }
        let downloads = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let target = downloads.appendingPathComponent(file.lastPathComponent)
        let temporary = downloads.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: file, to: temporary)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    private func report(_ id: UUID, attempt: UUID, key: String, progress: Double, count: Int) {
        guard var job = read(id), job.attemptID == attempt, job.resolved != nil,
              [.resolving, .downloading].contains(job.phase) else { return }
        fractions[id, default: [:]][key] = progress
        guard fractions[id, default: [:]].count == count else { return }
        job.phase = .downloading
        job.progress = 0.9 * fractions[id, default: [:]].values.reduce(0, +) / Double(max(1, count))
        try? store(job)
        BackgroundExecution.shared.update(jobID: id, progress: job.progress, subtitle: "Downloading…")
    }

    private func activeJob(_ id: UUID) throws -> DownloadJob {
        try Task.checkCancellation()
        guard let job = read(id), !job.phase.isFinished else { throw CancellationError() }
        return job
    }

    private func markFailed(_ id: UUID, error: Error) {
        guard var job = read(id), !job.phase.isFinished else { return }
        job.phase = .failed
        job.error = error.localizedDescription
        job.errorCode = (error as? MediaSaveError)?.code
        try? store(job)
        BackgroundDownloadSession.shared.cancel(jobID: id)
        BackgroundExecution.shared.finish(jobID: id, success: false)
    }

    private func store(_ job: DownloadJob) throws {
        guard let root else { throw failure("The shared download folder is unavailable.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: root.appendingPathComponent(job.id.uuidString + ".json"), options: .atomic)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.append(job) }
        jobs.sort { $0.createdAt > $1.createdAt }
    }

    private func read(_ id: UUID) -> DownloadJob? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(id.uuidString + ".json")) else { return nil }
        return try? JSONDecoder().decode(DownloadJob.self, from: data)
    }

    private func reload() {
        guard let root, let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        jobs = files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            return read(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func attemptDirectory(_ job: DownloadJob) -> URL {
        root!.appendingPathComponent(job.id.uuidString, isDirectory: true).appendingPathComponent(job.attemptID.uuidString, isDirectory: true)
    }

    private func streamFile(_ job: DownloadJob, media: Int, stream: Int) -> URL {
        attemptDirectory(job).appendingPathComponent("media-\(media)-stream-\(stream).part")
    }

    private func nonempty(_ file: URL) -> Bool {
        ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private func ownerIsAlive(_ job: DownloadJob) -> Bool {
        guard let pid = job.ownerProcessID, pid != getpid() else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func safeFilename(_ media: ResolvedMedia) -> String {
        let stem = ((media.filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let safe = stem.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        let suffix = media.container.lowercased()
        let allowed = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "mp4", "mov", "m4v", "mkv", "webm"]
        return String((safe.isEmpty ? "media" : safe).prefix(120)) + "." + (allowed.contains(suffix) ? suffix : "bin")
    }

    private func failure(_ message: String) -> MediaSaveError {
        MediaSaveError(code: "downloadFailed", message: message)
    }
}
