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
    let root: URL
    private let defaults: UserDefaults
    private let dictionary: PersonalDictionary
    private let executable: URL
    private let isolated: Bool
    // Runs only in the isolated native regression harness, after real IPC.
    var beforeRequest: ((String) throws -> Void)?
    var afterRequest: ((String) throws -> Void)?

    init(root: URL = Product.userRoot, defaults: UserDefaults = .standard,
         dictionary: PersonalDictionary = .shared, executable: URL? = nil, isolated: Bool = false) {
        self.root = root.appendingPathComponent("sync", isDirectory: true)
        self.defaults = defaults; self.dictionary = dictionary; self.isolated = isolated
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RimeQ.Sync")
    }
    private var timer: Timer?
    private var helper: Process?
    private var busy = false
    private var revision: UInt64?
    private var version: Data?
    private(set) var lastError: String?
    private var startupFailure: String?
    private var startupErrors: Pipe?
    private var retryAfter: TimeInterval = 0

    // Viewing an unused feature must not create an identity or access Keychain.
    func displayStatus() async throws -> [String: Any] {
        if let startupFailure { throw LexiconError.message(startupFailure) }
        if !defaults.bool(forKey: "SyncStarted"), helper?.isRunning != true {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path),
               let status = try? await request(["action": "status"]) { return status }
            return ["group": NSNull(), "enabled": false]
        }
        try await ensureStarted()
        return try await request(["action": "status"])
    }

    func startIfEnabled() {
        guard defaults.bool(forKey: "SyncStarted"), timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { [weak self] in await self?.tick() } }
        Task { await tick() }
    }
    func markStarted() { defaults.set(true, forKey: "SyncStarted"); startIfEnabled() }
    nonisolated private static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG"].contains($0.key) }
    }
    func ensureStarted(retry: Bool = false) async throws {
        if retry { startupFailure = nil }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("control.json").path),
           (try? await request(["action": "status"])) != nil { startupFailure = nil; return }
        if let startupFailure { throw LexiconError.message(startupFailure) }
        do {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LexiconError.message("同步组件缺失，请安装包含此功能的完整版本。") }
            if helper?.isRunning != true {
                let child = Process(); child.executableURL = executable
                child.arguments = ["serve", "--root", root.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)] + (isolated ? ["--isolated", "--no-discovery", "--bind", "127.0.0.1"] : [])
                child.environment = Self.environment
                let errors = Pipe()
                child.standardOutput = FileHandle.nullDevice; child.standardError = errors
                startupErrors = errors
                try child.run(); helper = child; revision = nil; version = nil
            }
            for _ in 0..<40 {
                if helper?.isRunning == false {
                    let diagnostic = startupErrors?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                    throw LexiconError.message(Self.failureMessage(String(decoding: diagnostic.prefix(4096), as: UTF8.self)))
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                if (try? await request(["action": "status"])) != nil { return }
            }
            throw LexiconError.message("同步服务未能启动，请稍后重试。")
        } catch {
            // Polling must not repeatedly relaunch a helper after denied access.
            startupFailure = error.localizedDescription
            throw error
        }
    }
    func request(_ object: [String: Any]) async throws -> [String: Any] {
        if isolated { try beforeRequest?(object["action"] as? String ?? "") }
        let data = try JSONSerialization.data(withJSONObject: object)
        let executable = executable, root = root
        let response: [String: Any] = try await withCheckedThrowingContinuation { continuation in
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
                    let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
                    guard task.terminationStatus == 0 else {
                        throw LexiconError.message(Self.failureMessage(String(decoding: diagnostic.prefix(4096), as: UTF8.self)))
                    }
                    guard result.count <= 96 * 1024 * 1024,
                          let value = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
                        throw LexiconError.message("同步操作未完成。请检查设备状态、配对码及原设备的确认，过期后重新生成邀请。")
                    }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
        if isolated { try afterRequest?(object["action"] as? String ?? "") }
        return response
    }
    // Never expose raw helper output: it may contain paths or library details.
    nonisolated private static func failureMessage(_ detail: String) -> String {
        for (needle, message) in [
            ("incompatible peer", "设备的同步协议版本不一致，请将两端 Rime Q 都升级到支持完整学习记录同步的版本；无需重新配对，本机词库保留。"),
            ("enter a local IP address and port", "连接地址格式不正确，请复制原设备显示的 IP 地址和端口。"),
            ("invalid port", "连接端口不正确，请重新复制原设备的连接信息。"),
            ("only local network addresses", "请选择局域网地址。两台电脑需要在能够互相连接的本地网络中。"),
            ("invalid name", "设备或同步组名称无效，请缩短名称并去掉换行等特殊字符。"),
            ("no open invitation", "原设备的邀请已结束，请重新生成配对码。"),
            ("invitation expired", "配对码已过期或尝试次数已用完，请在原设备重新生成。"),
            ("pairing was not approved", "原设备未允许加入，或确认已超时。请重新邀请后再试。"),
            ("pairing cancelled", "已取消加入同步组。"),
            ("this device was removed", "这台电脑已被移出同步组。保留本机词库，退出后可重新受邀加入。"),
            ("capacity exceeded", "同步数据已达到容量上限，已停止本次操作；本机词库仍保留。"),
            ("exceeds limit", "同步快照超过大小限制，已停止本次操作；本机词库仍保留。"),
            ("pairing request expired", "加入请求已过期，请在原设备重新生成邀请。"),
            ("recover pending", "有未完成的词库写入，请先处理同步恢复。"),
            ("sync unavailable", "同步已暂停或成员授权已失效，请检查设备状态。"),
            ("listener unavailable", "无法监听本地网络，请检查 Rime Q 的本地网络权限和防火墙。"),
            ("Connection refused", "同步服务暂不可用，请稍后重试。"),
            ("deadline has elapsed", "连接超时，请检查两台电脑的网络、权限及原设备的确认。")
        ] where detail.contains(needle) { return message }
        return "同步操作未完成。请检查设备状态、配对码及原设备的确认，过期后重新生成邀请。"
    }

    private func job(_ result: [String: Any]) throws -> SyncApplication? {
        guard let object = result["job"], !(object is NSNull) else { return nil }
        let application = try JSONDecoder().decode(SyncApplication.self, from: JSONSerialization.data(withJSONObject: object))
        for rows in [application.before, application.after] {
            var keys = Set<String>()
            guard rows.count <= 200_000 else { throw LexiconError.message("同步词库超过 20 万条限制。") }
            for row in rows {
                try row.entry.validate()
                guard row.key.namespace == "rime_q/full-pinyin/v1", keys.insert(row.entry.id).inserted else {
                    throw LexiconError.message("同步快照包含不兼容或重复词条，已停止写入。")
                }
            }
        }
        return application
    }
    private func same(_ lhs: [SyncRecord], _ rhs: [SyncRecord]) -> Bool {
        Dictionary(uniqueKeysWithValues: lhs.map { ($0.entry.id, $0.weight) }) == Dictionary(uniqueKeysWithValues: rhs.map { ($0.entry.id, $0.weight) })
    }
    private func snapshot() throws -> [SyncRecord] {
        precondition(Thread.isMainThread)
        guard !InputSession.hasComposition else { throw LexiconError.message("等待当前输入结束。") }
        return try dictionary.entries().map(SyncRecord.init)
    }
    private func apply(_ application: SyncApplication) throws -> [SyncRecord]? {
        precondition(Thread.isMainThread)
        guard !InputSession.hasComposition else { return nil }
        return try Engine.maintain {
            let store = dictionary
            let actual = try store.readClosedDictionary().map(SyncRecord.init)
            guard same(actual, application.before) else { return nil }
            try application.after.forEach { try $0.entry.validate() }
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
    func tick(force: Bool = false) async {
        precondition(Thread.isMainThread)
        guard !busy, defaults.bool(forKey: "SyncStarted"), force || ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        busy = true; defer { busy = false; NotificationCenter.default.post(name: Self.changed, object: nil) }
        do {
            try await ensureStarted(); let status = try await request(["action": "status"])
            guard status["enabled"] as? Bool == true, Engine.ready, !InputSession.hasComposition else { return }
            let remote = try JSONSerialization.data(withJSONObject: ["revision": status["revision"] ?? ""], options: .sortedKeys)
            guard force || lastError != nil || revision != QRimeLearningRevision() || remote != version || status["waiting_input"] as? Bool == true else { return }
            guard !InputSession.hasComposition else { return }
            var actual = try snapshot()
            var capturedRevision = QRimeLearningRevision()
            var pending = try job(await request(["action": "pending_apply", "rows": actual.map(\.object)]))
            if let value = pending, same(actual, value.after) {
                _ = try await request(["action": "acknowledge", "id": value.id, "rows": actual.map(\.object)]); pending = nil
                guard !InputSession.hasComposition else { return }
                actual = try snapshot(); capturedRevision = QRimeLearningRevision()
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
            revision = capturedRevision; version = remote; lastError = nil; retryAfter = 0
        } catch {
            lastError = error.localizedDescription + "\n30 秒后自动重试，也可点“立即同步”。"
            retryAfter = ProcessInfo.processInfo.systemUptime + 30
        }
    }
    func recoverLocal() async throws {
        guard !busy else { throw LexiconError.message("正在同步，请稍后重试。") }
        busy = true; defer { busy = false }
        guard let pending = try job(await request(["action": "pending_apply"])) else { return }
        let actual = try snapshot(), tag = UUID().uuidString
        try LexiconFiles.write(LexiconEntry.portable(actual.map(\.entry)), to: root.appendingPathComponent("backups/recovery-local-\(tag).tsv"))
        try LexiconFiles.write(LexiconEntry.portable(pending.after.map(\.entry)), to: root.appendingPathComponent("backups/recovery-target-\(tag).tsv"))
        _ = try await request(["action": "recover_local", "id": pending.id, "rows": actual.map(\.object)])
        revision = nil; version = nil; lastError = nil; retryAfter = 0
    }
    func leave() async throws {
        defaults.set(false, forKey: "SyncStarted")
        timer?.invalidate(); timer = nil
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        do { _ = try await request(["action": "leave"]); revision = nil; version = nil; lastError = nil; retryAfter = 0 }
        catch { markStarted(); throw error }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        // Only the exact child process created by this instance is terminated.
        // SQLite WAL and application jobs provide recovery after interruption.
        if helper?.isRunning == true { helper?.terminate() }
    }
}
