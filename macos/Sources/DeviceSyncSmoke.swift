import AppKit
import QRimeBridge

// Only entered by an explicit CLI option in an independently identified preview
// bundle. Every node owns a fresh root, defaults suite and real librime engine.
@MainActor enum DeviceSyncSmoke {
    static func wait<T>(_ action: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { do { result = .success(try await action()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return try result!.get()
    }

    static func node(root: URL) throws {
        guard root.lastPathComponent.hasPrefix("node-"),
              FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("mac-sync-test-only").path),
              root.resolvingSymlinksInPath().path != Product.userRoot.resolvingSymlinksInPath().path else {
            throw LexiconError.message("Native sync tests require an isolated test root.")
        }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "com.asmoyou.rimeq.sync-test." + root.deletingLastPathComponent().lastPathComponent + "." + root.lastPathComponent
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.synchronize() } // Driver removes this exact suite even after forced termination.
        let dictionary = PersonalDictionary(root: root)
        let sync = DeviceSync(root: root, defaults: defaults, dictionary: dictionary, isolated: true)
        try Engine.start(user: root.appendingPathComponent("rime")); Engine.ready = true
        let client = MockTextClient(), controller = InputSession()
        controller.activate(client)
        defer { sync.stop(); controller.deactivate(client); Engine.ready = false; QRimeStop() }
        func type(_ text: String) throws {
            for character in text {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: character == "\u{1b}" ? 53 : 0)!
                if !controller.process(event, client: client) {
                    try EngineSmoke.check(!InputSession.hasComposition && character != "\u{1b}", "native controller rejected test input")
                    // The controlled host inserts keys passed through in ASCII mode.
                    client.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
        }
        func replace(_ rows: [SyncRecord]) throws {
            let actual = try dictionary.entries()
            let retained = Set(rows.map { $0.entry.id })
            let removed = actual.filter { !retained.contains($0.id) }
            if !removed.isEmpty { _ = try dictionary.delete(removed) }
            for row in rows {
                if let before = actual.first(where: { $0.id == row.entry.id }), before.weight > row.weight {
                    _ = try dictionary.delete([before])
                }
                _ = try dictionary.merge([row.entry])
            }
        }
        func output(_ value: [String: Any]) throws {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            print("RIMEQ-SYNC-TEST " + String(decoding: bytes, as: UTF8.self)); fflush(stdout)
        }
        try output(["ready": true])
        while let line = readLine() {
            do {
                let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let action = command["action"] as? String ?? ""
                if action == "quit" { return }
                var response: [String: Any] = [:]
                switch action {
                case "tick":
                    defaults.set(true, forKey: "SyncStarted")
                    try wait { await sync.tick(force: command["force"] as? Bool ?? true) }
                    response = ["error": sync.lastError as Any? ?? NSNull(), "composition": InputSession.hasComposition, "document": client.document,
                                "progress": sync.progressText(["enabled": true])]
                case "preference": response = ["started": defaults.bool(forKey: "SyncStarted")]
                case "disabled":
                    defaults.set(false, forKey: "SyncStarted")
                    try wait { await sync.tick() }
                    response = ["control_exists": FileManager.default.fileExists(atPath: sync.root.appendingPathComponent("control.json").path)]
                case "startup_ui":
                    try wait { try await DeviceSyncWindow(sync: sync).validateUnusedForSmoke() }
                    let failureRoot = root.appendingPathComponent("failed-start")
                    let failureSyncRoot = failureRoot.appendingPathComponent("sync")
                    try FileManager.default.createDirectory(at: failureSyncRoot, withIntermediateDirectories: true)
                    let stub = failureRoot.appendingPathComponent("helper")
                    try "#!/bin/sh\nif [ \"$1\" = serve ]; then printf x >> \"$3/attempts\"; fi\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
                    let failed = DeviceSync(root: failureRoot, defaults: defaults, dictionary: dictionary, executable: stub, isolated: true)
                    defer { failed.stop(); defaults.set(false, forKey: "SyncStarted") }
                    defaults.set(true, forKey: "SyncStarted")
                    try wait {
                        for _ in 0..<3 { do { _ = try await failed.displayStatus() } catch {} }
                        let attempts = failureSyncRoot.appendingPathComponent("attempts")
                        try EngineSmoke.check(try String(contentsOf: attempts) == "x", "failed helper restarted during polling")
                        do { try await failed.ensureStarted(retry: true) } catch {}
                        try EngineSmoke.check(try String(contentsOf: attempts) == "xx", "explicit retry did not restart helper")
                    }
                case "rows": response = ["rows": try dictionary.entries().map { SyncRecord($0).object }]
                case "replace":
                    let rows = try JSONDecoder().decode([SyncRecord].self, from: JSONSerialization.data(withJSONObject: command["rows"]!))
                    try replace(rows)
                case "native_import", "native_delete":
                    let rows = try JSONDecoder().decode([SyncRecord].self, from: JSONSerialization.data(withJSONObject: command["rows"]!))
                    try rows.forEach { try $0.entry.validate() }
                    if action == "native_delete" { _ = try dictionary.delete(rows.map(\.entry)) }
                    else {
                        try Engine.maintain {
                            let file = root.appendingPathComponent("synthetic-native.tsv")
                            try LexiconFiles.write(LexiconEntry.portable(rows.map(\.entry)), to: file)
                            try EngineSmoke.check(QRimeImportPersonalDictionary(file.path) >= 0, "native learning fixture import failed")
                        }
                    }
                case "begin": try type("nihao")
                case "cancel": try type("\u{1b}")
                case "type": try type(command["text"] as! String); response = ["document": client.document]
                case "english": controller.toggleEnglish()
                case "hook":
                    let after = command["after"] as! String, effect = command["effect"] as! String
                    let hook: (String) throws -> Void = { action in
                        guard action == after else { return }
                        sync.afterRequest = nil; sync.beforeRequest = nil
                        switch effect {
                        case "begin": try type("nihao")
                        case "learn", "learn_again":
                            _ = try dictionary.merge([.init(text: "异步学习", code: "yi bu xue xi", weight: effect == "learn" ? 7 : 11)])
                        case "fail": throw LexiconError.message("Injected IPC interruption")
                        default: break
                        }
                    }
                    if command["before"] as? Bool == true { sync.beforeRequest = hook } else { sync.afterRequest = hook }
                case "ui":
                    try wait { try await DeviceSyncWindow(sync: sync).validateForSmoke(destination: root.appendingPathComponent("sync-window.png")) }
                case "recover": try wait { try await sync.recoverLocal() }
                case "leave": try wait { try await sync.leave() }
                case "undo": _ = try dictionary.undo()
                case "candidates": response = ["candidates": try DictionarySmoke.candidates(command["code"] as! String)]
                default: throw LexiconError.message("Unknown native test command")
                }
                try output(["ok": true, "result": response])
            } catch { try output(["ok": false, "error": error.localizedDescription]) }
        }
    }
}
