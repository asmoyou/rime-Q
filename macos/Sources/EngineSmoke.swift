import Foundation
import QRimeBridge

enum EngineSmoke {
    static var schemas: [String] {
        let filename = "wanxiang-lts-zh-hans.gram"
        let roots = [Engine.userDirectory, Engine.sharedDirectory].compactMap { $0 }
        let hasModel = roots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(filename).path) }
        return hasModel ? ["rime_q", "rime_q_grammar"] : ["rime_q"]
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "RimeQSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func type(_ input: String, session: UInt) {
        for c in input.utf8 { _ = QRimeProcess(session, Int32(c), 0) }
    }

    static func choose(_ text: String, session: UInt) throws {
        for _ in 0..<100 {
            let state = Engine.snapshot(session)
            if let index = state.candidates.firstIndex(where: { $0.text == text }) {
                try check(QRimeSelect(session, index), "candidate selection rejected")
                return
            }
            if state.lastPage { break }
            _ = QRimeProcess(session, 0xff56, 0)
        }
        throw NSError(domain: "RimeQSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture candidate missing: \(text)"])
    }

    static func phase(_ phase: String, user: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let resolved = user.resolvingSymlinksInPath()
        try check(resolved.deletingLastPathComponent() == temporary && resolved.lastPathComponent.hasPrefix("rimeq-smoke-"),
                  "smoke requires a dedicated temporary directory")
        try Engine.start(user: resolved)
        defer { QRimeStop() }
        let session = QRimeCreateSession()
        try check(session != 0, "session creation failed")
        defer { QRimeDestroySession(session) }
        try check(QRimeSchema(session, "rime_q"), "base schema missing")
        QRimeSetOption(session, "ascii_mode", false)
        if phase == "learn" {
            type("nihao", session: session)
            try check(Engine.snapshot(session).candidates.contains { $0.text == "你好" }, "basic Chinese conversion failed")
            try choose("你好", session: session)
            try check(String(cString: QRimeTakeCommit(session)) == "你好", "wrong committed text")
            type("qinglansongshuceci", session: session)
            for word in ["青", "岚", "松", "鼠", "测", "词"] { try choose(word, session: session) }
            try check(String(cString: QRimeTakeCommit(session)) == "青岚松鼠测词", "partial choices did not compose correctly")
            type("qinglansongshuceci", session: session)
            try check(Engine.snapshot(session).candidates.contains { $0.text == "青岚松鼠测词" }, "new phrase not recalled on first page")
            QRimeClear(session)
            // Exercise frequent single-character learning without depending on its initial rank.
            for _ in 0..<4 {
                type("shi", session: session)
                try choose("诗", session: session)
                try check(String(cString: QRimeTakeCommit(session)) == "诗", "single-character commit failed")
            }
        } else if phase == "reopen" {
            type("qinglansongshuceci", session: session)
            try check(Engine.snapshot(session).candidates.contains { $0.text == "青岚松鼠测词" }, "phrase did not survive process restart")
            QRimeClear(session)
            type("shi", session: session)
            try check(Engine.snapshot(session).candidates.contains { $0.text == "诗" }, "frequent character is not on first page")
            QRimeClear(session)
            if schemas.contains("rime_q_grammar") { try check(QRimeSchema(session, "rime_q_grammar"), "grammar schema missing") }
            type("qinglansongshuceci", session: session)
            try check(Engine.snapshot(session).candidates.contains { $0.text == "青岚松鼠测词" }, "mode switch lost shared learning")
            QRimeClear(session)
            // Two engine sessions must retain independent compositions.
            let other = QRimeCreateSession()
            defer { QRimeDestroySession(other) }
            _ = QRimeSchema(other, "rime_q")
            type("nihao", session: session)
            type("zhongguo", session: other)
            try check(Engine.snapshot(session).input == "nihao", "composition leaked across sessions")
            try check(Engine.snapshot(other).input == "zhongguo", "second session lost composition")
            QRimeClear(session)
            QRimeClear(other)
        } else { throw NSError(domain: "RimeQSmoke", code: 3) }
        print("PASS \(phase); librime \(String(cString: QRimeVersion()))")
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for phase in ["learn", "reopen"] {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--smoke-phase", phase, root.path]
            try process.run()
            process.waitUntilExit()
            try check(process.terminationStatus == 0, "engine phase failed: \(phase)")
        }
    }

    static func benchmark() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-bench-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = DispatchTime.now().uptimeNanoseconds
        try Engine.start(user: root)
        let startup = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        defer { QRimeStop() }
        let session = QRimeCreateSession()
        defer { QRimeDestroySession(session) }
        for schema in schemas {
            try check(QRimeSchema(session, schema), "benchmark schema unavailable")
            var times: [Double] = []
            for cycle in 0..<60 {
                for code in ["nihao", "zhongguo", "womenshiyongshurufa", "jintiantianqihenhao", "shijieshang"] {
                    QRimeClear(session)
                    for c in code.utf8 {
                        let begin = DispatchTime.now().uptimeNanoseconds
                        _ = QRimeProcess(session, Int32(c), 0)
                        _ = Engine.snapshot(session)
                        if cycle > 4 { times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000) }
                    }
                }
            }
            times.sort()
            func percentile(_ p: Double) -> Double { times[Int(Double(times.count - 1) * p)] }
            print(String(format: "%@ samples=%d key+snapshot p50=%.3f ms p95=%.3f ms p99=%.3f ms", schema, times.count,
                         percentile(0.50), percentile(0.95), percentile(0.99)))
        }
        print(String(format: "startup=%.1f ms; synthetic corpus; excludes IMK and drawing", startup))
    }
}
