import Foundation
import Darwin

/// Foundation can standardize an existing /private/var directory differently
/// from a not-yet-created child. Resolve the existing ancestor once, then append
/// missing components without changing the spelling based on file existence.
enum DownloadStoragePolicy {
    static func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.utf8.contains(0), !url.pathComponents.contains("."),
              !url.pathComponents.contains("..") else { return nil }
        var ancestor = url
        var missing: [String] = []
        while true {
            var metadata = stat()
            if lstat(ancestor.path, &metadata) == 0 {
                // An existing but broken symlink must not be treated as a
                // missing directory and later followed outside the container.
                guard let resolved = realpath(ancestor.path, nil) else { return nil }
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved))
                if !missing.isEmpty {
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: result.path, isDirectory: &directory),
                          directory.boolValue else { return nil }
                }
                for component in missing.reversed() { result.appendPathComponent(component) }
                return result
            }
            guard errno == ENOENT, ancestor.path != "/", !ancestor.lastPathComponent.isEmpty else { return nil }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }

    static func destination(_ url: URL, within container: URL) -> URL? {
        guard let root = canonicalFileURL(container), let file = canonicalFileURL(url) else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { return nil }
        let rootComponents = root.pathComponents
        let fileComponents = file.pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else { return nil }
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), directory.boolValue { return nil }
        return file
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = canonicalFileURL(lhs), let right = canonicalFileURL(rhs) else { return false }
        return left.pathComponents == right.pathComponents
    }

    /// Transfer errors can arrive before an attempt directory has been created.
    /// Match these records by location without requiring that directory to exist.
    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        guard let root = canonicalFileURL(directory), let file = canonicalFileURL(url) else { return false }
        let rootComponents = root.pathComponents
        let fileComponents = file.pathComponents
        return fileComponents.count > rootComponents.count &&
            fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}
