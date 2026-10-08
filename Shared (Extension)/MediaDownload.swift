import Foundation

struct DownloadedMedia {
    let directory: URL
    let file: URL
    let mimeType: String?
}

/// Downloads stream to disk, with a size limit and a wall-clock deadline.
/// A serial delegate queue protects mutable state and redirect decisions.
final class MediaDownload: NSObject, URLSessionDownloadDelegate {
    static let maximumBytes: Int64 = 512 * 1_024 * 1_024
    private let item: NativeMediaRequest
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var completion: ((Result<DownloadedMedia, Error>) -> Void)?
    private var result: DownloadedMedia?
    private var failure: Error?
    private var deadline: DispatchWorkItem?

    private init(item: NativeMediaRequest) {
        self.item = item
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Downloader.MediaDownload"
        delegateQueue = queue
    }

    static func download(_ item: NativeMediaRequest) async throws -> DownloadedMedia {
        try await withCheckedThrowingContinuation { continuation in
            let operation = MediaDownload(item: item)
            operation.start { continuation.resume(with: $0) }
        }
    }

    private func start(completion: @escaping (Result<DownloadedMedia, Error>) -> Void) {
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.downloadTask(with: item.downloadRequest())
        self.task = task
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.delegateQueue.addOperation {
                guard self.completion != nil else { return }
                self.failure = MediaSaveError(code: "downloadTimeout", message: "The media download exceeded 90 seconds. Try again on a faster connection.")
                self.task?.cancel()
            }
        }
        self.deadline = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: deadline)
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, item.policy.allowsRedirect(from: item.url, to: url) else {
            failure = MediaSaveError(code: "unsafeRedirect", message: "The media server redirected to an unsupported location.")
            completionHandler(nil)
            task.cancel()
            return
        }
        var safeRequest = request
        // Never preserve URLSession's copied Authorization header on a redirect.
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        if item.policy.isResolverURL(url), let token = item.policy.service?.token, !token.isEmpty {
            safeRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        completionHandler(safeRequest)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumBytes || totalBytesExpectedToWrite > Self.maximumBytes {
            failure = MediaSaveError(code: "mediaTooLarge", message: "This media exceeds the 512 MB download limit.")
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard failure == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw MediaSaveError(code: "downloadFailed", message: "The media server returned an invalid response.")
            }
            guard (200..<300).contains(response.statusCode) else {
                let message = [401, 403].contains(response.statusCode)
                    ? "The media URL is expired or requires authentication. Refresh the post and try again."
                    : "The media server returned HTTP \(response.statusCode)."
                throw MediaSaveError(code: "downloadHTTPError", message: message)
            }
            let bytes = (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard bytes > 0, bytes <= Self.maximumBytes else {
                throw MediaSaveError(code: bytes == 0 ? "emptyMedia" : "mediaTooLarge",
                                     message: bytes == 0 ? "The downloaded media is empty." : "This media exceeds the 512 MB download limit.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Downloader-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("media.download")
            do { try FileManager.default.moveItem(at: location, to: file) }
            catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            result = DownloadedMedia(directory: directory, file: file, mimeType: response.mimeType)
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        deadline?.cancel()
        deadline = nil
        let callback = completion
        completion = nil
        if let error = failure ?? error {
            if let result { try? FileManager.default.removeItem(at: result.directory) }
            let nativeError = error as NSError
            if failure == nil && nativeError.domain == NSURLErrorDomain && nativeError.code == NSURLErrorTimedOut {
                callback?(.failure(MediaSaveError(code: "downloadTimeout", message: "The media download timed out. Try again on a faster connection.")))
            } else if failure != nil { callback?(.failure(error)) }
            else { callback?(.failure(MediaSaveError(code: "downloadFailed", message: error.localizedDescription))) }
        } else if let result {
            callback?(.success(result))
        } else {
            callback?(.failure(MediaSaveError(code: "downloadFailed", message: "The media download did not produce a file.")))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        self.task = nil
    }
}
