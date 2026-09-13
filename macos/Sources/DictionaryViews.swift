import AppKit
import UniformTypeIdentifiers

enum SettingsUI {
    static func label(_ text: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }
    static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.spacing = 8; stack.alignment = .centerY
        return stack
    }
    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }
    static func layout(_ views: [NSView], in parent: NSView) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -24)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    static func table(_ table: NSTableView, columns: [(String, String, CGFloat)]) -> NSScrollView {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = min(width, 70)
            table.addTableColumn(column)
        }
        table.rowHeight = 34; table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .inset
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder; scroll.documentView = table
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10; scroll.layer?.masksToBounds = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        return scroll
    }
    static func cell(_ text: String, table: NSTableView, id: String, secondary: Bool = false) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell = (table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        cell.toolTip = text
        return cell
    }
    static func error(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = "未能完成操作"; alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    static func confirm(_ title: String, detail: String, action: String, window: NSWindow?, perform: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: action)
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { perform() } }
        } else if alert.runModal() == .alertSecondButtonReturn { perform() }
    }
}

final class PersonalDictionaryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let store: PersonalDictionary
    private let table = NSTableView()
    private let search = NSSearchField()
    private let sort = NSPopUpButton()
    private let status = SettingsUI.label("正在读取…", secondary: true)
    private var all: [LexiconEntry] = []
    private var filtered: [LexiconEntry] = []
    private var loaded = false
    private var previewOnly = false
    private var editButton: NSButton!
    private var deleteButton: NSButton!
    private var undoButton: NSButton!
    private var exportButton: NSButton!
    private let emptyTitle = SettingsUI.label("还没有学习记录", size: 15)
    private let emptyNote = SettingsUI.label("日常选词后会逐渐积累，也可以手动新增。", size: 12, secondary: true)
    private var emptyView: NSView?
    private var syncWindow: DeviceSyncWindow?

    init(store: PersonalDictionary = .shared) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = SettingsBackgroundView()
        let title = SettingsLayout.heading("个人词库", subtitle: "整理选词时积累的学习记录。", action: SettingsUI.button("新增…", target: self, action: #selector(addEntry)))
        search.placeholderString = "搜索词条或拼音"; search.delegate = self
        search.setAccessibilityLabel("搜索个人学习记录")
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        sort.addItems(withTitles: ["按学习权重", "按词条", "按拼音"])
        sort.target = self; sort.action = #selector(filterRows)
        let refresh = SettingsUI.button("刷新", target: self, action: #selector(refresh))
        let tools = SettingsUI.row([search, sort, refresh, SettingsUI.button("附近设备同步…", target: self, action: #selector(showDeviceSync))])
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true
        table.target = self; table.doubleAction = #selector(editEntry)
        let scroll = SettingsUI.table(table, columns: [("text", "词条", 230), ("code", "全拼", 300), ("weight", "学习权重", 95)])
        table.tableColumns.last?.headerToolTip = "用于排序的参考值，包含导入权重，不等于实际输入次数。"
        emptyTitle.alignment = .center; emptyTitle.font = .systemFont(ofSize: 15, weight: .medium)
        emptyNote.alignment = .center
        let placeholder = SettingsLayout.vertical([emptyTitle, emptyNote], spacing: 8)
        scroll.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), placeholder.widthAnchor.constraint(equalToConstant: 340)])
        emptyView = placeholder; placeholder.isHidden = true
        editButton = SettingsUI.button("编辑…", target: self, action: #selector(editEntry))
        deleteButton = SettingsUI.button("删除…", target: self, action: #selector(deleteEntries))
        undoButton = SettingsUI.button("撤销上次修改", target: self, action: #selector(undo))
        exportButton = SettingsUI.button("导出…", target: self, action: #selector(exportEntries))
        let actions = SettingsUI.row([editButton, deleteButton,
            undoButton, NSView(), SettingsUI.button("导入…", target: self, action: #selector(importEntries)), exportButton])
        let note = SettingsUI.label("学习权重不等于输入次数。删除仅移除个人记录，内置同名词仍可能出现。", size: 11, secondary: true)
        let bottom = SettingsUI.row([status, NSView(), SettingsUI.button("查看备份", target: self, action: #selector(showBackup))])
        SettingsLayout.dataPage([title, tools, scroll, actions, note, bottom], in: view)
        updateActions()
    }
    func activate() { if !previewOnly { refresh() } }
    @objc private func showDeviceSync() {
        if syncWindow == nil { syncWindow = DeviceSyncWindow() }
        syncWindow?.showWindow(nil); syncWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func refresh() {
        do { all = try store.entries(); loaded = true; filterRows() }
        catch { status.stringValue = error.localizedDescription; updateActions() }
    }
    @objc private func filterRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let codeQuery = query.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        filtered = all.filter { query.isEmpty || $0.text.localizedStandardContains(query)
            || $0.code.replacingOccurrences(of: " ", with: "").lowercased().contains(codeQuery) }
            .sorted {
                if sort.indexOfSelectedItem == 0, $0.weight != $1.weight { return $0.weight > $1.weight }
                if sort.indexOfSelectedItem == 2, $0.code != $1.code { return $0.code < $1.code }
                return $0.text == $1.text ? $0.code < $1.code : $0.text.localizedStandardCompare($1.text) == .orderedAscending
            }
        table.reloadData()
        emptyView?.isHidden = !filtered.isEmpty
        emptyTitle.stringValue = all.isEmpty ? "还没有学习记录" : "没有匹配的词条"
        emptyNote.stringValue = all.isEmpty ? "日常选词后会逐渐积累，也可以手动新增。" : "换个词语或拼音试试。"
        status.stringValue = all.isEmpty ? "还没有个人学习记录。打字选词后可点击刷新，也可以手动新增。" : "共 \(all.count.formatted()) 条 · 当前显示 \(filtered.count.formatted()) 条"
        updateActions()
    }
    func controlTextDidChange(_ obj: Notification) { filterRows() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row], id = tableColumn?.identifier.rawValue ?? "text"
        return SettingsUI.cell(id == "text" ? entry.text : id == "code" ? entry.code : entry.weight.formatted(), table: table, id: id)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private var selected: [LexiconEntry] { table.selectedRowIndexes.compactMap { filtered.indices.contains($0) ? filtered[$0] : nil } }
    private func updateActions() {
        editButton?.isEnabled = loaded && selected.count == 1
        deleteButton?.isEnabled = loaded && !selected.isEmpty
        undoButton?.isEnabled = store.lastChange != nil
        exportButton?.isEnabled = loaded && !all.isEmpty
    }
    private func changed(_ operation: () throws -> [LexiconEntry]) {
        do { all = try operation(); loaded = true; filterRows() }
        catch { SettingsUI.error(error, window: view.window); updateActions() }
    }
    @objc private func addEntry() { editor(nil) }
    @objc private func editEntry() { if selected.count == 1 { editor(selected[0]) } }
    private func editor(_ original: LexiconEntry?) {
        let alert = NSAlert(); alert.messageText = original == nil ? "新增个人词条" : "编辑个人词条"
        alert.informativeText = "拼音按音节用空格分隔，例如 xing he ci ku。编辑会保留原来的学习权重。"
        let text = NSTextField(string: original?.text ?? ""), code = NSTextField(string: original?.code ?? "")
        text.widthAnchor.constraint(equalToConstant: 350).isActive = true
        text.placeholderString = "词条"; code.placeholderString = "全拼，例如 xing he ci ku"
        text.setAccessibilityLabel("词条"); code.setAccessibilityLabel("全拼")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "词条"), text], [NSTextField(labelWithString: "全拼"), code]])
        grid.rowSpacing = 12; grid.columnSpacing = 12; grid.frame = NSRect(x: 0, y: 0, width: 440, height: 72)
        alert.accessoryView = grid; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                self.changed { try self.store.save(.draft(text: text.stringValue, code: code.stringValue), replacing: original) }
            }
        }
        alert.window.makeFirstResponder(text)
    }
    @objc private func deleteEntries() {
        let entries = selected
        guard !entries.isEmpty else { return }
        SettingsUI.confirm("删除 \(entries.count) 条个人学习记录？", detail: "修改前会自动保存备份，也可以撤销本次删除。", action: "删除记录", window: view.window) {
            self.changed { try self.store.delete(entries) }
        }
    }
    @objc private func undo() { changed { try store.undo() } }
    @objc private func showBackup() {
        let directory = store.backupURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(directory)
        } catch { SettingsUI.error(error, window: view.window) }
    }
    @objc private func importEntries() {
        let panel = NSOpenPanel(); panel.title = "导入个人学习词库"; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .tabSeparatedText]; panel.message = "UTF-8 TSV：词条、全拼、可选学习权重，用制表符分隔。已有记录会合并。"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let entries = try LexiconEntry.parsePersonal(LexiconFiles.text(url), allowEmpty: false)
                SettingsUI.confirm("导入 \(entries.count.formatted()) 条个人记录？", detail: "与现有记录合并；同词同拼音保留较高学习权重。修改前自动备份。", action: "导入", window: window) {
                    self.changed { try self.store.merge(entries) }
                }
            } catch { SettingsUI.error(error, window: window) }
        }
    }
    @objc private func exportEntries() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "RimeQ-个人词库.tsv"; panel.allowedContentTypes = [.tabSeparatedText]
        panel.message = "导出全部个人学习记录，包含当前搜索结果以外的词条。"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try LexiconFiles.write(LexiconEntry.portable(self.store.entries()), to: url) }
            catch { SettingsUI.error(error, window: window) }
        }
    }
    func showPreview(_ entries: [LexiconEntry]) { _ = view; all = entries; loaded = true; previewOnly = true; filterRows() }
}

final class DictionaryResourcesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let store: DictionaryResources
    private let model: OptionalModel
    var manageModel: (() -> Void)?
    private let table = NSTableView()
    private let detail = SettingsUI.label("选择词库查看来源、版本与使用情况。", size: 11, secondary: true)
    private var metadataText = ""
    private let status = SettingsUI.label("词库与个人学习记录独立保存。", secondary: true)
    private let progress = NSProgressIndicator()
    private var importButton: NSButton!
    private var toggleButton: NSButton!
    private var removeButton: NSButton!
    private var browseButton: NSButton!
    private var exportButton: NSButton!
    private var applyButton: NSButton!
    private var preview: DictionaryEntriesWindow?
    init(store: DictionaryResources = .shared, model: OptionalModel = .shared) {
        self.store = store; self.model = model
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(modelChanged), name: OptionalModel.didChange, object: model)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = SettingsBackgroundView()
        importButton = SettingsUI.button("导入词库…", target: self, action: #selector(importDictionary))
        let title = SettingsLayout.heading("词库与模型", subtitle: "管理内置资源，添加自己的专业词表。", action: importButton)
        table.delegate = self; table.dataSource = self
        let scroll = SettingsUI.table(table, columns: [("name", "资源", 210), ("kind", "类型", 110),
            ("count", "词条数 / 大小", 125), ("state", "状态", 150)])
        toggleButton = SettingsUI.button("停用", target: self, action: #selector(toggle))
        removeButton = SettingsUI.button("移除…", target: self, action: #selector(remove))
        browseButton = SettingsUI.button("查看词条…", target: self, action: #selector(browse))
        exportButton = SettingsUI.button("导出源文件…", target: self, action: #selector(exportSource))
        let actions = SettingsUI.row([toggleButton, removeButton, NSView(), browseButton, exportButton])
        detail.isSelectable = true
        detail.maximumNumberOfLines = 3; detail.lineBreakMode = .byTruncatingTail
        detail.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let detailRow = SettingsUI.row([detail, SettingsUI.button("详细信息…", target: self, action: #selector(showDetails))])
        detailRow.distribution = .fill
        detail.setContentHuggingPriority(.init(1), for: .horizontal)
        let information = SettingsCard([detailRow], padding: 12)
        applyButton = SettingsUI.button("重新应用", target: self, action: #selector(reapply))
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let bottom = SettingsUI.row([progress, status, NSView(), SettingsUI.button("恢复内置…", target: self, action: #selector(restore)), applyButton])
        SettingsLayout.dataPage([title, scroll, actions, information,
            SettingsUI.label("支持独立的全拼 .dict.yaml 与 TSV 词表。变更会自动编译，当前输入结束后生效。", size: 11, secondary: true), bottom], in: view)
        reload()
    }
    func activate() { reload() }
    @objc private func modelChanged() {
        guard isViewLoaded, let row = store.catalog.firstIndex(where: { $0.kind == "model" }) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        updateSelection()
    }
    private var imported: ImportedDictionary? {
        let row = table.selectedRow - store.catalog.count
        return store.configuration.imported.indices.contains(row) ? store.configuration.imported[row] : nil
    }
    private var builtin: BundledDictionary? { store.catalog.indices.contains(table.selectedRow) ? store.catalog[table.selectedRow] : nil }
    private func reload() {
        table.reloadData()
        if table.selectedRow < 0, numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if let error = store.loadingError { status.stringValue = error }
        updateSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { store.catalog.count + store.configuration.imported.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "name"
        let text: String
        if row < store.catalog.count {
            let entry = store.catalog[row]
            switch id {
            case "name": text = entry.name
            case "kind": text = entry.kind == "model" ? "可选模型" : "内置词库"
            case "count": text = entry.kind == "model" ? ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file) : entry.count.formatted()
            default: text = entry.kind == "model" ? model.statusDescription
                : entry.kind == "support" ? "随功能内置" : !entry.optional ? "基础必需" : store.configuration.disabled.contains(entry.id) ? "已停用" : "已启用"
            }
        } else {
            let entry = store.configuration.imported[row - store.catalog.count]
            switch id {
            case "name": text = entry.name
            case "kind": text = "第三方词库"
            case "count": text = entry.count.formatted()
            default: text = entry.enabled ? "已启用" : "已停用"
            }
        }
        return SettingsUI.cell(text, table: table, id: id, secondary: id != "name")
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        let busy = store.busy
        importButton?.isEnabled = !busy && store.configurationReadable
        applyButton?.isEnabled = !busy && store.configurationReadable
        toggleButton?.isEnabled = !busy && (imported != nil || builtin?.optional == true)
        removeButton?.isEnabled = !busy && imported != nil
        browseButton?.isEnabled = !busy && (imported != nil || (builtin != nil && builtin?.kind != "model"))
        exportButton?.isEnabled = !busy && (imported != nil || builtin != nil)
        browseButton?.title = builtin?.kind == "model" ? "管理模型…" : "查看词条…"
        if builtin?.kind == "model" {
            toggleButton?.isEnabled = !busy && model.available && !model.state.busy
            browseButton?.isEnabled = true
            exportButton?.isEnabled = model.available && !model.state.busy
        }
        if let entry = imported {
            toggleButton?.title = entry.enabled ? "停用" : "启用"
            detail.stringValue = "\(entry.source)\n版本 \(entry.version) · \(entry.originalName)\n\(entry.license)"
            metadataText = "来源：\(entry.source)\n版本：\(entry.version)\n原文件：\(entry.originalName)\n许可：\(entry.license)\n\nSHA-256：\n\(entry.sha256)"
        } else if let entry = builtin {
            toggleButton?.title = entry.kind == "model" ? (model.enabled ? "停用" : "启用") : (store.configuration.disabled.contains(entry.id) ? "启用" : "停用")
            detail.stringValue = "\(entry.source)\n版本 \(entry.version) · \(entry.file)\n\(entry.kind == "model" ? model.statusDescription : entry.license)"
            metadataText = "来源：\(entry.source)\n版本：\(entry.version)\n文件：\(entry.file)\n许可：\(entry.license)\n\nSHA-256：\n\(entry.sha256)"
        }
    }
    @objc private func showDetails() {
        let alert = NSAlert(); alert.messageText = imported?.name ?? builtin?.name ?? "资源信息"
        alert.informativeText = metadataText
        if let window = view.window { alert.beginSheetModal(for: window) }
    }
    private func apply(_ config: DictionaryConfiguration) {
        status.stringValue = "正在编译词库，完成后自动生效…"
        progress.startAnimation(nil)
        store.apply(config, progress: { self.status.stringValue = $0 }) { result in
            self.progress.stopAnimation(nil)
            switch result {
            case .success: self.status.stringValue = "词库已应用，下一次输入使用新词库。"
            case .failure(let error): self.status.stringValue = "应用失败，继续使用原词库。"; SettingsUI.error(error, window: self.view.window)
            }
            self.reload()
        }
        updateSelection()
    }
    @objc private func toggle() {
        if builtin?.kind == "model" { model.setEnabled(!model.enabled); return }
        var config = store.configuration
        if let entry = imported, let index = config.imported.firstIndex(where: { $0.id == entry.id }) { config.imported[index].enabled.toggle() }
        else if let entry = builtin, entry.optional {
            if !config.disabled.insert(entry.id).inserted { config.disabled.remove(entry.id) }
        } else { return }
        apply(config)
    }
    @objc private func reapply() { apply(store.configuration) }
    @objc private func restore() {
        SettingsUI.confirm("恢复内置词库配置？", detail: "重新启用全部内置词库，停用第三方词库。个人学习记录和导入文件会保留，当前配置会先备份。", action: "恢复内置", window: view.window) {
            do { try self.store.restoreBundled(); self.status.stringValue = "已恢复内置词库。"; self.reload() }
            catch { SettingsUI.error(error, window: self.view.window) }
        }
    }
    @objc private func remove() {
        guard let entry = imported else { return }
        SettingsUI.confirm("移除「\(entry.name)」？", detail: "从加载列表移除这个词库。个人学习记录会保留；原始导入文件仍保存在个人数据文件夹中。", action: "移除", window: view.window) {
            var config = self.store.configuration; config.imported.removeAll { $0.id == entry.id }; self.apply(config)
        }
    }
    @objc private func importDictionary() {
        let panel = NSOpenPanel(); panel.title = "导入第三方全拼词库"; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .tabSeparatedText, UTType(filenameExtension: "yaml") ?? .data]
        panel.message = "选择带全拼编码的独立 .dict.yaml 或 TSV 文件。导入后自动编译并启用。"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { self.confirmImport(try DictionaryImport.read(url)) }
            catch { SettingsUI.error(error, window: window) }
        }
    }
    private func confirmImport(_ draft: DictionaryImport) {
        let alert = NSAlert(); alert.messageText = "导入 \(draft.entries.count.formatted()) 条词条"
        alert.informativeText = "词库会作为独立资源管理，已有词条保留原词频。原始文件及其中的作者声明会一并保存。"
        let name = NSTextField(string: draft.name), source = NSTextField(string: ""), license = NSTextField(string: "")
        name.widthAnchor.constraint(equalToConstant: 350).isActive = true
        source.placeholderString = "来源网址或作者（可选）"; license.placeholderString = "源文件的许可说明（可选）"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "名称"), name], [NSTextField(labelWithString: "来源"), source], [NSTextField(labelWithString: "许可"), license]])
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 105); grid.rowSpacing = 10; grid.columnSpacing = 12
        alert.accessoryView = grid; alert.addButton(withTitle: "导入并启用"); alert.addButton(withTitle: "取消")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do { self.apply(try self.store.adding(draft, name: name.stringValue, source: source.stringValue, license: license.stringValue)) }
            catch { SettingsUI.error(error, window: window) }
        }
    }
    @objc private func exportSource() {
        let url: URL, name: String
        if let entry = imported { url = store.importedURL(entry, original: true); name = entry.originalName }
        else if let entry = builtin { url = entry.kind == "model" ? model.fileURL : store.bundled.appendingPathComponent(entry.file); name = URL(fileURLWithPath: entry.file).lastPathComponent }
        else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            do { try LexiconFiles.write(Data(contentsOf: url, options: .mappedIfSafe), to: destination) }
            catch { SettingsUI.error(error, window: window) }
        }
    }
    @objc private func browse() {
        if builtin?.kind == "model" { manageModel?(); return }
        let url: URL, name: String
        if let entry = imported { url = store.importedURL(entry); name = entry.name }
        else if let entry = builtin, entry.kind != "model" { url = store.bundled.appendingPathComponent(entry.file); name = entry.name }
        else { return }
        preview = DictionaryEntriesWindow(url: url, name: name)
        preview?.showWindow(nil)
    }
}

// Searches source text on demand. Only a bounded result page is materialized,
// including for the million-row bundled dictionary.
final class DictionaryEntriesWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let source: URL
    private let table = NSTableView(), search = NSSearchField()
    private let status = SettingsUI.label("正在读取…", secondary: true)
    private var rows: [[String]] = []
    private var generation = 0
    private let searchQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        return queue
    }()
    init(url: URL, name: String) {
        source = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = name; window.center(); window.isReleasedWhenClosed = false
        search.placeholderString = "搜索词条或拼音"; search.delegate = self
        table.delegate = self; table.dataSource = self
        let scroll = SettingsUI.table(table, columns: [("0", "词条", 300), ("1", "拼音 / 编码", 240), ("2", "原始词频", 120)])
        SettingsUI.layout([search, scroll, status], in: window.contentView!)
        loadRows()
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ obj: Notification) { loadRows() }
    private func loadRows() {
        generation += 1
        searchQueue.cancelAllOperations()
        let epoch = generation, url = source, query = search.stringValue.lowercased().replacingOccurrences(of: " ", with: "")
        status.stringValue = "正在搜索…"
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result: Result<([[String]], Int), Error> = Result {
                let text = try LexiconFiles.text(url, limit: 128 * 1024 * 1024)
                var body = !url.lastPathComponent.hasSuffix(".yaml"), rows: [[String]] = [], matches = 0
                let weightOnly = url.lastPathComponent == "tencent.dict.yaml"
                text.enumerateLines { line, stop in
                    if operation?.isCancelled != false { stop = true; return }
                    if line.trimmingCharacters(in: .whitespaces) == "..." { body = true; return }
                    guard body, !line.isEmpty, !line.hasPrefix("#") else { return }
                    guard query.isEmpty || line.lowercased().replacingOccurrences(of: " ", with: "").contains(query) else { return }
                    matches += 1
                    if rows.count < 1000 {
                        let parts = line.components(separatedBy: "\t")
                        rows.append([parts[0], weightOnly ? "自动注音" : (parts.count > 1 ? parts[1] : "自动注音"),
                                     weightOnly ? (parts.count > 1 ? parts[1] : "默认") : (parts.count > 2 ? parts[2] : "默认")])
                    }
                }
                return (rows, matches)
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                switch result {
                case .success(let (rows, count)):
                    self.rows = rows; self.table.reloadData()
                    self.status.stringValue = "匹配 \(count.formatted()) 条" + (count > 1000 ? " · 显示前 1,000 条，请缩小搜索范围。" : "")
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
        searchQueue.addOperation(operation)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "0"
        return SettingsUI.cell(rows[row][Int(id) ?? 0], table: table, id: id)
    }
}
