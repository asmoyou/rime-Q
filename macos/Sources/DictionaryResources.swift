import Foundation
import CryptoKit
import QRimeBridge

struct BundledDictionary: Codable, Identifiable {
    let id: String
    let name: String
    let file: String
    let count: Int
    let bytes: Int
    let sha256: String
    let source: String
    let version: String
    let license: String
    let optional: Bool
    let kind: String
}

struct ImportedDictionary: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let originalName: String
    let version: String
    let source: String
    let license: String
    let sha256: String
    let count: Int
    let bytes: Int
    var enabled: Bool
}

struct DictionaryConfiguration: Codable, Equatable {
    var format = 1
    var generation: String?
    var disabled: Set<String> = []
    var imported: [ImportedDictionary] = []
}

struct DictionaryImport {
    let original: Data
    let originalName: String
    let name: String
    let version: String
    let entries: [LexiconEntry]

    static func read(_ url: URL) throws -> Self {
        let original = try LexiconFiles.data(url)
        let text = try LexiconFiles.decode(original)
        let lines = text.components(separatedBy: .newlines)
        var name = url.deletingPathExtension().lastPathComponent
        var version = "未注明"
        var columns = ["text", "code", "weight"]
        var start = 0
        if url.lastPathComponent.lowercased().hasSuffix(".dict.yaml") {
            guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }), end < 1000 else {
                throw LexiconError.message("Rime 词表缺少以 ... 结束的 YAML 文件头。")
            }
            let header = lines[..<end].joined(separator: "\n")
            guard header.utf8.count <= 65536, QRimeParseDictionaryHeader(header) else {
                throw LexiconError.message("请选择包含实际词条的独立 Rime 词表。当前不支持仅引用其他词表的 import_tables 合集。")
            }
            name = String(cString: QRimeDictionaryName())
            let declared = String(cString: QRimeDictionaryVersion())
            if !declared.isEmpty { version = declared }
            columns = String(cString: QRimeDictionaryColumns()).components(separatedBy: "\t")
            start = end + 1
        } else if !["tsv", "txt"].contains(url.pathExtension.lowercased()) {
            throw LexiconError.message("支持 UTF-8 的 .dict.yaml 或 TSV 词表；请先将搜狗 SCEL 等二进制词库转换为全拼文本。")
        }
        guard let textColumn = columns.firstIndex(of: "text"), let codeColumn = columns.firstIndex(of: "code"),
              Set(columns).count == columns.count, columns.allSatisfy({ ["text", "code", "weight", "stem"].contains($0) }) else {
            throw LexiconError.message("第三方词表需要明确的词条与全拼列（text、code）。不支持声调、双拼或无注音词表。")
        }
        var unique: [String: LexiconEntry] = [:]
        for index in start..<lines.count {
            let line = lines[index].trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count > max(textColumn, codeColumn), parts.count <= columns.count else {
                throw LexiconError.message("第 \(index + 1) 行缺少词条或拼音，或含有多余的列。")
            }
            let value = columns.firstIndex(of: "weight").flatMap { parts.indices.contains($0) ? parts[$0] : nil } ?? "100"
            let number = Double(value.isEmpty ? "100" : value)
            guard let number, number.isFinite, number >= 0, number < Double(Int32.max) else {
                throw LexiconError.message("第 \(index + 1) 行的词频必须是非负数，不支持百分比词频。")
            }
            let entry: LexiconEntry
            do {
                entry = try .draft(text: parts[textColumn], code: parts[codeColumn], weight: Int(number))
                try entry.validateFullPinyin()
            }
            catch { throw LexiconError.message("第 \(index + 1) 行：\(error.localizedDescription)") }
            if let prior = unique[entry.id], prior.weight >= entry.weight { continue }
            unique[entry.id] = entry
            guard unique.count <= 500_000 else { throw LexiconError.message("单个第三方词库最多支持 50 万条记录。") }
        }
        guard !unique.isEmpty else { throw LexiconError.message("没有找到带全拼编码的词条。") }
        return .init(original: original, originalName: url.lastPathComponent, name: name, version: version,
                     entries: unique.values.sorted { $0.id < $1.id })
    }
}

final class DictionaryResources {
    static let shared = DictionaryResources(root: Product.userRoot)
    let root: URL
    let bundled: URL
    let catalog: [BundledDictionary]
    private(set) var configuration: DictionaryConfiguration
    private(set) var loadingError: String?
    private(set) var configurationReadable = true
    private(set) var busy = false
    var directory: URL { root.appendingPathComponent("dictionaries") }
    var manifest: URL { directory.appendingPathComponent("configuration.json") }
    func reportUnavailable(_ reason: String) { loadingError = reason }

    init(root: URL, bundled: URL = Engine.bundledShared) {
        self.root = root
        self.bundled = bundled.resolvingSymlinksInPath()
        let catalogURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dictionaries.json")
        catalog = (try? JSONDecoder().decode([BundledDictionary].self, from: Data(contentsOf: catalogURL))) ?? []
        configuration = .init()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("dictionaries/configuration.json").path) {
            do {
                let data = try Data(contentsOf: root.appendingPathComponent("dictionaries/configuration.json"))
                let loaded = try JSONDecoder().decode(DictionaryConfiguration.self, from: data)
                try Self.validate(loaded, catalog: catalog, persisted: true)
                configuration = loaded
            } catch { configurationReadable = false; loadingError = "词库配置读取失败。原文件已保留：\(error.localizedDescription)" }
        }
    }

    static func validate(_ config: DictionaryConfiguration, catalog: [BundledDictionary], persisted: Bool = false) throws {
        guard config.format == 1, config.generation.map({ UUID(uuidString: $0) != nil }) ?? true,
              config.disabled.isSubset(of: Set(catalog.filter(\.optional).map(\.id))),
              Set(config.imported.map(\.id)).count == config.imported.count,
              config.imported.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.name.isEmpty }) else {
            throw LexiconError.message("词库配置格式或版本不受支持。")
        }
        if persisted, config.generation == nil, !config.disabled.isEmpty || config.imported.contains(where: \.enabled) {
            throw LexiconError.message("词库启用配置缺少对应的编译资源。")
        }
    }

    func activeResources() throws -> URL {
        if let loadingError { throw LexiconError.message(loadingError) }
        // A historical "apply" with no customizations must not freeze the
        // input schema at the version installed at that time.
        if configuration.disabled.isEmpty && !configuration.imported.contains(where: \.enabled) { return bundled }
        guard let generation = configuration.generation else { return bundled }
        let resource = directory.appendingPathComponent("generations/\(generation)")
        guard FileManager.default.fileExists(atPath: resource.appendingPathComponent("build/rime_ice.table.bin").path) else {
            throw LexiconError.message("已启用的词库编译文件缺失。请在词库管理中重新应用配置。")
        }
        return resource
    }

    private func bundledConfigurationFingerprint() throws -> String {
        var hash = SHA256()
        for name in ["rime_q.schema.yaml", "rime_q_grammar.schema.yaml", "rime_ice.schema.yaml", "default.yaml", "default.custom.yaml", "lua/q_lunar.lua", "lua/q_corrector.lua"] {
            hash.update(data: try Data(contentsOf: bundled.appendingPathComponent(name)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Upgrade schemas in a new generation while the existing dictionaries
    /// continue serving input. apply() waits for composition to finish and
    /// retains the previous generation and personal learning on failure.
    @discardableResult
    func refreshBundledConfigurationIfNeeded(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) -> Bool {
        guard !busy, configurationReadable, let generation = configuration.generation,
              !configuration.disabled.isEmpty || configuration.imported.contains(where: \.enabled),
              let fingerprint = try? bundledConfigurationFingerprint() else { return false }
        let marker = directory.appendingPathComponent("generations/\(generation)/.rimeq-input-config")
        if (try? String(contentsOf: marker)) == fingerprint { return false }
        InstallationDiagnostics.append("bundled-input-configuration-refresh-begin")
        apply(configuration) { result in
            if case .success = result { InstallationDiagnostics.append("bundled-input-configuration-refresh-complete") }
            else { InstallationDiagnostics.append("bundled-input-configuration-refresh-failed; retained-previous-generation") }
            completion(result)
        }
        return true
    }

    func importedURL(_ entry: ImportedDictionary, original: Bool = false) -> URL {
        directory.appendingPathComponent("imports/\(entry.id).\(original ? "source" : "tsv")")
    }

    func adding(_ draft: DictionaryImport, name: String, source: String, license: String) throws -> DictionaryConfiguration {
        guard !busy, configurationReadable else { throw LexiconError.message(loadingError ?? "正在应用词库，请稍候。") }
        let id = UUID().uuidString
        let entry = ImportedDictionary(id: id, name: name.isEmpty ? draft.name : name, originalName: draft.originalName,
            version: draft.version, source: source.isEmpty ? "本地导入：\(draft.originalName)" : source,
            license: license.isEmpty ? "未注明，原始声明随源文件保留" : license,
            sha256: SHA256.hash(data: draft.original).map { String(format: "%02x", $0) }.joined(),
            count: draft.entries.count, bytes: draft.original.count, enabled: true)
        guard !configuration.imported.contains(where: { $0.sha256 == entry.sha256 }) else {
            throw LexiconError.message("此词库已经导入，可在列表中启用它。")
        }
        try LexiconFiles.write(draft.original, to: importedURL(entry, original: true))
        try LexiconFiles.write(draft.entries.map(\.tsv).joined(separator: "\n") + "\n", to: importedURL(entry))
        var updated = configuration
        updated.imported.append(entry)
        return updated
    }

    // Prepare a new immutable generation while typing continues with the old
    // resources. Only a successful helper build is switched into the live engine.
    func apply(_ proposed: DictionaryConfiguration, progress: @escaping (String) -> Void = { _ in },
               completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy, configurationReadable else {
            completion(.failure(LexiconError.message(loadingError ?? "正在应用词库，请稍候。"))); return
        }
        do { try Self.validate(proposed, catalog: catalog) }
        catch { completion(.failure(error)); return }
        busy = true
        let old = configuration
        var next = proposed
        next.generation = UUID().uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error> = Result { try self.compile(next) }
            DispatchQueue.main.async {
                let activate = {
                    self.busy = false
                    do {
                        let resources = try result.get()
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(next)
                        try Engine.useResources(resources) { try LexiconFiles.write(data, to: self.manifest) }
                        self.configuration = next
                        self.loadingError = nil
                        // Keep the previous generation as a recovery copy. Remove
                        // only older generated resources, never learning data.
                        self.pruneGenerations(keeping: Set([old.generation, next.generation].compactMap { $0 }))
                        completion(.success(()))
                    } catch {
                        if let id = next.generation { try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("generations/\(id)")) }
                        let existing = Set(old.imported.map(\.id))
                        for added in next.imported where !existing.contains(added.id) {
                            try? FileManager.default.removeItem(at: self.importedURL(added))
                            try? FileManager.default.removeItem(at: self.importedURL(added, original: true))
                        }
                        completion(.failure(error))
                    }
                }
                switch result {
                case .success:
                    if InputSession.hasComposition { progress("编译完成，等待当前输入结束后生效…") }
                    Engine.whenInputFinished(activate)
                case .failure: activate()
                }
            }
        }
    }

    func restoreBundled() throws {
        guard !busy else { throw LexiconError.message("正在应用词库，请稍候。") }
        if FileManager.default.fileExists(atPath: manifest.path) {
            try LexiconFiles.write(Data(contentsOf: manifest), to: directory.appendingPathComponent("configuration-backup-\(UUID().uuidString).json"))
        }
        var restored = configuration
        restored.generation = nil; restored.disabled = []
        restored.imported = restored.imported.map { var entry = $0; entry.enabled = false; return entry }
        try Engine.useResources(bundled) { try LexiconFiles.write(JSONEncoder().encode(restored), to: manifest) }
        configuration = restored; configurationReadable = true; loadingError = nil
    }

    private func compile(_ config: DictionaryConfiguration) throws -> URL {
        guard let id = config.generation, let executable = Bundle.main.executableURL else {
            throw LexiconError.message("无法启动词库编译器。")
        }
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("generations/\(id)")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for item in try fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)
            where !["build", "rime_ice.dict.yaml"].contains(item.lastPathComponent) {
            try fm.createSymbolicLink(at: destination.appendingPathComponent(item.lastPathComponent), withDestinationURL: item)
        }
        try fm.copyItem(at: bundled.appendingPathComponent("build"), to: destination.appendingPathComponent("build"))
        for name in ["rime_ice.table.bin", "rime_ice.reverse.bin", "rime_ice.prism.bin", "rime_q.schema.yaml", "rime_q_grammar.schema.yaml"] {
            try fm.removeItem(at: destination.appendingPathComponent("build/\(name)"))
        }
        let original = try String(contentsOf: bundled.appendingPathComponent("rime_ice.dict.yaml"), encoding: .utf8)
        guard let separator = original.range(of: "\n...\n") else { throw LexiconError.message("内置词库文件头损坏。") }
        var tables = ["cn_dicts/8105", "cn_dicts/base", "cn_dicts/ext", "cn_dicts/tencent", "cn_dicts/others"]
            .filter { !config.disabled.contains($0) }
        for entry in config.imported where entry.enabled {
            let contents = try LexiconFiles.text(importedURL(entry))
            let name = "q_import_" + entry.id.replacingOccurrences(of: "-", with: "").lowercased()
            let header = "---\nname: \(name)\nversion: '1'\nsort: by_weight\ncolumns: [text, code, weight]\n...\n"
            try LexiconFiles.write(header + contents, to: destination.appendingPathComponent(name + ".dict.yaml"))
            tables.append(name)
        }
        let header = "# Generated by Rime Q; originals and attribution are retained.\n---\nname: rime_ice\nversion: '\(id)'\nimport_tables:\n"
            + tables.map { "  - \($0)" }.joined(separator: "\n") + "\n...\n"
        try LexiconFiles.write(header + original[separator.upperBound...], to: destination.appendingPathComponent("rime_ice.dict.yaml"))
        try LexiconFiles.write("Rime Q dictionary generation\n", to: destination.appendingPathComponent(".rimeq-generation"))
        let log = destination.appendingPathComponent("compile.log")
        fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--compile-dictionaries", destination.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fm.homeDirectoryForCurrentUser.path,
                               "TMPDIR": fm.temporaryDirectory.path, "LANG": "en_US.UTF-8"]
        process.standardOutput = output; process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? LexiconFiles.write(Data(contentsOf: log), to: directory.appendingPathComponent("last-compile.log"))
            throw LexiconError.message("词库编译失败，已继续使用原词库。请检查文件中的全拼编码和词频。")
        }
        try LexiconFiles.write(bundledConfigurationFingerprint(), to: destination.appendingPathComponent(".rimeq-input-config"))
        return destination
    }

    static func compileHelper(_ destination: URL) throws {
        let fm = FileManager.default
        guard UUID(uuidString: destination.lastPathComponent) != nil,
              destination.deletingLastPathComponent().lastPathComponent == "generations",
              fm.fileExists(atPath: destination.appendingPathComponent(".rimeq-generation").path) else {
            throw LexiconError.message("词库编译目标无效。")
        }
        let user = fm.temporaryDirectory.appendingPathComponent("rimeq-dictionary-build-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: user) }
        try Engine.start(user: user, deploy: true, shared: destination)
        defer { QRimeStop() }
        let compiled = user.appendingPathComponent("build")
        for name in ["rime_ice.table.bin", "rime_ice.reverse.bin", "rime_ice.prism.bin", "rime_q.schema.yaml", "rime_q_grammar.schema.yaml"] {
            guard (try? compiled.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 else {
                throw LexiconError.message("未能生成完整的词库：\(name)")
            }
        }
        // Both schemas were compiled above; validate base input without fetching
        // an optional model into this temporary compiler's user directory.
        for schema in ["rime_q"] {
            let session = QRimeCreateSession()
            defer { QRimeDestroySession(session) }
            guard QRimeSchema(session, schema) else { throw LexiconError.message("输入方案未能加载。") }
            QRimeSetOption(session, "ascii_mode", false)
            for c in "nihao".utf8 { _ = QRimeProcess(session, Int32(c), 0) }
            guard QRimeRead(session), (0..<QRimeCandidateCount()).contains(where: { String(cString: QRimeCandidateText($0)) == "你好" }) else {
                throw LexiconError.message("新词库未通过基础输入验证。")
            }
            QRimeClear(session)
        }
        let existing = destination.appendingPathComponent("build")
        // Maintenance emits only rebuilt files. Retain unchanged prebuilt
        // English/radical indexes and default config from the bundled seed.
        for file in try fm.contentsOfDirectory(at: compiled, includingPropertiesForKeys: nil) {
            let target = existing.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: file, to: target)
        }
        for dictionary in ["rime_ice", "melt_eng", "radical_pinyin"] {
            for suffix in ["table.bin", "prism.bin", "reverse.bin"] {
                guard (try? existing.appendingPathComponent("\(dictionary).\(suffix)").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 else {
                    throw LexiconError.message("词库索引不完整：\(dictionary).\(suffix)")
                }
            }
        }
        print("PASS dictionary compilation: both Chinese schemas compiled, base input and complete English/radical indexes verified")
    }

    private func pruneGenerations(keeping ids: Set<String>) {
        let generations = directory.appendingPathComponent("generations")
        for url in (try? FileManager.default.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil)) ?? []
            where UUID(uuidString: url.lastPathComponent) != nil && !ids.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
