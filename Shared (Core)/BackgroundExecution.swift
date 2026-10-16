import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// CPU work can continue on iOS 26 when the system accepts a user-initiated task.
/// Background URLSession separately owns durable HTTP transfers on earlier systems.
@MainActor
final class BackgroundExecution {
    static let shared = BackgroundExecution()
    private static let prefix = "wang.xiaolin.Downloader.continued."
    private static let persistenceKey = "continuedProcessingRequests"
    private var current: [UUID: String] = [:]
    private var registered = Set<String>()
    private var checking = Set<UUID>()
    private var submitting = Set<String>()
    private var pending = Set<String>()
    private var cancellations: [UUID: () -> Void] = [:]
    private var tasks: [String: AnyObject] = [:]
    private var finished: [String: Bool] = [:]
    private var lastProgress: [UUID: (Double?, String)] = [:]
    private(set) var submissionErrors: [UUID: String] = [:]
    var recoveryHandler: ((UUID) async -> Void)?

    private var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    private var defaults: UserDefaults? { UserDefaults(suiteName: BackgroundDownloadSession.appGroup) }

    /// Call during host application launch. Share extensions never own launch handlers.
    func register() {
        guard !isExtension else { return }
        #if os(iOS)
        if #available(iOS 26.0, *) {
            let saved = defaults?.dictionary(forKey: Self.persistenceKey) as? [String: String] ?? [:]
            for (key, identifier) in saved {
                guard let jobID = UUID(uuidString: key), valid(identifier, for: jobID) else { continue }
                current[jobID] = identifier
                registerRequest(identifier, jobID: jobID)
            }
            defaults?.removeObject(forKey: "continuedProcessingJobs")
        }
        #endif
    }

    func begin(jobID: UUID, title: String, cancel: @escaping () -> Void) {
        cancellations[jobID] = cancel
        submissionErrors.removeValue(forKey: jobID)
        lastProgress.removeValue(forKey: jobID)
        guard !isExtension else { return }
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if let identifier = current[jobID] {
                // A host relaunch can attach the cancellation closure to the same
                // pending request. Active and in-flight requests must not be duplicated.
                if tasks[identifier] != nil || submitting.contains(identifier) || pending.contains(identifier) { return }
                guard checking.insert(jobID).inserted else { return }
                Task {
                    defer { checking.remove(jobID) }
                    let identifiers = await pendingIdentifiers()
                    guard current[jobID] == identifier else { return }
                    if tasks[identifier] != nil || identifiers.contains(identifier) {
                        pending.insert(identifier)
                        return
                    }
                    // User termination may have removed a persisted request. A retry
                    // gets a new token, so a late old callback cannot own this attempt.
                    createRequest(jobID: jobID, title: title)
                }
            } else {
                createRequest(jobID: jobID, title: title)
            }
        }
        #endif
    }

    func update(jobID: UUID, progress: Double?, subtitle: String) {
        lastProgress[jobID] = (progress, subtitle)
        #if os(iOS)
        if #available(iOS 26.0, *), let identifier = current[jobID],
           let task = tasks[identifier] as? BGContinuedProcessingTask {
            // Do not fabricate progress while Python is resolving an unknown-size job.
            if let progress {
                task.progress.totalUnitCount = 10_000
                task.progress.completedUnitCount = Int64(min(1, max(0, progress)) * 10_000)
            }
            task.updateTitle(task.title, subtitle: subtitle)
        }
        #endif
    }

    func finish(jobID: UUID, success: Bool) {
        cancellations.removeValue(forKey: jobID)
        lastProgress.removeValue(forKey: jobID)
        // The share process cannot remove or complete a host-owned system task.
        guard !isExtension else { return }
        #if os(iOS)
        if #available(iOS 26.0, *), let identifier = current.removeValue(forKey: jobID) {
            finished[identifier] = success
            pending.remove(identifier)
            persist()
            if let task = tasks.removeValue(forKey: identifier) as? BGContinuedProcessingTask {
                task.expirationHandler = nil
                if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
                task.setTaskCompleted(success: success)
                finished.removeValue(forKey: identifier)
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
        }
        #endif
    }

    private func valid(_ identifier: String, for jobID: UUID) -> Bool {
        let start = Self.prefix + jobID.uuidString + "."
        guard identifier.hasPrefix(start) else { return false }
        return UUID(uuidString: String(identifier.dropFirst(start.count))) != nil
    }

    private func persist() {
        defaults?.set(Dictionary(uniqueKeysWithValues: current.map { ($0.key.uuidString, $0.value) }),
                      forKey: Self.persistenceKey)
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func pendingIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
    }

    @available(iOS 26.0, *)
    private func createRequest(jobID: UUID, title: String) {
        let identifier = Self.prefix + jobID.uuidString + "." + UUID().uuidString
        current[jobID] = identifier
        persist()
        registerRequest(identifier, jobID: jobID)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title,
                                                      subtitle: "Preparing download…")
        // The foreground pipeline already owns the job. Queuing another copy can
        // outlive that job; unavailable CPU continuation leaves HTTP transfers intact.
        request.strategy = .fail
        submitting.insert(identifier)
        Task {
            defer { submitting.remove(identifier) }
            do {
                if #available(iOS 27.0, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
                if current[jobID] == identifier && tasks[identifier] == nil {
                    pending.insert(identifier)
                } else if current[jobID] != identifier {
                    // A very short job may finish while the async submit is in flight.
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                }
            } catch {
                guard current[jobID] == identifier else { return }
                submissionErrors[jobID] = error.localizedDescription
                current.removeValue(forKey: jobID)
                pending.remove(identifier)
                persist()
            }
        }
    }

    @available(iOS 26.0, *)
    private func registerRequest(_ identifier: String, jobID: UUID) {
        guard registered.insert(identifier).inserted else { return }
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                if let success = self.finished.removeValue(forKey: identifier) {
                    continued.setTaskCompleted(success: success)
                    return
                }
                guard self.current[jobID] == identifier else {
                    // This request belongs to an old attempt. Ending it must never
                    // cancel transfers or attach progress to the replacement token.
                    continued.setTaskCompleted(success: false)
                    return
                }
                self.pending.remove(identifier)
                self.tasks[identifier] = continued
                continued.progress.totalUnitCount = 10_000
                continued.expirationHandler = {
                    Task { @MainActor in
                        guard self.current[jobID] == identifier else { return }
                        self.cancellations[jobID]?()
                        BackgroundDownloadSession.shared.cancel(jobID: jobID)
                        self.finish(jobID: jobID, success: false)
                    }
                }
                if let (progress, subtitle) = self.lastProgress[jobID] {
                    self.update(jobID: jobID, progress: progress, subtitle: subtitle)
                }
                await self.recoveryHandler?(jobID)
            }
        }
        if !accepted {
            submissionErrors[jobID] = "Background processing could not be enabled for this download."
        }
    }
    #endif
}
