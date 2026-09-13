import AppKit
import QRimeBridge

struct SyncRecordKey: Codable, Equatable { let namespace: String; let text: String; let code: String }
struct SyncRecord: Codable, Equatable {
    let key: SyncRecordKey
    let weight: Int
    init(_ entry: LexiconEntry) { key = .init(namespace: "rime_q/full-pinyin/v1", text: entry.text, code: entry.code.trimmingCharacters(in: .whitespaces)); weight = entry.weight }
    var entry: LexiconEntry { .init(text: key.text, code: key.code, weight: weight) }
    var object: [String: Any] { ["key": ["namespace": key.namespace, "text": key.text, "code": key.code], "weight": weight] }
}
struct SyncApplication: Decodable { let id: String; let before: [SyncRecord]; let after: [SyncRecord] }

@MainActor final class DeviceSync {
    static let shared = DeviceSync()
    static let changed = Notification.Name("RimeQDeviceSyncChanged")
    let root = Product.userRoot.appendingPathComponent("sync", isDirectory: true)
    private var timer: Timer?
    private var helper: Process?
    private var busy = false
    private var revision: UInt64?
    private var version: Data?
    private(set) var lastError: String?
    private var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RimeQ.Sync") }

    func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "SyncStarted"), timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { await self?.tick() } }
        Task { await tick() }
    }
    func markStarted() { UserDefaults.standard.set(true, forKey: "SyncStarted"); startIfEnabled() }
    nonisolated private static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG"].contains($0.key) }
    }
    func ensureStarted() async throws {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path),
           (try? await request(["action": "status"])) != nil { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LexiconError.message("同步组件缺失，请安装包含此功能的完整版本。") }
        if helper?.isRunning != true {
            let child = Process(); child.executableURL = executable
            child.arguments = ["serve", "--root", root.path]; child.environment = Self.environment
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); helper = child
        }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? await request(["action": "status"])) != nil { return }
        }
        throw LexiconError.message("同步服务未能启动，请稍后重试。")
    }
    func request(_ object: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let executable = executable, root = root
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let task = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
                    task.executableURL = executable; task.arguments = ["control", "--root", root.path]
                    task.environment = Self.environment; task.standardInput = input; task.standardOutput = output; task.standardError = errors
                    try task.run()
                    let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 145, execute: timeout)
                    input.fileHandleForWriting.write(data); try input.fileHandleForWriting.close()
                    let result = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit(); timeout.cancel()
                    guard task.terminationStatus == 0, result.count <= 96 * 1024 * 1024,
                          let value = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
                        throw LexiconError.message("同步操作未完成。请检查设备状态、配对码及原设备的确认，过期后重新生成邀请。")
                    }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func job(_ result: [String: Any]) throws -> SyncApplication? {
        guard let object = result["job"], !(object is NSNull) else { return nil }
        return try JSONDecoder().decode(SyncApplication.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func same(_ lhs: [SyncRecord], _ rhs: [SyncRecord]) -> Bool {
        Dictionary(uniqueKeysWithValues: lhs.map { ($0.entry.id, $0.weight) }) == Dictionary(uniqueKeysWithValues: rhs.map { ($0.entry.id, $0.weight) })
    }
    private func snapshot() throws -> [SyncRecord] {
        precondition(Thread.isMainThread)
        guard !InputSession.hasComposition else { throw LexiconError.message("等待当前输入结束。") }
        return try PersonalDictionary.shared.entries().map(SyncRecord.init)
    }
    private func apply(_ application: SyncApplication) throws -> [SyncRecord]? {
        precondition(Thread.isMainThread)
        guard !InputSession.hasComposition else { return nil }
        return try Engine.maintain {
            let store = PersonalDictionary.shared
            let actual = try store.readClosedDictionary().map(SyncRecord.init)
            guard same(actual, application.before) else { return nil }
            try application.after.forEach { try $0.entry.validateFullPinyin() }
            let backup = root.appendingPathComponent("backups/before-\(UUID().uuidString).tsv")
            try LexiconFiles.write(LexiconEntry.portable(actual.map(\.entry)), to: backup)
            let before = Dictionary(uniqueKeysWithValues: actual.map { ($0.entry.id, $0) })
            let after = Dictionary(uniqueKeysWithValues: application.after.map { ($0.entry.id, $0) })
            var rows: [String] = []
            for entry in application.after where before[entry.entry.id]?.weight != entry.weight {
                if let prior = before[entry.entry.id], prior.weight > entry.weight { rows.append("\(entry.key.text)\t\(entry.key.code)\t-1") }
                rows.append(entry.entry.tsv)
            }
            for entry in actual where after[entry.entry.id] == nil { rows.append("\(entry.key.text)\t\(entry.key.code)\t-1") }
            let patch = root.appendingPathComponent("engine/apply.tsv")
            try LexiconFiles.write(rows.joined(separator: "\n") + "\n", to: patch)
            let count = QRimeImportPersonalDictionary(patch.path)
            let observed = try store.readClosedDictionary().map(SyncRecord.init)
            guard count >= 0, same(observed, application.after) else { throw LexiconError.message("同步写入未能完整完成，原记录及恢复快照已保留。") }
            return observed
        }
    }
    func tick() async {
        precondition(Thread.isMainThread)
        guard !busy, UserDefaults.standard.bool(forKey: "SyncStarted") else { return }
        busy = true; defer { busy = false; NotificationCenter.default.post(name: Self.changed, object: nil) }
        do {
            try await ensureStarted(); let status = try await request(["action": "status"])
            guard status["enabled"] as? Bool == true, Engine.ready, !InputSession.hasComposition else { return }
            let remote = try JSONSerialization.data(withJSONObject: ["revision": status["revision"] ?? ""], options: .sortedKeys)
            guard revision != QRimeLearningRevision() || remote != version || status["waiting_input"] as? Bool == true else { return }
            var pending = try job(await request(["action": "pending_apply"]))
            guard !InputSession.hasComposition else { return }
            let actual = try snapshot()
            var capturedRevision = QRimeLearningRevision()
            if let value = pending, same(actual, value.after) {
                _ = try await request(["action": "acknowledge", "id": value.id, "rows": actual.map(\.object)]); pending = nil
            }
            if pending == nil { pending = try job(await request(["action": "capture", "rows": actual.map(\.object)])) }
            if let value = pending {
                guard same(actual, value.before) else { throw LexiconError.message("同步恢复期间词库已有新修改。已保留本机记录和恢复快照，请在同步页面处理。") }
                if InputSession.hasComposition { return }
                guard let observed = try apply(value) else {
                    _ = try await request(["action": "abort_unapplied", "id": value.id]); revision = nil; return
                }
                capturedRevision = QRimeLearningRevision()
                _ = try await request(["action": "acknowledge", "id": value.id, "rows": observed.map(\.object)])
            }
            revision = capturedRevision; version = remote; lastError = nil
        } catch { lastError = error.localizedDescription }
    }
    func recoverLocal() async throws {
        guard !busy else { throw LexiconError.message("正在同步，请稍后重试。") }
        busy = true; defer { busy = false }
        guard let pending = try job(await request(["action": "pending_apply"])) else { return }
        let actual = try snapshot(), tag = UUID().uuidString
        try LexiconFiles.write(LexiconEntry.portable(actual.map(\.entry)), to: root.appendingPathComponent("backups/recovery-local-\(tag).tsv"))
        try LexiconFiles.write(LexiconEntry.portable(pending.after.map(\.entry)), to: root.appendingPathComponent("backups/recovery-target-\(tag).tsv"))
        _ = try await request(["action": "recover_local", "id": pending.id, "rows": actual.map(\.object)])
        revision = nil; version = nil; lastError = nil
    }
    func leave() async throws {
        UserDefaults.standard.set(false, forKey: "SyncStarted")
        timer?.invalidate(); timer = nil
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        do { _ = try await request(["action": "leave"]); revision = nil; version = nil; lastError = nil }
        catch { markStarted(); throw error }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        // Only the exact child process created by this instance is terminated.
        // SQLite WAL and application jobs provide recovery after interruption.
        if helper?.isRunning == true { helper?.terminate() }
    }
}
