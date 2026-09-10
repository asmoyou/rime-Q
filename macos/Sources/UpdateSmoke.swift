import AppKit

private final class UpdateFixtureProtocol: URLProtocol {
    static var status = 200
    static var payload = Data(#"{"tag_name":"v0.3.0","draft":false,"prerelease":false}"#.utf8)
    static var failure: URLError?
    static var requests: [URLRequest] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.status, payload = Self.payload, failure = Self.failure
        Self.lock.unlock()
        if let failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

enum UpdateSmoke {
    private static func wait(_ checker: UpdateChecker) throws {
        let deadline = Date().addingTimeInterval(20)
        while checker.isChecking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try EngineSmoke.check(!checker.isChecking, "update request did not finish within its timeout")
    }

    static func run() throws {
        func parsed(_ json: String, _ status: Int = 200, _ installed: String = "0.2.4") -> ReleaseLookup {
            ReleaseLookup.parse(data: Data(json.utf8), status: status, installed: installed)
        }
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0"}"#) == .available("v0.3.0"), "upgrade not detected")
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0"}"#, 200, "0.3.0") == .current, "same release offered as an update")
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0"}"#, 200, "0.4.0") == .current, "downgrade offered as an update")
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0"}"#, 200, "0.3.0-rc.1") == .available("v0.3.0"), "stable release must supersede a prerelease")
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0","draft":true}"#) == .invalid, "draft must not be offered")
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0","prerelease":true}"#) == .invalid, "prerelease must not be offered")
        try EngineSmoke.check(parsed(#"{"tag_name":"v0.3.0-rc.1"}"#) == .invalid, "prerelease tag must not be offered")
        for version in ["", "bad", "0.3", "0..3.0", "0.3.0.", "00.3.0", "0.3.0-", "0.3.0-01", "0.3.0+", "0.3.0\n"] {
            try EngineSmoke.check(ReleaseVersion(version) == nil, "accepted malformed version: \(version)")
        }
        try EngineSmoke.check(ReleaseVersion("v0.3.0+build.12") == ReleaseVersion("0.3.0"), "build metadata changed version precedence")
        try EngineSmoke.check(ReleaseVersion("0.3.0-rc.2")! < ReleaseVersion("0.3.0-rc.10")!, "prerelease numbers compared as text")
        for status in [403, 429, 500] { try EngineSmoke.check(parsed("{}", status) == .invalid, "HTTP failure reported as current") }
        try EngineSmoke.check(parsed("", 404) == .unpublished && parsed("<html>error</html>") == .invalid, "missing/malformed release not distinguished")

        let suite = "RimeQ.UpdateSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var date = Date(timeIntervalSince1970: 1_789_084_800)
        let checker = UpdateChecker(defaults: defaults, session: session, installed: "0.2.4", now: { date })
        try EngineSmoke.check(checker.automatic && checker.nextAutomaticCheck == date, "first run should be due by default")
        checker.start()
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 0, "startup check should be deferred")
        checker.checkIfDue()
        var manualResult: ReleaseLookup?
        checker.check { manualResult = $0 }
        try wait(checker)
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 1 && manualResult == .available("v0.3.0"), "manual check did not join the automatic request")
        try EngineSmoke.check(checker.lastAttempt == date && checker.availableTag == "v0.3.0", "successful check was not persisted")
        let restarted = UpdateChecker(defaults: defaults, session: session, installed: "0.2.4", now: { date })
        try EngineSmoke.check(restarted.availableTag == "v0.3.0", "new-version hint lost on restart")
        restarted.checkIfDue()
        date.addTimeInterval(UpdateChecker.interval - 1)
        restarted.checkIfDue()
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 1 && !restarted.isChecking, "restart/early timer bypassed daily limit")
        date.addTimeInterval(1)
        restarted.checkIfDue()
        try wait(restarted)
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 2, "daily boundary did not trigger check")
        restarted.automatic = false
        date.addTimeInterval(UpdateChecker.interval * 3)
        restarted.checkIfDue()
        try EngineSmoke.check(!restarted.isChecking && restarted.nextAutomaticCheck == nil, "disabled automatic checks still run")
        restarted.check { manualResult = $0 }
        try wait(restarted)
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 3 && manualResult == .available("v0.3.0"), "manual check must work when automatic is disabled")
        restarted.automatic = true
        restarted.checkIfDue()
        try EngineSmoke.check(!restarted.isChecking, "manual request must reset the automatic daily interval")
        UpdateFixtureProtocol.lock.lock(); UpdateFixtureProtocol.failure = URLError(.notConnectedToInternet); UpdateFixtureProtocol.lock.unlock()
        date.addTimeInterval(UpdateChecker.interval)
        restarted.checkIfDue()
        try wait(restarted)
        try EngineSmoke.check(restarted.result == .invalid, "offline request reported as current")
        try EngineSmoke.check(restarted.availableTag == "v0.3.0", "network failure discarded a previously known update")
        restarted.checkIfDue()
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 4 && !restarted.isChecking, "offline failure caused automatic retries")
        UpdateFixtureProtocol.lock.lock(); UpdateFixtureProtocol.failure = nil; UpdateFixtureProtocol.lock.unlock()
        date.addTimeInterval(-UpdateChecker.interval * 5)
        restarted.checkIfDue()
        try wait(restarted)
        try EngineSmoke.check(UpdateFixtureProtocol.count() == 5 && restarted.lastAttempt == date, "clock rollback prevented future checks")
        let upgraded = UpdateChecker(defaults: defaults, session: session, installed: "0.3.0", now: { date })
        try EngineSmoke.check(upgraded.availableTag == nil, "installed update retained an obsolete badge")
        upgraded.check()
        try wait(upgraded)
        let currentAgain = UpdateChecker(defaults: defaults, session: session, installed: "0.3.0", now: { date })
        try EngineSmoke.check(currentAgain.result == .current, "restart discarded the last successful check result")
        UpdateFixtureProtocol.lock.lock()
        let requests = UpdateFixtureProtocol.requests
        UpdateFixtureProtocol.lock.unlock()
        try EngineSmoke.check(requests.allSatisfy {
            $0.url == UpdateChecker.endpoint && $0.httpMethod == "GET" && $0.httpBody == nil
                && ["RimeQ/0.2.4", "RimeQ/0.3.0"].contains($0.value(forHTTPHeaderField: "User-Agent") ?? "")
        }, "release requests contained unexpected URL, method or body")
        print("PASS updates: real URLSession transport fixtures; release states, semantic versions, daily limit, restarts, deferred startup, opt-out, manual joins, offline backoff, clock rollback, no input data")
    }

    static func live(installed: String, expected: String) throws {
        let suite = "RimeQ.UpdateLive." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, installed: installed)
        checker.check()
        try wait(checker)
        let actual: String
        switch checker.result {
        case .available(let tag): actual = "available:" + tag
        case .current: actual = "current"
        case .unpublished: actual = "unpublished"
        default: actual = "invalid"
        }
        try EngineSmoke.check(actual == expected, "live GitHub lookup for \(installed): expected \(expected), got \(actual)")
        print("PASS live GitHub update check: installed=\(installed) result=\(actual)")
    }
}
