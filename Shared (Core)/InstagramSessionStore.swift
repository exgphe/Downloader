import Foundation
import Security

struct InstagramSessionStatus: Sendable {
    var hasSession: Bool
    var importedAt: Date? = nil
    var expiresAt: Date? = nil
    var errorMessage: String? = nil

    var nativeMessage: [String: Any] {
        var result: [String: Any] = ["hasSession": hasSession]
        if let importedAt { result["importedAt"] = importedAt.timeIntervalSince1970 }
        if let expiresAt { result["expiresAt"] = expiresAt.timeIntervalSince1970 }
        if let errorMessage { result["error"] = errorMessage }
        return result
    }
}

/// This schema is shared with the popup and the instance-local gallery-dl jar.
/// Neither status responses nor persisted download jobs contain these values.
struct InstagramSessionCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Double?
}

enum InstagramSessionValidation {
    static let maximumBytes = 65_536
    private static let names: Set<String> = ["sessionid", "csrftoken", "ds_user_id", "rur", "mid", "ig_did"]
    private static let domains: Set<String> = ["instagram.com", ".instagram.com", "www.instagram.com", ".www.instagram.com"]

    static var invalid: MediaSaveError {
        MediaSaveError(code: "invalidInstagramSession", message: "The Instagram session could not be imported. Sign in to Instagram in Safari and sync again from the Downloader extension.")
    }

    static var missing: MediaSaveError {
        MediaSaveError(code: "instagramSessionMissing", message: "No usable Instagram session was found. Sign in at instagram.com in Safari, then sync from the Downloader extension. Reading the login cookie requires Safari 18 or later.")
    }

    static func decode(_ payload: [Any], now: Date = Date()) throws -> [InstagramSessionCookie] {
        guard payload.count <= 24, JSONSerialization.isValidJSONObject(payload) else { throw invalid }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= maximumBytes else { throw invalid }
        let cookies: [InstagramSessionCookie]
        do { cookies = try JSONDecoder().decode([InstagramSessionCookie].self, from: data) }
        catch { throw invalid }
        return try validate(cookies, now: now, requireSession: true)
    }

    static func validate(_ input: [InstagramSessionCookie], now: Date, requireSession: Bool) throws -> [InstagramSessionCookie] {
        guard input.count <= 24 else { throw invalid }
        var result: [InstagramSessionCookie] = []
        var seen: [String: InstagramSessionCookie] = [:]
        var sessionValue: String?
        var bytes = 0
        for var cookie in input {
            cookie.domain = cookie.domain.lowercased()
            guard names.contains(cookie.name), domains.contains(cookie.domain), cookie.path == "/",
                  !cookie.value.isEmpty, cookie.value.utf8.count <= 8_192,
                  cookie.value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && $0.value != 0x3B }),
                  cookie.name != "sessionid" || cookie.secure else { throw invalid }
            if let expires = cookie.expires {
                guard expires.isFinite, expires < 9_223_372_036_854_775_808 else { throw invalid }
                if expires <= now.timeIntervalSince1970 { continue }
            }
            bytes += cookie.value.utf8.count
            guard bytes <= 32_768 else { throw invalid }
            if cookie.name == "sessionid" {
                if let sessionValue, sessionValue != cookie.value { throw invalid }
                sessionValue = cookie.value
            }
            let key = (cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain) + ":" + cookie.name
            if let existing = seen[key] {
                guard existing == cookie else { throw invalid }
                continue
            }
            seen[key] = cookie
            result.append(cookie)
        }
        if requireSession && sessionValue == nil { throw missing }
        return result
    }
}

/// Injected storage permits policy tests without touching a user's Keychain.
struct InstagramSessionRepository {
    var read: () throws -> Data?
    var write: (Data) throws -> Void
    var delete: () throws -> Void

    private struct Record: Codable {
        var version: Int = 1
        var importedAt: Date
        var cookies: [InstagramSessionCookie]
    }

    func importCookies(_ payload: [Any], now: Date = Date()) throws -> InstagramSessionStatus {
        let cookies = try InstagramSessionValidation.decode(payload, now: now)
        let record = Record(importedAt: now, cookies: cookies)
        let data = try JSONEncoder().encode(record)
        guard data.count <= InstagramSessionValidation.maximumBytes else { throw InstagramSessionValidation.invalid }
        try write(data)
        return status(for: record, cookies: cookies)
    }

    func status(now: Date = Date()) -> InstagramSessionStatus {
        do {
            guard let record = try load() else { return InstagramSessionStatus(hasSession: false) }
            let cookies = try InstagramSessionValidation.validate(record.cookies, now: now, requireSession: false)
            return status(for: record, cookies: cookies)
        } catch let failure as MediaSaveError {
            return InstagramSessionStatus(hasSession: false, errorMessage: failure.message)
        } catch {
            return InstagramSessionStatus(hasSession: false, errorMessage: "The synced Instagram session could not be read. Sync again from the Downloader extension.")
        }
    }

    func resolverJSON(now: Date = Date()) throws -> String {
        guard let record = try load() else { return "[]" }
        let cookies = try InstagramSessionValidation.validate(record.cookies, now: now, requireSession: false)
        guard cookies.contains(where: { $0.name == "sessionid" }) else { return "[]" }
        return String(decoding: try JSONEncoder().encode(cookies), as: UTF8.self)
    }

    private func load() throws -> Record? {
        guard let data = try read() else { return nil }
        guard data.count <= InstagramSessionValidation.maximumBytes,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
              record.importedAt.timeIntervalSince1970.isFinite else { throw InstagramSessionValidation.invalid }
        return record
    }

    private func status(for record: Record, cookies: [InstagramSessionCookie]) -> InstagramSessionStatus {
        let sessionCookies = cookies.filter { $0.name == "sessionid" }
        guard !sessionCookies.isEmpty else { return InstagramSessionStatus(hasSession: false) }
        return InstagramSessionStatus(hasSession: true, importedAt: record.importedAt,
                                      expiresAt: sessionCookies.compactMap(\.expires).min().map(Date.init(timeIntervalSince1970:)))
    }
}

enum InstagramSessionStore {
    private static var repository: InstagramSessionRepository {
        InstagramSessionRepository(read: read, write: write, delete: delete)
    }

    static func importCookies(_ payload: [Any]) throws -> InstagramSessionStatus { try repository.importCookies(payload) }
    static func status() -> InstagramSessionStatus { repository.status() }
    static func resolverJSON() throws -> String { try repository.resolverJSON() }
    static func clear() throws { try repository.delete() }

    private static func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DownloaderKeychainAccessGroup") as? String,
              !group.isEmpty, !group.contains("$(") else {
            throw MediaSaveError(code: "instagramSessionConfiguration", message: "Instagram login sharing is unavailable in this build. Rebuild and install the complete Downloader app with its extensions.")
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "wang.xiaolin.Downloader.instagram-session",
                kSecAttrAccount as String: "safari-v1",
                kSecAttrAccessGroup as String: group,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true]
    }

    private static func read() throws -> Data? {
        var query = try query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        try check(code)
        guard let data = result as? Data else { throw InstagramSessionValidation.invalid }
        return data
    }

    private static func write(_ data: Data) throws {
        let query = try query()
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            // Two extension processes can both observe an empty vault. The
            // later import should update the atomically stored complete record.
            if added == errSecDuplicateItem {
                try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
            } else { try check(added) }
        } else { try check(code) }
    }

    private static func delete() throws {
        let code = SecItemDelete(try query() as CFDictionary)
        if code != errSecItemNotFound { try check(code) }
    }

    private static func check(_ code: OSStatus) throws {
        guard code == errSecSuccess else {
            let message = code == errSecInteractionNotAllowed
                ? "Unlock this device to access the synced Instagram session, then try again."
                : "The shared Instagram session could not be accessed. Rebuild and install Downloader with all its extensions, then sync again."
            throw MediaSaveError(code: "instagramSessionUnavailable", message: message)
        }
    }
}
