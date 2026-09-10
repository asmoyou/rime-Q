import AppKit
import Darwin
import InputMethodKit
import QRimeBridge

/// A short challenge/response verifies the serving process, not just the TIS
/// registration or a stale status file. Messages contain no input/user data.
struct RuntimeIdentity: Equatable {
    let appPath: String
    let build: String
    let pid: Int32
    static var current: Self {
        .init(appPath: Bundle.main.bundleURL.standardizedFileURL.path, build: Product.build,
              pid: ProcessInfo.processInfo.processIdentifier)
    }
}

enum RuntimeReadiness {
    static let request = Notification.Name("com.asmoyou.rimeq.runtimeProbe")
    static let reply = Notification.Name("com.asmoyou.rimeq.runtimeReply")

    static func accepts(_ notification: Notification, nonce: String, expected: RuntimeIdentity) -> RuntimeIdentity? {
        guard notification.name == reply, notification.object as? String == nonce,
              notification.userInfo?["path"] as? String == expected.appPath,
              notification.userInfo?["build"] as? String == expected.build,
              let pid = notification.userInfo?["pid"] as? NSNumber,
              pid.int32Value > 0, pid.int32Value != ProcessInfo.processInfo.processIdentifier else { return nil }
        return .init(appPath: expected.appPath, build: expected.build, pid: pid.int32Value)
    }

    static func probe(expected: RuntimeIdentity = .current, timeout: TimeInterval = 3) -> RuntimeIdentity? {
        precondition(Thread.isMainThread)
        let center = DistributedNotificationCenter.default(), nonce = UUID().uuidString
        var response: RuntimeIdentity?
        let observer = center.addObserver(forName: reply, object: nonce, queue: .main) {
            if let identity = accepts($0, nonce: nonce, expected: expected) { response = identity }
        }
        defer { center.removeObserver(observer) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var nextSend: TimeInterval = 0
        repeat {
            if ProcessInfo.processInfo.systemUptime >= nextSend {
                center.postNotificationName(request, object: expected.appPath,
                    userInfo: ["nonce": nonce, "build": expected.build], deliverImmediately: true)
                nextSend = ProcessInfo.processInfo.systemUptime + 0.2
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        } while response == nil && ProcessInfo.processInfo.systemUptime < deadline
        return response
    }
}

final class RuntimeResponder: NSObject {
    private let identity: RuntimeIdentity
    private let isReady: () -> Bool
    init(identity: RuntimeIdentity = .current, isReady: @escaping () -> Bool) {
        self.identity = identity; self.isReady = isReady
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(respond(_:)),
            name: RuntimeReadiness.request, object: identity.appPath, suspensionBehavior: .deliverImmediately)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func respond(_ notification: Notification) {
        guard isReady(), notification.userInfo?["build"] as? String == identity.build,
              let nonce = notification.userInfo?["nonce"] as? String, UUID(uuidString: nonce) != nil else { return }
        DistributedNotificationCenter.default().postNotificationName(RuntimeReadiness.reply, object: nonce,
            userInfo: ["path": identity.appPath, "build": identity.build, "pid": identity.pid], deliverImmediately: true)
    }
}

enum InstallationDiagnostics {
    static func append(_ message: String, root: URL = Product.userRoot) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) build=\(Product.build) \(message)\n"
        let path = root.appendingPathComponent("installation.log")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(path.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        line.withCString { _ = Darwin.write(descriptor, $0, strlen($0)) }
    }
}

enum RuntimeReadinessSmoke {
    static func worker(root: URL, ready: Bool) throws {
        let resolved = root.resolvingSymlinksInPath()
        try EngineSmoke.check(resolved.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            && resolved.lastPathComponent.hasPrefix("rimeq-runtime-test-"), "runtime fixture requires its own temporary directory")
        _ = NSApplication.shared
        var server: IMKServer?
        if ready {
            // Use a unique IMK connection and temporary user data. This does
            // not register/select an input source or disturb the live server.
            try Engine.start(user: root.appendingPathComponent("rime"))
            Engine.ready = true
            guard let fixtureID = Bundle.main.bundleIdentifier,
                  fixtureID.hasPrefix(Product.identifier + ".RuntimeFixture.") else {
                throw LexiconError.message("runtime server fixture requires its own bundle identity")
            }
            server = IMKServer(name: fixtureID + "_Connection", bundleIdentifier: fixtureID)
            try EngineSmoke.check(server != nil, "test IMK server did not initialize")
            let session = QRimeCreateSession()
            defer { QRimeDestroySession(session) }
            try EngineSmoke.check(QRimeSchema(session, "rime_q"), "test input schema unavailable")
            QRimeSetOption(session, "ascii_mode", false)
            EngineSmoke.type("nihao", session: session)
            try EngineSmoke.check(Engine.snapshot(session).candidates.contains(where: { $0.text == "你好" }),
                                  "serving process could not produce Chinese candidates")
            QRimeClear(session)
        }
        defer { Engine.ready = false; QRimeStop() }
        let identity = RuntimeIdentity(appPath: root.path, build: "fixture", pid: ProcessInfo.processInfo.processIdentifier)
        let responder = RuntimeResponder(identity: identity, isReady: { Engine.ready && server != nil })
        print("runtime-fixture: ready=\(ready) engine=\(Engine.ready) server=\(server != nil)")
        fflush(stdout)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline && !FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        withExtendedLifetime(responder) {}
    }
    static func run() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = RuntimeIdentity(appPath: root.path, build: "fixture", pid: 0)
        // IMK derives an additional legacy port from the bundle identifier.
        // A unique name parameter alone does not isolate a test server.
        let fixtureApp = root.appendingPathComponent("RuntimeFixture.app")
        let contents = fixtureApp.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let executable = contents.appendingPathComponent("MacOS/RimeQ")
        try FileManager.default.copyItem(at: Bundle.main.executableURL!, to: executable)
        let originalContents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        for name in ["Frameworks", "SharedSupport"] {
            try FileManager.default.createSymbolicLink(at: contents.appendingPathComponent(name), withDestinationURL: originalContents.appendingPathComponent(name))
        }
        var metadata = Bundle.main.infoDictionary!
        let fixtureID = Product.identifier + ".RuntimeFixture." + UUID().uuidString
        metadata["CFBundleIdentifier"] = fixtureID
        metadata["InputMethodConnectionName"] = fixtureID + "_Connection"
        metadata.removeValue(forKey: "ComponentInputModeDict")
        metadata.removeValue(forKey: "TISInputSourceID")
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", fixtureApp.path]
        try sign.run(); sign.waitUntilExit()
        try EngineSmoke.check(sign.terminationStatus == 0, "runtime fixture signing failed")
        try EngineSmoke.check(RuntimeReadiness.probe(expected: expected, timeout: 0.15) == nil, "missing process reported ready")
        for ready in [false, true] {
            let process = Process(); process.executableURL = executable
            process.arguments = ["--runtime-smoke-worker", root.path, ready ? "ready" : "starting"]
            try process.run()
            let response = RuntimeReadiness.probe(expected: expected, timeout: ready ? 6 : 0.6)
            try LexiconFiles.write("stop", to: root.appendingPathComponent("stop"))
            process.waitUntilExit()
            try FileManager.default.removeItem(at: root.appendingPathComponent("stop"))
            try EngineSmoke.check((response != nil) == ready, "runtime readiness differs from actual serving state: ready=\(ready) response=\(response != nil) exit=\(process.terminationStatus)")
            if ready { try EngineSmoke.check(response?.pid == process.processIdentifier, "runtime responder PID mismatch") }
        }
        let stale = Notification(name: RuntimeReadiness.reply, object: "old-challenge",
            userInfo: ["path": root.path, "build": "fixture", "pid": 123])
        try EngineSmoke.check(RuntimeReadiness.accepts(stale, nonce: "new-challenge", expected: expected) == nil,
                              "stale runtime reply accepted")
        for (path, build) in [(root.path + "/other", "fixture"), (root.path, "old-build")] {
            let foreign = Notification(name: RuntimeReadiness.reply, object: "challenge",
                userInfo: ["path": path, "build": build, "pid": 123])
            try EngineSmoke.check(RuntimeReadiness.accepts(foreign, nonce: "challenge", expected: expected) == nil,
                                  "another path/build was accepted as the updated server")
        }
        try EngineSmoke.check(RuntimeReadiness.probe(expected: expected, timeout: 0.15) == nil, "exited process reported ready")
        print("PASS runtime readiness: absent/unready/exited processes rejected; real IMK+librime server responds with exact build/path/PID")
    }
}
