import Foundation
import QRimeBridge

enum LexiconError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum LexiconFiles {
    static func data(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= limit else {
            throw LexiconError.message("请选择不超过 \(limit / 1024 / 1024) MB 的文本词库文件。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw LexiconError.message("词库文件超过大小限制。") }
        return data
    }
    static func decode(_ data: Data) throws -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            throw LexiconError.message("词库必须是 UTF-8 编码的文本文件。")
        }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        return text
    }
    static func text(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> String {
        try decode(data(url, limit: limit))
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Atomic replacement never writes through a destination symlink.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct LexiconEntry: Codable, Equatable, Identifiable {
    let text: String
    let code: String
    let weight: Int
    var id: String { code + "\t" + text }
    var tsv: String { "\(text)\t\(code)\t\(weight)" }
    private static let syllables: Set<String> = {
        let url = Engine.bundledShared.appendingPathComponent("cn_dicts/8105.dict.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").flatMap { line -> [String] in
            let parts = line.split(separator: "\t")
            return parts.count >= 2 ? parts[1].split(separator: " ").map(String.init) : []
        })
    }()
    func validateFullPinyin() throws {
        try validate()
        guard code.split(separator: " ").allSatisfy({ $0.count <= 16 && (Self.syllables.contains(String($0)) || $0.utf8.allSatisfy { (65...90).contains($0) }) }) else {
            throw LexiconError.message("拼音中有无法识别的音节。请使用不带声调的全拼，并用空格分隔，例如 shu ru fa。")
        }
    }

    static func draft(text: String, code: String, weight: Int = 1) throws -> Self {
        let normalized = code.replacingOccurrences(of: "ü", with: "v")
            .replacingOccurrences(of: "'", with: " ").split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let entry = Self(text: text.trimmingCharacters(in: .whitespaces), code: normalized, weight: weight)
        try entry.validate()
        return entry
    }

    func validate() throws {
        guard !text.isEmpty, !text.hasPrefix("#"), text.utf8.count <= 1024,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !code.isEmpty, code.utf8.count <= 1024, weight >= 0, weight < Int(Int32.max),
              code.split(separator: " ").allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) }
              }), code.utf8.allSatisfy({ $0 == 32 || (97...122).contains($0) || (65...90).contains($0) }) else {
            throw LexiconError.message("词条不能为空；拼音请按音节用空格分隔，不带声调，例如 xing he ci ku。权重须为非负整数。")
        }
    }

    static func parsePersonal(_ text: String, allowEmpty: Bool = true) throws -> [Self] {
        var result: [String: Self] = [:]
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix("#@/db_name\t"), line != "#@/db_name\trime_q" {
                throw LexiconError.message("此文件属于其他输入方案，请导入 Rime Q 的全拼学习词库。")
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "\t")
            guard (2...3).contains(parts.count), let weight = Int(parts.count == 3 ? parts[2] : "1") else {
                throw LexiconError.message("第 \(index + 1) 行格式不正确。需要：词条、拼音、可选学习权重，以制表符分隔。")
            }
            let entry = try Self.draft(text: parts[0], code: parts[1], weight: weight)
            if let previous = result[entry.id], previous.weight > entry.weight { continue }
            result[entry.id] = entry
            guard result.count <= 200_000 else { throw LexiconError.message("一次最多导入 20 万条个人记录。") }
        }
        guard allowEmpty || !result.isEmpty else { throw LexiconError.message("文件中没有可导入的词条。") }
        return result.values.sorted { $0.id < $1.id }
    }

    static func portable(_ entries: [Self]) -> String {
        "# Rime Q personal dictionary export\n#@/db_name\trime_q\n# 词条\t全拼（空格分隔）\t学习权重\n"
            + entries.map(\.tsv).joined(separator: "\n") + "\n"
    }
}

struct PersonalChange {
    let before: [LexiconEntry]
    let after: [LexiconEntry]
    var ids: Set<String> { Set((before + after).map(\.id)) }
    func check(_ current: [LexiconEntry]) throws {
        let actual = current.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
        guard actual == before.sorted(by: { $0.id < $1.id }) else {
            throw LexiconError.message("这些词条在上次读取后已有新的学习或修改。请刷新列表后重试，避免覆盖新记录。")
        }
    }
}

// Uses librime's supported levers API, never opens or rewrites a live LevelDB.
// A refreshed snapshot is compared before editing; only affected rows change.
final class PersonalDictionary {
    static let shared = PersonalDictionary(root: Product.userRoot)
    let root: URL
    private(set) var lastChange: PersonalChange?
    var backupURL: URL { root.appendingPathComponent("lexicon-backups/before-last-change.tsv") }
    init(root: URL) { self.root = root }

    func entries() throws -> [LexiconEntry] {
        try Engine.maintain { try readClosedDictionary() }
    }

    func readClosedDictionary() throws -> [LexiconEntry] {
        let state = QRimePersonalDictionaryState()
        guard state >= 0 else { throw LexiconError.message("当前引擎未提供个人词库管理接口。") }
        if state == 0 { return [] }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-lexicon-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: file) }
        try LexiconFiles.write("", to: file)
        let count = QRimeExportPersonalDictionary(file.path)
        guard count >= 0 else { throw LexiconError.message("个人学习记录读取失败。原始数据仍保留，请稍后重试。") }
        let records = try LexiconEntry.parsePersonal(LexiconFiles.text(file))
        guard records.count == count else { throw LexiconError.message("个人词库导出不完整，已停止操作。") }
        return records
    }

    func save(_ entry: LexiconEntry, replacing original: LexiconEntry?) throws -> [LexiconEntry] {
        try entry.validateFullPinyin()
        let saved = LexiconEntry(text: entry.text, code: entry.code, weight: max(1, original?.weight ?? 1))
        return try apply(.init(before: original.map { [$0] } ?? [], after: [saved]))
    }

    func delete(_ entries: [LexiconEntry]) throws -> [LexiconEntry] {
        guard !entries.isEmpty else { throw LexiconError.message("请先选择词条。") }
        return try apply(.init(before: entries, after: []))
    }

    func merge(_ imported: [LexiconEntry]) throws -> [LexiconEntry] {
        try imported.forEach { try $0.validateFullPinyin() }
        return try Engine.maintain {
            let current = try readClosedDictionary()
            let incoming = Set(imported.map(\.id))
            let originals = current.filter { incoming.contains($0.id) }
            let byID = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
            let changed = imported.map {
                LexiconEntry(text: $0.text, code: $0.code, weight: max(1, $0.weight, byID[$0.id]?.weight ?? 0))
            }
            return try applyClosed(.init(before: originals, after: changed), current: current)
        }
    }

    func undo() throws -> [LexiconEntry] {
        guard let change = lastChange else { throw LexiconError.message("当前没有可以撤销的修改。") }
        let restored = change.before.map { LexiconEntry(text: $0.text, code: $0.code, weight: max(1, $0.weight)) }
        let entries = try apply(.init(before: change.after, after: restored))
        lastChange = nil
        return entries
    }

    private func apply(_ change: PersonalChange) throws -> [LexiconEntry] {
        try Engine.maintain { try applyClosed(change, current: readClosedDictionary()) }
    }

    private func applyClosed(_ change: PersonalChange, current: [LexiconEntry]) throws -> [LexiconEntry] {
        try change.check(current)
        try LexiconFiles.write(LexiconEntry.portable(current), to: backupURL)
        let retained = Set(change.after.map(\.id))
        // librime's importer merges weights by max; -1 removes a learned row.
        // Add replacements first so a partial import cannot lose the only copy.
        let previous = Dictionary(uniqueKeysWithValues: change.before.map { ($0.id, $0.weight) })
        // Undo of a bulk weight increase needs a deletion marker immediately
        // followed by restoration; the importer otherwise only raises weights.
        let resets = change.after.filter { (previous[$0.id] ?? 0) > $0.weight }
            .map { "\($0.text)\t\($0.code)\t-1" }
        let rows = resets + change.after.map(\.tsv) + change.before.filter { !retained.contains($0.id) }
            .map { "\($0.text)\t\($0.code)\t-1" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-lexicon-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: file) }
        try LexiconFiles.write(rows.joined(separator: "\n") + "\n", to: file)
        let count = QRimeImportPersonalDictionary(file.path)
        let actual = try readClosedDictionary()
        let observed = actual.filter { change.ids.contains($0.id) }
        lastChange = .init(before: change.before, after: observed)
        guard count >= 0, observed.sorted(by: { $0.id < $1.id }) == change.after.sorted(by: { $0.id < $1.id }) else {
            throw LexiconError.message("修改未能完整完成。已保留修改前的备份，可刷新后撤销或恢复备份。")
        }
        return actual
    }
}
