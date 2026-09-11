import Foundation
import CryptoKit
import QRimeBridge

enum ModelSmoke {
    private static func wait(_ model: OptionalModel, seconds: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while model.state.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try EngineSmoke.check(!model.state.busy, "optional model operation did not finish")
    }

    /// Runs in separate app bundles to check reuse across application versions.
    static func reuse(root: URL, server: URL, phase: String) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard root.resolvingSymlinksInPath().deletingLastPathComponent() == temporary,
              root.lastPathComponent.hasPrefix("rimeq-model-reuse-"),
              ["download", "restore", "restore-disabled"].contains(phase) else {
            throw LexiconError.message("Invalid model reuse test arguments")
        }
        let defaults = UserDefaults(suiteName: "RimeQ.ModelReuse." + root.lastPathComponent)!
        let payload = Data(repeating: 0x71, count: 128 * 1024)
        let descriptor = ModelDescriptor(file: "wanxiang-lts-zh-hans.gram", bytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            url: server.appendingPathComponent(phase == "download" ? "reuse-model" : "must-not-download"))
        let model = OptionalModel(root: root, defaults: defaults, descriptor: descriptor)
        defer { model.shutdown() }
        if phase == "download" { model.download() }
        else { model.restore() }
        try wait(model)
        try EngineSmoke.check(model.available, "cached model was not restored in app version \(Product.version)")
        try EngineSmoke.check(model.enabled == (phase != "restore-disabled"), "application replacement changed the optimization preference")
        try EngineSmoke.check(try Data(contentsOf: model.fileURL) == payload, "application replacement changed cached model content")
        let link = root.appendingPathComponent("rime/" + descriptor.file)
        try EngineSmoke.check(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == model.fileURL.path,
                              "new application did not restore the model link")
        if phase == "restore" { model.setEnabled(false) }
        defaults.synchronize()
        print("PASS model reuse: app=\(Product.version) build=\(Product.build) phase=\(phase) file=unchanged")
    }

    static func run(server: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-model-smoke-" + UUID().uuidString)
        let suite = "RimeQ.ModelSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let payload = Data(repeating: 0x71, count: 128 * 1024)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        var models: [OptionalModel] = []
        defer { models.forEach { $0.shutdown() } }
        func make(_ path: String, name: String? = nil) -> OptionalModel {
            let model = OptionalModel(root: root.appendingPathComponent(name ?? path), defaults: defaults,
                descriptor: .init(file: "wanxiang-lts-zh-hans.gram", bytes: Int64(payload.count), sha256: hash,
                                  url: server.appendingPathComponent(path)))
            models.append(model)
            return model
        }
        defaults.set(true, forKey: "sentenceOptimization")
        let model = make("model")
        model.restore()
        try EngineSmoke.check(model.state == .missing && !model.activeOptimization, "missing model must fall back even with an old enabled preference")
        defaults.set(false, forKey: "sentenceOptimization")
        model.download()
        model.download() // repeated clicks must join the same operation
        try wait(model)
        try EngineSmoke.check(model.available && model.enabled && model.activeOptimization, "successful download did not enable optimization")
        try EngineSmoke.check(try Data(contentsOf: model.fileURL) == payload, "downloaded bytes changed")
        model.setEnabled(false)
        try EngineSmoke.check(!model.activeOptimization && model.available, "turning off must retain the downloaded file")
        let reopened = make("model")
        reopened.restore()
        try wait(reopened)
        try EngineSmoke.check(reopened.available && !reopened.enabled, "restart did not restore the downloaded model/preferences")
        let retained = model.root.appendingPathComponent("rime/personal-retention-check")
        try Data("keep".utf8).write(to: retained)
        try reopened.remove()
        try wait(reopened)
        try EngineSmoke.check(!FileManager.default.fileExists(atPath: model.fileURL.path) && FileManager.default.fileExists(atPath: retained.path), "model removal changed learning files")
        for path in ["corrupt", "missing", "oversize"] {
            let failure = make(path)
            failure.download()
            try wait(failure)
            guard case .failed = failure.state else { throw LexiconError.message("Invalid model was accepted: \(path)") }
            try EngineSmoke.check(!failure.available && !failure.activeOptimization && !FileManager.default.fileExists(atPath: failure.fileURL.path), "unverified model was installed")
        }
        let retry = make("retry")
        retry.download(); try wait(retry)
        guard case .failed = retry.state else { throw LexiconError.message("503 was not reported") }
        retry.download(enableAfterwards: false); try wait(retry)
        try EngineSmoke.check(retry.available && !retry.activeOptimization, "retry failed or enabled optimization without request")
        let slow = make("slow")
        slow.download()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .downloading(let bytes) = slow.state, bytes > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        slow.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try EngineSmoke.check(!slow.available && slow.state == .missing && !FileManager.default.fileExists(atPath: slow.fileURL.path), "cancelled download activated or left a model")
        try EngineSmoke.check((try FileManager.default.contentsOfDirectory(atPath: slow.directory.path)).isEmpty, "cancelled download left partial files")
        let corruptLocal = make("model", name: "corrupt-local")
        try FileManager.default.createDirectory(at: corruptLocal.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: payload.count).write(to: corruptLocal.fileURL)
        defaults.set(true, forKey: "sentenceOptimization")
        corruptLocal.restore(); try wait(corruptLocal)
        try EngineSmoke.check(!corruptLocal.activeOptimization && !corruptLocal.available, "corrupt local cache activated an old enabled preference")
        let occupied = make("model", name: "occupied")
        let userFile = occupied.root.appendingPathComponent("rime/wanxiang-lts-zh-hans.gram")
        try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: userFile)
        occupied.download(); try wait(occupied)
        try EngineSmoke.check(!occupied.available && (try String(contentsOf: userFile)) == "unrelated", "activation overwrote an unmanaged model file")
        print("PASS optional model: real download tasks, progress, checksum/size rejection, HTTP failures/retry, cancel, restart, opt-in activation and removal preserving learning files")
    }

    static func live(localSource: URL? = nil) throws {
        guard let descriptor = ModelDescriptor.bundled else { throw LexiconError.message("Missing model metadata") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-model-live-" + UUID().uuidString)
        let suite = "RimeQ.ModelLive." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = OptionalModel(root: root, defaults: defaults, descriptor: descriptor)
        defer { model.shutdown(); Engine.ready = false; QRimeStop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try EngineSmoke.check(!FileManager.default.fileExists(atPath: Engine.bundledShared.appendingPathComponent(descriptor.file).path), "model is still bundled")
        try Engine.start(user: root.appendingPathComponent("rime")); Engine.ready = true
        var session = QRimeCreateSession()
        try EngineSmoke.check(QRimeSchema(session, "rime_q"), "base input needs the optional model")
        if let localSource {
            try FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: localSource, to: model.fileURL)
            defaults.set(true, forKey: "sentenceOptimization")
            model.restore()
        } else { model.download() }
        let deadline = Date().addingTimeInterval(600)
        var checks = 0
        while model.state.busy && Date() < deadline {
            QRimeClear(session)
            EngineSmoke.type("nihao", session: session)
            try EngineSmoke.check(Engine.snapshot(session).candidates.contains { $0.text == "你好" }, "download interrupted base input")
            QRimeClear(session)
            checks += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try EngineSmoke.check(model.available && model.activeOptimization, "live model download failed: \(model.statusDescription)")
        try EngineSmoke.check(QRimeSchema(session, "rime_q_grammar"), "downloaded grammar schema unavailable")
        EngineSmoke.type("cC1+2*3", session: session)
        try EngineSmoke.check(Engine.snapshot(session).candidates.contains { $0.text == "7" }, "optional grammar model changed Lua tools")
        QRimeClear(session)
        EngineSmoke.type("qinglansongshuceci", session: session)
        for word in ["青", "岚", "松", "鼠", "测", "词"] { try EngineSmoke.choose(word, session: session) }
        try EngineSmoke.check(String(cString: QRimeTakeCommit(session)) == "青岚松鼠测词", "downloaded model mode did not commit")
        let maps = Process(), output = Pipe()
        maps.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        maps.arguments = ["-p", String(ProcessInfo.processInfo.processIdentifier), "-Fn"]
        maps.standardOutput = output; maps.standardError = FileHandle.nullDevice
        try maps.run()
        let mapped = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        maps.waitUntilExit()
        try EngineSmoke.check(mapped.contains(model.fileURL.path), "librime did not map the model from personal storage")
        QRimeDestroySession(session)
        let resources = DictionaryResources(root: root)
        var custom = resources.configuration
        custom.disabled.insert("cn_dicts/others")
        var applied: Result<Void, Error>?
        resources.apply(custom) { applied = $0 }
        let compileDeadline = Date().addingTimeInterval(90)
        while applied == nil && Date() < compileDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        try EngineSmoke.check(applied != nil, "custom dictionary compilation did not finish")
        try applied?.get()
        session = QRimeCreateSession()
        try EngineSmoke.check(QRimeSchema(session, "rime_q_grammar"), "custom dictionary generation could not use downloaded model")
        EngineSmoke.type("qinglansongshuceci", session: session)
        try EngineSmoke.check(Engine.snapshot(session).candidates.contains { $0.text == "青岚松鼠测词" }, "custom dictionary/model combination lost learning")
        QRimeClear(session); QRimeDestroySession(session)
        try model.remove(); try wait(model)
        try EngineSmoke.check(!model.activeOptimization && !model.available, "model removal left optimization active")
        session = QRimeCreateSession()
        defer { QRimeDestroySession(session) }
        try EngineSmoke.check(QRimeSchema(session, "rime_q"), "base input did not recover after model removal")
        EngineSmoke.type("qinglansongshuceci", session: session)
        try EngineSmoke.check(Engine.snapshot(session).candidates.contains { $0.text == "青岚松鼠测词" }, "model removal lost learned words")
        print("PASS optional model integration: \(localSource == nil ? "GitHub download" : "local verified cache"), SHA-256; \(checks) base input checks; user-path grammar mapping, Lua, custom dictionaries, removal and learning retention")
    }
}
