import Foundation
import JavaScriptCore
import Python

/// The Safari API stays stable while the app and Share extension use richer
/// manifests for native background transfers and adaptive video remuxing.
enum EmbeddedVideoResolver {
    static var status: [String: Any] { EmbeddedPython.status }

    static func resolve(postURL: URL) async throws -> [[String: Any]] {
        guard let canonical = NativeMediaRequest.postURL(postURL.absoluteString) else {
            throw MediaSaveError(code: "invalidPost", message: "Provide a supported Instagram or X post URL.")
        }
        let data = try await EmbeddedPython.call(module: "downloader_resolver", arguments: [canonical.absoluteString])
        let envelope = try EmbeddedPython.envelope(data)
        guard let media = envelope["media"] as? [[String: Any]] else {
            throw EmbeddedPython.invalidResult
        }
        return media
    }
}

enum EmbeddedMediaResolver {
    static var status: [String: Any] { EmbeddedPython.status }

    static func resolve(sourceURL: URL, destination: DownloadDestination, allowAV1: Bool = false) async throws -> ResolvedDownload {
        let canonical = try DownloadSource.url(from: sourceURL.absoluteString)
        var arguments = [canonical.absoluteString, destination.rawValue]
        if ["instagram.com", "www.instagram.com"].contains(canonical.host?.lowercased() ?? "") {
            arguments.append(try InstagramSessionStore.resolverJSON())
        } else if allowAV1 && HEVCConversionSettings.isYouTube(canonical) {
            arguments.append("[]")
            arguments.append("true")
        }
        let data = try await EmbeddedPython.call(module: "app_resolver", arguments: arguments)
        _ = try EmbeddedPython.envelope(data)
        struct Envelope: Decodable { var download: ResolvedDownload }
        let manifest: ResolvedDownload
        do { manifest = try JSONDecoder().decode(Envelope.self, from: data).download }
        catch { throw EmbeddedPython.invalidResult }
        guard sourceIdentity(manifest.sourceURL) == sourceIdentity(canonical), !manifest.media.isEmpty, manifest.media.count <= 20,
              manifest.title.count <= 500, Set(manifest.media.map(\.id)).count == manifest.media.count else {
            throw EmbeddedPython.invalidResult
        }
        if let storyID = NativeMediaRequest.instagramStoryID(canonical) {
            guard manifest.media.count == 1, manifest.media.first?.id == storyID else { throw EmbeddedPython.invalidResult }
        }
        for item in manifest.media {
            guard !item.id.isEmpty, item.id.count <= 100, !item.filename.isEmpty,
                  item.filename == URL(fileURLWithPath: item.filename).lastPathComponent,
                  item.filename.count <= 160, item.streams.count >= 1, item.streams.count <= 2 else {
                throw EmbeddedPython.invalidResult
            }
            for stream in item.streams {
                guard DownloadURLPolicy.allows(stream.url), stream.headers.count <= 5,
                      stream.expectedBytes == nil || stream.expectedBytes! > 0 else {
                    throw EmbeddedPython.invalidResult
                }
                _ = try DownloadURLPolicy.request(for: stream)
            }
            if item.streams.count == 2 {
                guard item.kind == .video, item.streams[0].role == .video, item.streams[1].role == .audio else {
                    throw EmbeddedPython.invalidResult
                }
            }
        }
        return manifest
    }

    private static func sourceIdentity(_ url: URL) -> String? {
        guard let validated = try? DownloadSource.url(from: url.absoluteString),
              var components = URLComponents(url: validated, resolvingAgainstBaseURL: false) else { return nil }
        var host = components.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        components.host = host
        components.port = nil
        components.path = "/" + components.path.split(separator: "/").joined(separator: "/")
        return components.string
    }
}

/// A single serial queue owns CPython calls, including JavaScriptCore callbacks.
/// Python handles extraction only; native Swift owns all media transfer/saving.
private enum EmbeddedPython {
    private static let queue = DispatchQueue(label: "Downloader.embedded-python", qos: .userInitiated)
    private static var functions: [String: UnsafeMutablePointer<PyObject>] = [:]
    private static var initialized = false
    private static let failureLock = NSLock()
    private static var initializationFailure: MediaSaveError?

    static let invalidResult = MediaSaveError(code: "invalidMediaResult", message: "The built-in media engine returned invalid information.")

    static var status: [String: Any] {
        var failure = cachedFailure
        if failure == nil {
            do { _ = try runtimePaths() }
            catch let error as MediaSaveError { failure = error }
            catch { failure = invalidResult }
        }
        let available = failure == nil
        var response: [String: Any] = ["available": available, "engine": "embedded-yt-dlp", "javascriptEngine": "JavaScriptCore"]
        if let resources = Bundle.main.resourceURL,
           let data = try? Data(contentsOf: resources.appendingPathComponent("python-runtime.json")),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            response["version"] = metadata["ytDlpVersion"]
            response["pythonVersion"] = metadata["pythonVersion"]
            response["galleryDlVersion"] = metadata["galleryDlVersion"]
        }
        if let failure {
            response["error"] = failure.message
            response["code"] = failure.code
        }
        return response
    }

    private static var cachedFailure: MediaSaveError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return initializationFailure
    }

    static func call(module: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try callOnQueue(module: module, values: arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func envelope(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalidResult }
        guard result["ok"] as? Bool == true else {
            throw MediaSaveError(code: result["code"] as? String ?? "mediaResolutionFailed",
                                 message: result["error"] as? String ?? "Media extraction failed.")
        }
        return result
    }

    private static func runtimePaths() throws -> EmbeddedPythonResources {
        try EmbeddedPythonResources.locate(resources: Bundle.main.resourceURL, executable: Bundle.main.executableURL)
    }

    private static func callOnQueue(module name: String, values: [String]) throws -> Data {
        try initializeIfNeeded()
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
        let function: UnsafeMutablePointer<PyObject>
        if let cached = functions[name] { function = cached }
        else {
            guard let module = PyImport_ImportModule(name) else { throw pythonError() }
            defer { Py_DecRef(module) }
            guard let callable = PyObject_GetAttrString(module, "resolve_json"), PyCallable_Check(callable) != 0 else {
                throw pythonError()
            }
            functions[name] = callable
            function = callable
        }
        guard let arguments = PyTuple_New(values.count) else { throw pythonError() }
        defer { Py_DecRef(arguments) }
        for (index, value) in values.enumerated() {
            guard let argument = PyUnicode_FromString(value), PyTuple_SetItem(arguments, index, argument) == 0 else {
                throw pythonError()
            }
        }
        guard let result = PyObject_CallObject(function, arguments) else { throw pythonError() }
        defer { Py_DecRef(result) }
        var size = 0
        guard let value = PyUnicode_AsUTF8AndSize(result, &size), size > 0, size <= 4 * 1024 * 1024 else {
            throw invalidResult
        }
        return Data(bytes: value, count: size)
    }

    private static func initializeIfNeeded() throws {
        if let failure = cachedFailure { throw failure }
        if initialized { return }
        let paths = try runtimePaths()
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
                // AppleFrameworkLoader resolves .fwork paths from this actual
                // app/extension executable into the containing app Frameworks.
                try check(PyConfig_SetBytesString(pointer, &pointer.pointee.executable, paths.executable.path))
                try check(PyConfig_SetBytesString(pointer, &pointer.pointee.program_name, paths.executable.path))
                for path in [paths.home.appendingPathComponent("lib/python3.13"),
                             paths.home.appendingPathComponent("lib/python3.13/lib-dynload"), paths.packages, paths.script] {
                    guard let wide = Py_DecodeLocale(path.path, nil) else {
                        throw MediaSaveError(code: "videoEngineUnavailable", message: "The media engine could not read its bundled resources.")
                    }
                    defer { PyMem_RawFree(wide) }
                    try check(PyWideStringList_Append(&pointer.pointee.module_search_paths, wide))
                }
            }
            try check(Py_InitializeFromConfig(&configuration))
            try installJavaScriptBridge()
            // Import the Safari bootstrap now so a broken runtime is reflected
            // in status and repeated requests retain its actionable failure.
            guard let module = PyImport_ImportModule("downloader_resolver") else { throw pythonError() }
            Py_DecRef(module)
            initialized = true
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

    private static func installJavaScriptBridge() throws {
        guard let module = PyModule_New("downloader_native") else { throw pythonError() }
        defer { Py_DecRef(module) }
        // CPython retains this method definition for the interpreter lifetime.
        let method = UnsafeMutablePointer<PyMethodDef>.allocate(capacity: 1)
        method.initialize(to: PyMethodDef(ml_name: UnsafePointer(strdup("evaluate_javascript")),
                                         ml_meth: evaluateJavaScript, ml_flags: METH_O, ml_doc: nil))
        guard let function = PyCFunction_NewEx(method, nil, nil) else { throw pythonError() }
        guard PyModule_AddObject(module, "evaluate_javascript", function) == 0,
              PyDict_SetItemString(PyImport_GetModuleDict(), "downloader_native", module) == 0 else {
            throw pythonError()
        }
    }

    private static let evaluateJavaScript: @convention(c) (UnsafeMutablePointer<PyObject>?, UnsafeMutablePointer<PyObject>?) -> UnsafeMutablePointer<PyObject>? = { _, argument in
        var size = 0
        guard let argument, let bytes = PyUnicode_AsUTF8AndSize(argument, &size), size > 0, size <= 12 * 1024 * 1024 else {
            PyErr_SetString(PyExc_RuntimeError, "Invalid JavaScript challenge input.")
            return nil
        }
        return autoreleasepool {
            guard let context = JSContext() else {
                PyErr_SetString(PyExc_RuntimeError, "The built-in JavaScript engine could not start.")
                return nil
            }
            // The isolated context receives no native network, filesystem, or
            // process objects. EJS emits its single JSON response to console.
            context.evaluateScript("var __downloaderResult = null; var console = {log: function(value) { __downloaderResult = String(value); }};")
            context.evaluateScript(String(cString: bytes))
            guard context.exception == nil,
                  let output = context.objectForKeyedSubscript("__downloaderResult"), !output.isNull,
                  let text = output.toString(), text.utf8.count <= 4 * 1024 * 1024 else {
                PyErr_SetString(PyExc_RuntimeError, "The built-in JavaScript challenge failed.")
                return nil
            }
            return PyUnicode_FromString(text)
        }
    }

    private static func check(_ result: PyStatus) throws {
        if PyStatus_Exception(result) != 0 {
            throw MediaSaveError(code: "videoEngineUnavailable", message: "The built-in media engine could not start. Restart Downloader or Safari, then try again.")
        }
    }

    private static func pythonError() -> MediaSaveError {
        PyErr_Clear()
        return MediaSaveError(code: "videoEngineUnavailable", message: "The built-in media engine could not run. Restart Downloader or Safari, then try again.")
    }
}
