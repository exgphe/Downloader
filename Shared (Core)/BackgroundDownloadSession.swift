import Foundation

/// The system owns these HTTP transfers after the share extension or app is suspended.
/// Resolution and media export still need an executing process.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloadSession()
    static let appGroup = "group.wang.xiaolin.Downloader"
    private static let identifierPrefix = "wang.xiaolin.Downloader.transfer."

    struct CompletedTransfer: Sendable {
        let jobID: UUID
        let destination: URL
        let sourceURL: URL
        let responseURL: URL?
        let error: String?
    }

    private struct Record: Codable {
        let id: UUID
        let jobID: UUID
        let sessionIdentifier: String
        var taskIdentifier: Int
        let sourceURL: URL
        let destination: URL
        var state: String
        var responseURL: URL?
        var error: String?
        var cancellationRequested: Bool?
    }

    private struct Waiting {
        let continuation: CheckedContinuation<URL, Error>
        let progress: (Double) -> Void
    }

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var waiting: [UUID: Waiting] = [:]
    private var reportedProgress: [UUID: Double] = [:]
    private var eventCompletions: [String: () -> Void] = [:]
    private let injectedContainerURL: URL?
    private let configurationProvider: ((String) -> URLSessionConfiguration)?
    /// The containing app installs this before recreating an extension-owned session.
    var recoveryHandler: (() async -> Void)?

    init(containerURL: URL? = nil, configurationProvider: ((String) -> URLSessionConfiguration)? = nil) {
        injectedContainerURL = containerURL
        self.configurationProvider = configurationProvider
        super.init()
    }

    private var containerURL: URL? {
        injectedContainerURL ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
    }

    private var recordDirectory: URL? {
        containerURL.flatMap(DownloadStoragePolicy.canonicalFileURL)?
            .appendingPathComponent("BackgroundTransfers", isDirectory: true)
    }

    private var currentIdentifier: String {
        Self.identifierPrefix + (Bundle.main.bundleIdentifier ?? "app")
    }

    func download(request: URLRequest, destination: URL, jobID: UUID,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        guard let source = request.url, DownloadURLPolicy.allows(source) else {
            throw transferError("The media URL is not an approved HTTPS download URL.")
        }
        guard let directory = recordDirectory else {
            throw transferError("The download storage is unavailable. Open Downloader and try again.")
        }
        guard let approvedDestination = DownloadStoragePolicy.destination(destination, within: directory.deletingLastPathComponent()) else {
            throw transferError("The media could not be saved to the download folder.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transferID = UUID()
        var safeRequest = request
        // URLSession background transfers follow redirects in the system process. Never
        // put login cookies or bearer credentials on a request that could be redirected.
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        safeRequest.httpShouldHandleCookies = false
        let session = session(for: currentIdentifier)
        let task = session.downloadTask(with: safeRequest)
        task.taskDescription = transferID.uuidString
        let record = Record(id: transferID, jobID: jobID, sessionIdentifier: currentIdentifier,
                            taskIdentifier: task.taskIdentifier, sourceURL: source,
                            destination: approvedDestination, state: "running")
        try save(record)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                waiting[transferID] = Waiting(continuation: continuation, progress: progress)
                lock.unlock()
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                    progress(0) // The persisted transfer is now owned by URLSession.
                }
            }
        }, onCancel: { task.cancel() })
    }

    /// Do not recreate an extension session at ordinary app launch: only one process
    /// may own it at a time. UIKit supplies the identifier when ownership transfers.
    func reattachOwnedSession() {
        _ = session(for: currentIdentifier)
    }

    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(Self.identifierPrefix) else {
            completionHandler()
            return
        }
        lock.lock()
        eventCompletions[identifier] = completionHandler
        lock.unlock()
        _ = session(for: identifier)
    }

    func completedTransfers() async -> [CompletedTransfer] {
        records().filter { ["delivered", "failed"].contains($0.state) }.map {
            CompletedTransfer(jobID: $0.jobID, destination: $0.destination,
                              sourceURL: $0.sourceURL, responseURL: $0.responseURL, error: $0.error)
        }
    }

    func acknowledge(_ destination: URL) {
        for record in records() where DownloadStoragePolicy.sameFile(record.destination, destination) && ["delivered", "failed"].contains(record.state) {
            if let file = recordURL(record.id) { try? FileManager.default.removeItem(at: file) }
        }
    }

    func cancel(jobID: UUID) {
        let pending = records().filter { $0.jobID == jobID && $0.state == "running" }
        for var record in pending {
            record.cancellationRequested = true
            record.error = "Download cancelled."
            try? save(record)
            lock.lock()
            let owner = sessions[record.sessionIdentifier]
            lock.unlock()
            // Creating the other process's session while its extension is alive is
            // forbidden. A persisted cancellation is picked up by its next callback.
            guard let owner else { continue }
            owner.getAllTasks { tasks in
                tasks.filter { $0.taskDescription == record.id.uuidString }.forEach { $0.cancel() }
            }
        }
    }

    private func session(for identifier: String) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[identifier] { return existing }
        let configuration = configurationProvider?(identifier) ?? URLSessionConfiguration.background(withIdentifier: identifier)
        if configuration.identifier != nil {
            configuration.sharedContainerIdentifier = Self.appGroup
            configuration.sessionSendsLaunchEvents = true
        }
        configuration.isDiscretionary = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.timeoutIntervalForRequest = 90
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        sessions[identifier] = session
        return session
    }

    private func recordURL(_ id: UUID) -> URL? {
        recordDirectory?.appendingPathComponent(id.uuidString + ".json")
    }

    private func save(_ record: Record) throws {
        guard let file = recordURL(record.id) else { throw transferError("The download storage is unavailable.") }
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }

    private func read(_ task: URLSessionTask) -> Record? {
        guard let description = task.taskDescription, let id = UUID(uuidString: description),
              let file = recordURL(id), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func records() -> [Record] {
        guard let directory = recordDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let record = read(downloadTask) else { return }
        if record.cancellationRequested == true {
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        lock.lock()
        let last = reportedProgress[record.id] ?? -1
        let callback = fraction - last >= 0.002 || fraction == 1 ? waiting[record.id]?.progress : nil
        if callback != nil { reportedProgress[record.id] = fraction }
        lock.unlock()
        callback?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard var record = read(downloadTask) else { return }
        do {
            if record.cancellationRequested == true { throw CancellationError() }
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let finalURL = response.url,
                  DownloadURLPolicy.allows(finalURL) else {
                throw transferError("The server returned an unsuccessful or unapproved media response.")
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else {
                throw transferError("The downloaded media is empty.")
            }
            guard let container = containerURL,
                  let destination = DownloadStoragePolicy.destination(record.destination, within: container) else {
                throw transferError("The media could not be saved to the download folder.")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A recovered completion can arrive after the same file was already persisted.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            record.responseURL = finalURL
            record.state = "downloaded"
            record.error = nil
        } catch {
            // Keep the record until didCompleteWithError has delivered the owning
            // process's continuation. Another process must not acknowledge it yet.
            record.state = "downloadError"
            record.error = error.localizedDescription
        }
        try? save(record)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard var record = read(task) else { return }
        if let error {
            record.state = "failed"
            record.error = record.error ?? error.localizedDescription
        } else if record.state == "downloaded" {
            record.state = "delivered"
        } else if record.state == "downloadError" {
            record.state = "failed"
        } else if record.state == "running" {
            record.state = "failed"
            record.error = "The media transfer ended without a downloaded file."
        }
        try? save(record)
        lock.lock()
        let item = waiting.removeValue(forKey: record.id)
        reportedProgress.removeValue(forKey: record.id)
        let recovery = recoveryHandler
        lock.unlock()
        if let item {
            if record.state == "delivered" {
                item.progress(1)
                item.continuation.resume(returning: record.destination)
            } else {
                item.continuation.resume(throwing: error ?? transferError(record.error ?? "Download failed."))
            }
        } else if let recovery {
            Task { await recovery() }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        lock.lock()
        let completion = eventCompletions.removeValue(forKey: identifier)
        let recovery = recoveryHandler
        lock.unlock()
        Task {
            // UIKit's completion must run after the host has persisted the Photos / Files result.
            await recovery?()
            if let completion { await MainActor.run { completion() } }
        }
    }

    private func transferError(_ message: String) -> NSError {
        NSError(domain: "Downloader.BackgroundTransfer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
