import AppKit

@MainActor final class DeviceSyncWindow: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let sync: DeviceSync
    private let root = SettingsBackgroundView()
    private let body = SettingsLayout.vertical([], spacing: 20)
    private let message = SyncUI.text("", size: 12)
    private let progress = NSProgressIndicator()
    private let activity = SyncUI.text("正在读取设备状态…", size: 12, secondary: true)
    private let summaryTitle = SyncUI.text("", size: 16, weight: .semibold)
    private let summaryDetail = SyncUI.text("", size: 12, secondary: true)
    private let memberList = SettingsLayout.vertical([], spacing: 0)
    private let requests = SettingsLayout.vertical([], spacing: 8)
    private let search = NSSearchField()
    private let noResults = SyncUI.text("没有匹配的设备", size: 13, secondary: true)
    private var pendingCard: NSView?
    private var memberRows: [String: SyncDeviceRow] = [:]
    private var memberIDs: [String] = []
    private var pendingIDs: [String] = []
    private var controls: [NSControl] = []
    private var pauseButton: SyncActionButton?
    private var addButton: SyncActionButton?
    private var moreButton: SyncActionButton?
    private var timer: Timer?
    private var refreshing = false, working = false, loaded = false
    private var shownGroup: String?
    private var state: [String: Any] = [:]
    private var operationError: String?
    private var sheet: DeviceSyncSheet?
    private var retryButton: SyncActionButton!

    init(sync: DeviceSync? = nil) {
        self.sync = sync ?? .shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "附近设备同步"; window.titlebarAppearsTransparent = true
        window.minSize = .init(width: 680, height: 580); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        window.delegate = self; window.contentView = root
        search.placeholderString = "搜索设备"; search.delegate = self; search.controlSize = .large
        search.setAccessibilityLabel("搜索已加入的设备")
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 14).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let heading = SyncUI.row([SyncUI.icon("arrow.triangle.2.circlepath", size: 30),
            SettingsLayout.heading("附近设备同步", subtitle: "在你的电脑之间，延续个人词库与学习记录。")], spacing: 16)
        let status = SyncUI.row([progress, activity, SyncUI.spacer()], spacing: 8)
        let header = SettingsLayout.vertical([heading, status], spacing: 12)
        retryButton = SyncActionButton("重试连接", symbol: "arrow.clockwise") { [weak self] in
            guard let self else { return }
            runAction("正在重新连接…") { [self] in try await self.sync.ensureStarted(retry: true) }
        }
        retryButton.isHidden = true
        message.isHidden = true; message.textColor = .systemRed
        SettingsLayout.scrollPage([header, message, retryButton, body,
            SyncUI.footer("仅在信任的局域网开启。连接已授权设备，日常输入仍在本机完成。")], in: root)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.window?.isVisible == true else { return }
                    await self.refresh()
                }
            }
        }
        Task { await refresh() }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private func button(_ title: String, symbol: String? = nil, primary: Bool = false,
                        action: @escaping () -> Void) -> SyncActionButton {
        let button = SyncActionButton(title, symbol: symbol, primary: primary, action: action)
        controls.append(button); return button
    }
    private func runAction(_ title: String, action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; operationError = nil; showError(nil)
        activity.stringValue = title; progress.startAnimation(nil)
        updateControls()
        Task {
            defer { working = false; progress.stopAnimation(nil); updateControls(); updateActivity() }
            do { try await action() } catch { operationError = error.localizedDescription; sheet?.reportError(error.localizedDescription) }
            // Finish any older polling read before requesting the post-action state.
            while refreshing { try? await Task.sleep(nanoseconds: 10_000_000) }
            await refresh()
        }
    }
    private func updateActivity() {
        guard !working else { return }
        if state["group"] is [String: Any] {
            activity.stringValue = state["enabled"] as? Bool == true ? "同步已开启 · 连接后自动合并，有输入时稍候应用" : "同步已暂停 · 本机输入和学习照常保留"
        } else { activity.stringValue = "尚未开启 · 选择创建或加入同步组" }
    }
    private func updateControls() {
        retryButton.isEnabled = !working
        controls.forEach { $0.isEnabled = !working }
        if state["group"] is [String: Any] { addButton?.isEnabled = !working && state["enabled"] as? Bool == true }
    }
    private func showError(_ text: String?) { message.stringValue = text ?? ""; message.isHidden = text == nil }
    private func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            render(try await sync.displayStatus())
            retryButton.isHidden = true
        } catch {
            retryButton.isHidden = false
            if !loaded { buildLanding(); loaded = true }
            showError(error.localizedDescription)
            if !working { activity.stringValue = "服务暂不可用，请点重试连接" }
        }
    }
    private func render(_ value: [String: Any]) {
        state = value
        let group = value["group"] as? [String: Any], id = group?["id"] as? String
        if !loaded || shownGroup != id {
            shownGroup = id; loaded = true; controls.removeAll(); memberRows.removeAll(); memberIDs = []; pendingIDs = []
            if group == nil { buildLanding() } else { buildGroup() }
        }
        let enabled = value["enabled"] as? Bool == true
        showError(operationError ?? sync.lastError ?? value["network_error"] as? String)
        if group != nil {
            let devices = (value["members"] as? [[String: Any]] ?? []).filter { $0["removed"] as? Bool != true }.sorted {
                if ($0["self"] as? Bool == true) != ($1["self"] as? Bool == true) { return $0["self"] as? Bool == true }
                return ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending
            }
            summaryTitle.stringValue = group?["name"] as? String ?? "我的设备"
            summaryDetail.stringValue = "\(devices.count) 台设备已加入 · \(devices.filter { $0["online"] as? Bool == true }.count) 台可连接"
            pauseButton?.title = enabled ? "暂停同步" : "恢复同步"
            pauseButton?.image = NSImage(systemSymbolName: enabled ? "pause" : "play", accessibilityDescription: nil)
            if !working { activity.stringValue = enabled ? "同步已开启 · 连接后自动合并，有输入时稍候应用" : "同步已暂停 · 本机输入和学习照常保留" }
            updateMembers(devices)
            let pending = value["pending"] as? [[String: Any]] ?? []
            updateRequests(pending)
            sheet?.update(state: value)
        } else if !working { activity.stringValue = "尚未开启 · 选择创建或加入同步组" }
        updateControls()
    }
    private func buildLanding() {
        let create = button("创建同步组", symbol: "plus", primary: true) { [weak self] in self?.showSetup(.create) }
        let join = button("加入已有同步组", symbol: "arrow.right") { [weak self] in self?.showSetup(.join) }
        func option(_ symbol: String, title: String, detail: String, action: NSView) -> NSView {
            SettingsCard([SyncUI.row([SyncUI.icon(symbol, size: 28), SyncUI.spacer()]), SyncUI.text(title, size: 17, weight: .semibold),
                          SyncUI.text(detail, size: 12, secondary: true), action], padding: 22, spacing: 13)
        }
        let choices = SyncUI.row([
            option("laptopcomputer", title: "从这台电脑开始", detail: "第一次使用？创建一个同步组，再邀请你的其他电脑。", action: create),
            option("laptopcomputer.and.arrow.down", title: "连接已有的电脑", detail: "其他电脑已经开启同步？输入那台电脑上的配对码。", action: join)
        ], spacing: 16)
        choices.distribution = .fillEqually; choices.alignment = .top
        choices.arrangedSubviews[0].widthAnchor.constraint(equalTo: choices.arrangedSubviews[1].widthAnchor).isActive = true
        let details = SettingsCard([
            SyncUI.row([SyncUI.icon("text.book.closed", size: 19), SettingsLayout.vertical([
                SyncUI.text("同步你的个人词库", weight: .medium),
                SyncUI.text("已有和后续的个人词条、拼音与学习权重会在组内合并。", size: 12, secondary: true)
            ], spacing: 5)]),
            SettingsLayout.separator(),
            SyncUI.row([SyncUI.icon("checkmark.shield", size: 19), SettingsLayout.vertical([
                SyncUI.text("每台电脑只需加入一次", weight: .medium),
                SyncUI.text("无需账号或服务器。基础词库、模型、皮肤和原始按键不参与同步。", size: 12, secondary: true)
            ], spacing: 5)])
        ], padding: 20, spacing: 18)
        SyncUI.replace(body, with: [choices, details])
    }
    private func buildGroup() {
        let pause = button("暂停同步", symbol: "pause") { [weak self] in
            guard let self else { return }
            let enabled = state["enabled"] as? Bool == true
            runAction(enabled ? "正在暂停同步…" : "正在恢复同步…") { [self] in
                _ = try await self.sync.request(["action": enabled ? "pause" : "resume"])
            }
        }
        pauseButton = pause
        summaryTitle.maximumNumberOfLines = 1; summaryTitle.lineBreakMode = .byTruncatingTail
        summaryDetail.maximumNumberOfLines = 1; summaryDetail.lineBreakMode = .byTruncatingTail
        let summaryLabels = SettingsLayout.vertical([summaryTitle, summaryDetail], spacing: 6)
        summaryLabels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let summary = SettingsCard([SyncUI.row([SyncUI.icon("rectangle.3.group", size: 26),
            summaryLabels, pause], spacing: 18)], padding: 20)
        let add = button("添加设备", symbol: "plus", primary: true) { [weak self] in self?.showInvitation() }; addButton = add
        let now = button("立即同步", symbol: "arrow.clockwise") { [weak self] in
            guard let self else { return }
            runAction("正在同步…") { [self] in _ = try await self.sync.request(["action": "sync_now"]); await self.sync.tick(force: true) }
        }
        let tools = SyncUI.row([SyncUI.text("已加入的设备", size: 14, weight: .semibold), SyncUI.spacer(), now, add])
        let card = SettingsCard([requests], padding: 16); card.isHidden = true; pendingCard = card
        let more = button("更多", symbol: "ellipsis") { [weak self] in self?.showMore() }; more.isBordered = false; moreButton = more
        let foot = SyncUI.row([SyncUI.text("离线设备会在重新连接后补齐变更。", size: 11, secondary: true), SyncUI.spacer(), more])
        SyncUI.replace(body, with: [summary, card, tools, search, SettingsCard([memberList]), foot])
    }
    private func updateMembers(_ devices: [[String: Any]]) {
        let ids = devices.compactMap { $0["id"] as? String }
        if ids != memberIDs {
            memberIDs = ids; memberRows.removeAll()
            var rows: [NSView] = []
            for device in devices {
                guard let id = device["id"] as? String else { continue }
                let name = device["name"] as? String ?? "设备"
                let canRemove = device["self"] as? Bool != true && state["can_remove"] as? Bool == true
                let row = SyncDeviceRow(remove: canRemove ? { [weak self] in self?.remove(id: id, name: name) } : nil)
                memberRows[id] = row; rows.append(row)
            }
            rows.append(noResults); SyncUI.replace(memberList, with: rows)
        }
        for device in devices {
            if let id = device["id"] as? String { memberRows[id]?.update(device, paused: state["enabled"] as? Bool != true) }
        }
        filterMembers()
    }
    func controlTextDidChange(_ notification: Notification) { filterMembers() }
    private func filterMembers() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = state["members"] as? [[String: Any]] ?? []
        for device in devices {
            guard let id = device["id"] as? String else { continue }
            memberRows[id]?.isHidden = !query.isEmpty && !(device["name"] as? String ?? "").localizedCaseInsensitiveContains(query)
        }
        noResults.isHidden = memberRows.values.contains { !$0.isHidden }
    }
    private func updateRequests(_ pending: [[String: Any]]) {
        pendingCard?.isHidden = pending.isEmpty
        let ids = pending.compactMap { $0["id"] as? String }
        guard ids != pendingIDs else { return }; pendingIDs = ids
        let rows = pending.compactMap { item -> NSView? in
            guard let id = item["id"] as? String else { return nil }
            let name = item["name"] as? String ?? "新设备"
            let approve = SyncActionButton("允许加入", primary: true) { [weak self] in self?.approve(id: id, name: name) }
            let reject = SyncActionButton("拒绝") { [weak self] in self?.reject(id: id) }
            return SyncUI.row([SyncUI.icon("person.crop.circle.badge.plus", size: 19),
                SettingsLayout.vertical([SyncUI.text(name, weight: .medium), SyncUI.text("请求加入你的同步组", size: 11, secondary: true)], spacing: 4), reject, approve])
        }
        SyncUI.replace(requests, with: rows)
    }
    fileprivate func approve(id: String, name: String) {
        runAction("正在允许设备加入…") { [self] in
            _ = try await self.sync.request(["action": "approve", "id": id]); sheet?.showApproved(name)
        }
    }
    fileprivate func reject(id: String) {
        runAction("正在拒绝加入请求…") { [self] in _ = try await self.sync.request(["action": "reject", "id": id]) }
    }
    private func remove(id: String, name: String) {
        confirm("移除“\(name)”？", detail: "其他设备收到移除记录后停止与其同步。已经复制的词条无法远程收回。", action: "移除设备") { [weak self] in
            self?.runAction("正在移除设备…") { [weak self] in _ = try await self?.sync.request(["action": "remove", "id": id]) }
        }
    }
    private func confirm(_ title: String, detail: String, action: String, perform: @escaping () -> Void) {
        guard !working, window?.attachedSheet == nil else { return }
        SettingsUI.confirm(title, detail: detail, action: action, window: window, perform: perform)
    }
    private func showMore() {
        guard let moreButton else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, selector, enabled) in [
            ("查看同步备份", #selector(openBackups), true),
            ("处理未完成的同步…", #selector(recover), state["waiting_input"] as? Bool == true),
            ("退出同步组…", #selector(leave), true)
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
            item.isEnabled = enabled && !working; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }
    @objc private func openBackups() {
        runAction("正在打开备份…") { [self] in
            let url = sync.root.appendingPathComponent("backups")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func recover() {
        confirm("采用本机词库继续同步？", detail: "先保留本机与同步目标两份备份，再将本机当前的新增、修改和删除同步给其他设备。", action: "备份并继续") { [weak self] in
            self?.runAction("正在恢复同步…") { [weak self] in try await self?.sync.recoverLocal() }
        }
    }
    @objc private func leave() {
        let detail = "个人词库和学习记录会留在本机。" + (state["can_remove"] as? Bool == true ? "这台电脑是创建者，退出后原组将无法再移除成员。" : "重新加入需要另一台设备邀请。")
        confirm("退出这个同步组？", detail: detail, action: "保留词库并退出") { [weak self] in
            self?.runAction("正在退出同步组…") { [weak self] in try await self?.sync.leave() }
        }
    }
    private func showSetup(_ mode: DeviceSyncSheet.Mode) {
        guard !working, let window, window.attachedSheet == nil else { return }
        let sheet = DeviceSyncSheet(mode: mode, sync: sync)
        self.sheet = sheet
        sheet.finished = { [weak self] in self?.sheet = nil; Task { await self?.refresh() } }
        sheet.present(in: window)
    }
    private func showInvitation() {
        guard !working, let window, window.attachedSheet == nil else { return }
        let sheet = DeviceSyncSheet(mode: .invite, sync: sync)
        self.sheet = sheet
        sheet.approve = { [weak self] id, name in self?.approve(id: id, name: name) }
        sheet.reject = { [weak self] id in self?.reject(id: id) }
        sheet.finished = { [weak self] in self?.sheet = nil; Task { await self?.refresh() } }
        sheet.present(in: window)
    }

    func validateUnusedForSmoke() async throws {
        await refresh(); await refresh()
        try EngineSmoke.check(loaded && state["group"] is NSNull, "unused sync page did not show setup")
        try EngineSmoke.check(!FileManager.default.fileExists(atPath: sync.root.path), "viewing unused sync started a helper or created an identity")
    }

    func validateForSmoke(destination: URL) async throws {
        await refresh()
        try EngineSmoke.check(memberRows.count == 6, "sync window lost group members")
        let first = memberRows.values.first
        await refresh()
        try EngineSmoke.check(memberRows.values.contains { $0 === first }, "polling replaced stable device rows")
        search.stringValue = "not-a-device"; filterMembers()
        try EngineSmoke.check(!noResults.isHidden && memberRows.values.allSatisfy(\.isHidden), "device search failed")
        search.stringValue = ""; filterMembers()
        try snapshot(to: destination, size: .init(width: 760, height: 780), appearance: .aqua)
        guard let pauseButton else { throw LexiconError.message("pause control unavailable") }
        pauseButton.performClick(nil)
        while working { try await Task.sleep(nanoseconds: 10_000_000) }
        try EngineSmoke.check(state["enabled"] as? Bool == false, "pause button did not pause helper")
        pauseButton.performClick(nil)
        while working { try await Task.sleep(nanoseconds: 10_000_000) }
        try EngineSmoke.check(state["enabled"] as? Bool == true, "resume button did not resume helper")
        // Exercise the actual join sheet and its cancellation against the TLS
        // service. This guest never opens or captures an input dictionary.
        let guestRoot = sync.root.appendingPathComponent("ui-cancel-guest")
        let suite = "RimeQ.SyncUISmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let guest = DeviceSync(root: guestRoot, defaults: defaults, dictionary: .init(root: guestRoot), isolated: true)
        defer {
            guest.stop(); defaults.removePersistentDomain(forName: suite); defaults.synchronize()
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/" + suite + ".plist"))
        }
        try await guest.ensureStarted()
        let invite = try await sync.request(["action": "invite"])
        let joinSheet = DeviceSyncSheet(mode: .join, sync: guest)
        guard let window else { throw LexiconError.message("native sync window missing") }
        window.orderFront(nil); defer { window.orderOut(nil) }
        joinSheet.present(in: window)
        try joinSheet.joinForSmoke(address: "127.0.0.1:\(invite["port"] as? Int ?? 0)", invite: invite["invite"] as? String ?? "", code: invite["code"] as? String ?? "")
        let deadline = Date().addingTimeInterval(15)
        var requested = false
        while Date() < deadline {
            let value = try await sync.request(["action": "status"])
            if !(value["pending"] as? [[String: Any]] ?? []).isEmpty { requested = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try EngineSmoke.check(requested, "native join sheet did not reach inviter approval")
        joinSheet.cancelForSmoke()
        while window.attachedSheet != nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try EngineSmoke.check(window.attachedSheet == nil, "cancel join did not close its sheet")
        let guestStatus = try await guest.request(["action": "status"])
        try EngineSmoke.check(guestStatus["group"] is NSNull, "cancelled UI guest still joined the group")
        while Date() < deadline {
            let value = try await sync.request(["action": "status"])
            if (value["pending"] as? [[String: Any]] ?? []).isEmpty { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LexiconError.message("cancelled native approval remained on inviter")
    }
    private func snapshot(to path: URL, size: NSSize, appearance: NSAppearance.Name) throws {
        guard let window, let view = window.contentView else { return }
        window.appearance = NSAppearance(named: appearance); window.setContentSize(size)
        window.orderFront(nil); defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        if state["group"] is [String: Any], let pauseButton {
            let naturalWidth = (summaryDetail.stringValue as NSString).size(withAttributes: [.font: summaryDetail.font!]).width
            let labelFrame = summaryDetail.convert(summaryDetail.bounds, to: view)
            let buttonFrame = pauseButton.convert(pauseButton.bounds, to: view)
            try EngineSmoke.check(summaryDetail.bounds.width >= ceil(naturalWidth) && summaryDetail.bounds.height < 30,
                                  "group summary wrapped despite available width")
            try EngineSmoke.check(buttonFrame.minX - labelFrame.maxX <= 24,
                                  "group summary lost available width to an empty spacer")
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LexiconError.message("sync bitmap unavailable") }
        window.appearance!.performAsCurrentDrawingAppearance { view.displayIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LexiconError.message("sync PNG unavailable") }
        try LexiconFiles.write(data, to: path)
    }
    static func renderPreviews(to directory: URL) throws {
        let controller = DeviceSyncWindow()
        let names = ["我的 MacBook Pro", "办公室的电脑", "家里的 Mac mini", "随身笔记本", "工作室电脑", "备用电脑"]
        let devices: [[String: Any]] = names.enumerated().map { i, name in
            ["id": "preview-\(i)", "name": name, "self": i == 0, "online": i < 3, "applied": i != 2, "removed": false]
        }
        let group: [String: Any] = ["group": ["id": "preview-group", "name": "我的设备"], "enabled": true, "can_remove": true, "members": devices, "pending": []]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let single = DeviceSyncWindow()
            var singleGroup = group
            singleGroup["group"] = ["id": "single-preview", "name": "测试组"]
            singleGroup["members"] = [devices[0]]
            single.render(singleGroup)
            try single.snapshot(to: directory.appendingPathComponent("single-device-\(suffix).png"), size: .init(width: 760, height: 780), appearance: appearance)
            try single.snapshot(to: directory.appendingPathComponent("single-device-compact-\(suffix).png"), size: .init(width: 680, height: 580), appearance: appearance)
            controller.render(["enabled": false])
            try controller.snapshot(to: directory.appendingPathComponent("welcome-\(suffix).png"), size: .init(width: 760, height: 780), appearance: appearance)
            controller.render(group)
            try controller.snapshot(to: directory.appendingPathComponent("devices-\(suffix).png"), size: .init(width: 760, height: 780), appearance: appearance)
            try controller.snapshot(to: directory.appendingPathComponent("compact-\(suffix).png"), size: .init(width: 680, height: 580), appearance: appearance)
        }
        var expanded = group
        expanded["members"] = (0..<20).map { i -> [String: Any] in
            ["id": "large-\(i)", "name": i == 0 ? String(repeating: "外出使用的笔记本电脑", count: 4) : String(format: "测试电脑 %02d", i), "self": i == 0, "online": i < 3, "applied": true, "removed": false]
        }
        controller.render(expanded)
        try controller.snapshot(to: directory.appendingPathComponent("twenty-devices.png"), size: .init(width: 680, height: 580), appearance: .aqua)
        try DeviceSyncSheet.renderPreviews(to: directory)
    }
}
