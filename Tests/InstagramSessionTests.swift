import Foundation

@main
enum InstagramSessionTests {
    static func main() throws {
        var checks = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.timeIntervalSince1970 + 3_600
        func expect(_ condition: Bool, _ label: String) { checks += 1; precondition(condition, label) }
        func cookie(_ name: String = "sessionid", _ value: String = "fixture-session") -> [String: Any] {
            ["name": name, "value": value, "domain": ".instagram.com", "path": "/",
             "secure": true, "httpOnly": true, "expires": expiry]
        }
        let session = cookie()
        var stored: Data?
        var reads = 0
        var writes = 0
        let repository = InstagramSessionRepository(read: { reads += 1; return stored }, write: { stored = $0; writes += 1 }, delete: { stored = nil })
        expect(repository.status(now: now).hasSession == false, "Empty vault claimed a session")
        expect(try repository.resolverJSON(now: now) == "[]", "Empty vault must permit anonymous extraction")
        let imported = try repository.importCookies([session, cookie("csrftoken", "fixture-csrf")], now: now)
        expect(imported.hasSession && imported.importedAt == now && imported.expiresAt?.timeIntervalSince1970 == expiry, "Synced metadata missing")
        let status = repository.status(now: now)
        expect(status.hasSession && status.errorMessage == nil, "Session could not be read across repository calls")
        let statusData = try JSONSerialization.data(withJSONObject: status.nativeMessage)
        expect(!String(decoding: statusData, as: UTF8.self).contains("fixture-"), "Status leaked cookie values")
        let json = try repository.resolverJSON(now: now)
        let cookies = try JSONDecoder().decode([InstagramSessionCookie].self, from: Data(json.utf8))
        expect(cookies.count == 2 && cookies[0].httpOnly && cookies[0].secure && cookies[0].value == "fixture-session", "Resolver handoff lost metadata")
        expect(writes == 1 && reads >= 3, "Resolver must read current process-shared storage")
        expect(!repository.status(now: now.addingTimeInterval(3_601)).hasSession, "Expired session claimed usable")
        expect(try repository.resolverJSON(now: now.addingTimeInterval(3_601)) == "[]", "Expired credentials entered extractor")
        var expiredCsrf = cookie("csrftoken", "expired-csrf")
        expiredCsrf["expires"] = now.timeIntervalSince1970 - 1
        let filtered = try InstagramSessionValidation.decode([session, expiredCsrf], now: now)
        expect(filtered.count == 1, "Expired supporting cookies must be filtered")
        expect(try InstagramSessionValidation.decode([session, session], now: now).count == 1, "Identical cookie duplicate must be deduplicated")
        var otherHost = session
        otherHost["domain"] = "www.instagram.com"
        expect(try InstagramSessionValidation.decode([session, otherHost], now: now).count == 2, "Same session on both allowed hosts rejected")
        var sessionOnly = session
        sessionOnly.removeValue(forKey: "expires")
        let ephemeral = try repository.importCookies([sessionOnly], now: now)
        expect(ephemeral.hasSession && ephemeral.expiresAt == nil, "Safari session cookie must not invent expiry")

        func reject(_ payload: [Any], _ label: String) throws {
            let before = stored
            do {
                _ = try repository.importCookies(payload, now: now)
                preconditionFailure(label)
            } catch let error as MediaSaveError {
                expect(!error.message.contains("fixture-session") && !error.message.contains("second-session"), "Import errors leaked cookie secrets")
            }
            expect(stored == before, "Rejected import overwrote the existing session")
        }
        for (field, value) in [
            ("domain", "instagram.com.attacker.example"), ("domain", "evil.instagram.com"),
            ("domain", "..instagram.com"), ("path", "/accounts"), ("name", "tracking"),
            ("value", "bad\r\nHeader"), ("value", "space value"), ("value", "bad;Header"), ("value", ""),
            ("value", String(repeating: "x", count: 8_193)), ("value", String(repeating: "é", count: 4_097))
        ] {
            var changed = session
            changed[field] = value
            try reject([changed], "Invalid cookie accepted: " + field)
        }
        for (field, value): (String, Any) in [("secure", false), ("secure", "true"), ("httpOnly", 1),
                                             ("expires", true), ("expires", Double.infinity),
                                             ("expires", 9_223_372_036_854_775_808.0)] {
            var changed = session
            changed[field] = value
            try reject([changed], "Invalid cookie flag/expiry accepted: " + field)
        }
        var changedSession = session
        changedSession["value"] = "second-session"
        try reject([session, changedSession], "Conflicting same-host session accepted")
        changedSession["domain"] = "www.instagram.com"
        try reject([session, changedSession], "Conflicting cross-host session accepted")
        try reject([cookie("csrftoken")], "CSRF cookie alone claimed a session")
        try reject([], "Empty import accepted")
        try reject(Array(repeating: session, count: 25), "Unbounded cookie array accepted")
        var largePayload = session
        largePayload["irrelevant"] = String(repeating: "x", count: 65_536)
        try reject([largePayload], "Unbounded JSON accepted")
        let supporting = ["csrftoken", "ds_user_id", "mid", "ig_did"].map { cookie($0, String(repeating: "x", count: 8_192)) }
        try reject([session] + supporting, "Unbounded aggregate values accepted")
        try repository.delete()
        expect(try repository.resolverJSON(now: now) == "[]" && !repository.status(now: now).hasSession, "Clear did not remove session")
        stored = Data("corrupt-vault".utf8)
        expect(repository.status(now: now).errorMessage != nil, "Corrupt vault silently claimed logged out")
        do { _ = try repository.resolverJSON(now: now); preconditionFailure("Corrupt vault used") }
        catch let error as MediaSaveError { expect(error.code == "invalidInstagramSession", "Wrong corrupt-vault code") }
        let locked = InstagramSessionRepository(read: { throw MediaSaveError(code: "locked", message: "Unlock device") }, write: { _ in }, delete: {})
        expect(locked.status().errorMessage == "Unlock device", "Keychain error was hidden from user")
        print("Instagram session validation and isolated storage: \(checks) checks passed.")
    }
}
