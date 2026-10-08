import Foundation
import Python

/// A single interpreter and serial queue keep Python objects/GIL ownership out
/// of Swift concurrency. yt-dlp extracts metadata only; Swift downloads media.
enum EmbeddedVideoResolver {
    private static let queue = DispatchQueue(label: "Downloader.embedded-video-resolver", qos: .userInitiated)
    private static var resolver: UnsafeMutablePointer<PyObject>?
    private static let failureLock = NSLock()
    private static var initializationFailure: MediaSaveError?

    static var status: [String: Any] {
        let failure = cachedFailure
        let available = runtimePaths != nil && failure == nil
        var response: [String: Any] = ["available": available, "engine": "embedded-yt-dlp"]
        if let resources = Bundle.main.resourceURL,
           let data = try? Data(contentsOf: resources.appendingPathComponent("python-runtime.json")),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            response["version"] = metadata["ytDlpVersion"]
            response["pythonVersion"] = metadata["pythonVersion"]
        }
        if let failure {
            response["error"] = failure.message
            response["code"] = failure.code
        } else if !available {
            response["error"] = "The built-in video engine is unavailable. Update or reinstall Downloader, then try again."
        }
        return response
    }

    private static var cachedFailure: MediaSaveError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return initializationFailure
    }

    static func resolve(postURL: URL) async throws -> [[String: Any]] {
        // Repeat validation even when invoked outside the Safari handler.
        guard let canonical = NativeMediaRequest.postURL(postURL.absoluteString) else {
            throw MediaSaveError(code: "invalidPost", message: "Provide a supported Instagram or X post URL.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try resolveOnQueue(canonical.absoluteString)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static var runtimePaths: (home: URL, packages: URL, script: URL)? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let home = resources.appendingPathComponent("python", isDirectory: true)
        let packages = resources.appendingPathComponent("python-packages", isDirectory: true)
        let script = resources.appendingPathComponent("Python", isDirectory: true)
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("lib/python3.13/encodings/__init__.py").path),
              FileManager.default.fileExists(atPath: packages.appendingPathComponent("yt_dlp/__init__.py").path),
              FileManager.default.fileExists(atPath: script.appendingPathComponent("downloader_resolver.py").path) else { return nil }
        return (home, packages, script)
    }

    private static func resolveOnQueue(_ address: String) throws -> [[String: Any]] {
        try initializeIfNeeded()
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
        guard let function = resolver, let argument = PyUnicode_FromString(address) else {
            throw pythonError()
        }
        defer { Py_DecRef(argument) }
        guard let arguments = PyTuple_New(1) else { throw pythonError() }
        defer { Py_DecRef(arguments) }
        // PyTuple_SetItem steals this reference; keep the original for defer.
        Py_IncRef(argument)
        guard PyTuple_SetItem(arguments, 0, argument) == 0,
              let result = PyObject_CallObject(function, arguments) else { throw pythonError() }
        defer { Py_DecRef(result) }
        guard let value = PyUnicode_AsUTF8AndSize(result, nil),
              let data = String(cString: value).data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSaveError(code: "invalidVideoResult", message: "The bundled video engine returned invalid information.")
        }
        guard envelope["ok"] as? Bool == true else {
            throw MediaSaveError(code: envelope["code"] as? String ?? "videoResolutionFailed",
                                 message: envelope["error"] as? String ?? "Video extraction failed.")
        }
        guard let media = envelope["media"] as? [[String: Any]] else {
            throw MediaSaveError(code: "invalidVideoResult", message: "The bundled video engine returned invalid information.")
        }
        return media
    }

    private static func initializeIfNeeded() throws {
        if let failure = cachedFailure { throw failure }
        if resolver != nil { return }
        guard let paths = runtimePaths, let executable = Bundle.main.executableURL else {
            throw MediaSaveError(code: "videoEngineUnavailable", message: "The built-in video engine is unavailable. Update or reinstall Downloader, then try again.")
        }
        do {
            var preconfiguration = PyPreConfig()
            PyPreConfig_InitIsolatedConfig(&preconfiguration)
            preconfiguration.utf8_mode = 1
            try check(Py_PreInitialize(&preconfiguration))
            var configuration = PyConfig()
            PyConfig_InitIsolatedConfig(&configuration)
            defer { PyConfig_Clear(&configuration) }
            configuration.install_signal_handlers = 0
            configuration.write_bytecode = 0
            configuration.buffered_stdio = 0
            configuration.site_import = 0
            configuration.parse_argv = 0
            configuration.module_search_paths_set = 1
            try withUnsafeMutablePointer(to: &configuration) { pointer in
                try check(PyConfig_SetBytesString(pointer, &pointer.pointee.home, paths.home.path))
                // AppleFrameworkLoader resolves .fwork markers relative to
                // sys.executable; this must be the real extension executable.
                try check(PyConfig_SetBytesString(pointer, &pointer.pointee.executable, executable.path))
                try check(PyConfig_SetBytesString(pointer, &pointer.pointee.program_name, executable.path))
                for path in [paths.home.appendingPathComponent("lib/python3.13"),
                             paths.home.appendingPathComponent("lib/python3.13/lib-dynload"),
                             paths.packages, paths.script] {
                    guard let wide = Py_DecodeLocale(path.path, nil) else {
                        throw MediaSaveError(code: "videoEngineUnavailable", message: "The video engine could not read its bundled resources.")
                    }
                    defer { PyMem_RawFree(wide) }
                    try check(PyWideStringList_Append(&pointer.pointee.module_search_paths, wide))
                }
            }
            try check(Py_InitializeFromConfig(&configuration))
            guard let module = PyImport_ImportModule("downloader_resolver") else { throw pythonError() }
            defer { Py_DecRef(module) }
            guard let function = PyObject_GetAttrString(module, "resolve_json"), PyCallable_Check(function) != 0 else {
                throw pythonError()
            }
            resolver = function
            // The initialize call acquires the GIL. All later operations use
            // PyGILState_Ensure, even if this queue executes on another thread.
            _ = PyEval_SaveThread()
        } catch {
            if Py_IsInitialized() != 0 { _ = PyEval_SaveThread() }
            let failure = error as? MediaSaveError ?? MediaSaveError(code: "videoEngineUnavailable", message: error.localizedDescription)
            failureLock.lock()
            initializationFailure = failure
            failureLock.unlock()
            throw failure
        }
    }

    private static func check(_ result: PyStatus) throws {
        if PyStatus_Exception(result) != 0 {
            throw MediaSaveError(code: "videoEngineUnavailable", message: "The built-in video engine could not start. Restart Safari or update Downloader, then try again.")
        }
    }

    private static func pythonError() -> MediaSaveError {
        // Clear errors without writing tracebacks or authenticated URLs to logs.
        PyErr_Clear()
        return MediaSaveError(code: "videoEngineUnavailable", message: "The built-in video engine could not run. Restart Safari or update Downloader, then try again.")
    }
}
