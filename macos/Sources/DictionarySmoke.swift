import AppKit
import QRimeBridge

enum DictionarySmoke {
    static func candidates(_ code: String, schema: String = "rime_q") throws -> [String] {
        let session = QRimeCreateSession()
        defer { QRimeDestroySession(session) }
        try EngineSmoke.check(session != 0 && QRimeSchema(session, schema), "test schema missing")
        QRimeSetOption(session, "ascii_mode", false)
        EngineSmoke.type(code, session: session)
        try EngineSmoke.check(QRimeRead(session), "candidate snapshot failed")
        let result = (0..<QRimeCandidateCount()).map { String(cString: QRimeCandidateText($0)) }
        QRimeClear(session)
        return result
    }

    static func reject(_ action: () throws -> Void, _ message: String) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try EngineSmoke.check(rejected, message)
    }

    static func personal() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-personal-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("rime")
        try Engine.start(user: user); Engine.ready = true
        defer { Engine.ready = false; QRimeStop() }
        let store = PersonalDictionary(root: root)
        try EngineSmoke.check(try store.entries().isEmpty, "fresh personal dictionary is not empty")
        let original = try LexiconEntry.draft(text: "青岚松鼠学习", code: "qing lan song shu xue xi")
        let edited = try LexiconEntry.draft(text: "青岚松鼠学兮", code: original.code)
        var rows = try store.save(original, replacing: nil)
        try EngineSmoke.check(rows.contains(original), "new entry not exported")
        try EngineSmoke.check(try candidates("qinglansongshuxuexi").contains(original.text), "new entry not recalled")
        rows = try store.save(edited, replacing: original)
        try EngineSmoke.check(rows.contains(edited) && !rows.contains(original), "edit did not replace original")
        rows = try store.delete([edited])
        try EngineSmoke.check(!rows.contains(edited), "deleted entry still exported")
        rows = try store.undo()
        try EngineSmoke.check(rows.contains(edited), "undo did not restore entry")
        try EngineSmoke.check(try candidates("qinglansongshuxuexi", schema: "rime_q_grammar").contains(edited.text), "grammar mode lost edited entry")
        let raised = LexiconEntry(text: edited.text, code: edited.code, weight: 20)
        _ = try store.merge([raised])
        try reject({ _ = try store.save(original, replacing: edited) }, "stale edit overwrote newer learning")
        rows = try store.undo()
        try EngineSmoke.check(rows.contains(edited), "undo of imported weight failed")
        let portable = LexiconEntry.portable(rows)
        try EngineSmoke.check(try LexiconEntry.parsePersonal(portable) == rows.sorted(by: { $0.id < $1.id }), "TSV export did not round trip")
        try reject({ _ = try LexiconEntry.parsePersonal("#@/db_name\tother\n词\tci\t1\n") }, "cross-schema import accepted")
        try reject({ _ = try LexiconEntry.parsePersonal("词\tci\t-1\n") }, "bulk deletion marker accepted")
        try reject({ _ = try LexiconEntry.parsePersonal("broken line") }, "malformed input accepted")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.backupURL.path)[.posixPermissions] as? NSNumber
        try EngineSmoke.check(permissions?.intValue == 0o600, "backup is not private")

        // A settings read must settle preedit and recreate controller sessions.
        let client = MockTextClient(), controller = InputSession()
        controller.activate(client)
        func type(_ text: String) throws {
            for character in text {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!
                try EngineSmoke.check(controller.process(event, client: client), "controller could not accept key after maintenance")
            }
        }
        try type("nihao")
        var inputFinished = false
        Engine.whenInputFinished { inputFinished = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try EngineSmoke.check(!inputFinished && client.document.isEmpty, "background activation committed unfinished input")
        _ = try store.entries()
        try EngineSmoke.check(client.document == "你好" && client.preedit.isEmpty, "maintenance lost active preedit")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try EngineSmoke.check(inputFinished, "resource activation did not resume after composition ended")
        try type("zhongguo ")
        try EngineSmoke.check(client.document == "你好中国", "session was not recreated after personal dictionary read")
        controller.deactivate(client)
        QRimeStop(); try Engine.start(user: user)
        try EngineSmoke.check(try store.entries().contains(edited), "edited entry did not persist across engine restart")
        print("PASS personal dictionary: real librime CRUD, undo, TSV merge, stale edits, backup, both modes, maintenance sessions, persistence")
    }

    static func apply(_ store: DictionaryResources, _ config: DictionaryConfiguration) throws {
        var result: Result<Void, Error>?
        store.apply(config) { result = $0 }
        let deadline = Date().addingTimeInterval(600)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { throw LexiconError.message("dictionary test timed out") }
        try result.get()
    }

    static func resources() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-resources-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("rime")
        try Engine.start(user: user); Engine.ready = true
        defer { Engine.ready = false; QRimeStop() }
        let store = DictionaryResources(root: root), personal = PersonalDictionary(root: root)
        try EngineSmoke.check(store.catalog.count >= 8, "bundled resource catalog missing")
        try EngineSmoke.check(try candidates("hello").contains("hello"), "bundled English fixture unavailable")
        try EngineSmoke.check(try candidates("uUmumumu").contains("森"), "bundled radical fixture unavailable")
        let learned = try LexiconEntry.draft(text: "青岚松鼠学习", code: "qing lan song shu xue xi")
        _ = try personal.save(learned, replacing: nil)
        let fixture = root.appendingPathComponent("fixture.dict.yaml")
        try LexiconFiles.write("---\nname: fixture\nversion: '1.0'\ncolumns: [code, text, weight]\n...\nxing he ci ku\t星河词库甲乙\t900\nxing he ci ku\t星河词库甲乙\t800\n", to: fixture)
        let draft = try DictionaryImport.read(fixture)
        try EngineSmoke.check(draft.entries.count == 1 && draft.entries[0].weight == 900, "column ordering/deduplication failed")
        let invalid = root.appendingPathComponent("invalid.dict.yaml")
        try LexiconFiles.write("---\nname: invalid\nimport_tables: [unselected_file]\n...\n", to: invalid)
        try reject({ _ = try DictionaryImport.read(invalid) }, "dictionary collection accepted without dependencies")
        let malformed = root.appendingPathComponent("malformed.tsv")
        try LexiconFiles.write("测试\tnotapinyin\t100\n", to: malformed)
        try reject({ _ = try DictionaryImport.read(malformed) }, "unrecognized pinyin accepted")
        let bom = root.appendingPathComponent("bom.tsv")
        let originalBytes = Data("\u{feff}词库\tci ku\t100\r\n".utf8)
        try LexiconFiles.write(originalBytes, to: bom)
        try EngineSmoke.check(try DictionaryImport.read(bom).original == originalBytes, "original source bytes were changed")
        var config = try store.adding(draft, name: "集成测试词库", source: "synthetic fixture", license: "test only")
        config.disabled = ["cn_dicts/ext", "cn_dicts/tencent", "cn_dicts/others"]
        try EngineSmoke.check(try !candidates("xingheciku").contains("星河词库甲乙"), "fixture already in bundled dictionary")
        print("Compiling imported dictionary…")
        try apply(store, config)
        for schema in ["rime_q", "rime_q_grammar"] {
            try EngineSmoke.check(try candidates("xingheciku", schema: schema).contains("星河词库甲乙"), "import not active in \(schema)")
            try EngineSmoke.check(try candidates("hello", schema: schema).contains("hello"), "resource update lost English dictionary in \(schema)")
            try EngineSmoke.check(try candidates("uUmumumu", schema: schema).contains("森"), "resource update lost radical lookup in \(schema)")
        }
        try EngineSmoke.check(try personal.entries().contains(learned), "resource switch lost learning")
        let reopened = DictionaryResources(root: root)
        try EngineSmoke.check(reopened.configuration == store.configuration, "resource manifest did not persist")
        QRimeStop(); try Engine.start(user: user, shared: reopened.activeResources())
        try EngineSmoke.check(try candidates("xingheciku").contains("星河词库甲乙"), "import not recalled after restart")
        var disabled = store.configuration; disabled.imported[0].enabled = false
        print("Compiling disabled dictionary…")
        try apply(store, disabled)
        try EngineSmoke.check(try !candidates("xingheciku").contains("星河词库甲乙"), "disabled import still supplied candidates")
        try EngineSmoke.check(try candidates("hello").contains("hello"), "disabling import lost English dictionary")
        try EngineSmoke.check(try candidates("uUmumumu").contains("森"), "disabling import lost radical lookup")
        // Deliberately break a stored source. Failure must retain both the
        // current runtime and the last committed configuration.
        let stable = store.configuration
        var failed = stable; failed.imported[0].enabled = true
        let source = store.importedURL(failed.imported[0])
        try FileManager.default.removeItem(at: source)
        try reject({ try apply(store, failed) }, "missing source unexpectedly applied")
        try EngineSmoke.check(store.configuration == stable, "failed compile changed manifest")
        try EngineSmoke.check(try candidates("nihao").contains("你好"), "failed compile interrupted input")
        try store.restoreBundled()
        try EngineSmoke.check(try personal.entries().contains(learned), "restore bundled lost personal records")
        try EngineSmoke.check(store.configuration.generation == nil, "restore bundled left managed generation active")
        print("PASS dictionary resources: real compile, import, both modes, disable, restart, failure rollback, learning retained")
    }
}
