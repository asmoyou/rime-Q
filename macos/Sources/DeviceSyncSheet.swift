import AppKit

@MainActor final class DeviceSyncSheet: NSWindowController, NSTextFieldDelegate {
    enum Mode { case create, join, invite }
    private let mode: Mode
    private let sync: DeviceSync
    private let root = SettingsBackgroundView()
    private let content = SettingsLayout.vertical([], spacing: 18)
    private let status = SyncUI.text("", size: 12, secondary: true)
    private let error = SyncUI.text("", size: 12)
    private let deviceName = NSTextField(string: Host.current().localizedName ?? "我的 Mac")
    private let groupName = NSTextField(string: "我的设备")
    private let code = NSTextField()
    private let address = NSTextField(), invitation = NSTextField()
    private let nearby = NSPopUpButton()
    private let manual = NSButton(checkboxWithTitle: "找不到设备？手动连接", target: nil, action: nil)
    private let manualFields = SettingsLayout.vertical([], spacing: 12)
    private let codeCaption = SyncUI.text("在另一台电脑输入", size: 12, secondary: true)
    private let pairingCode = SyncUI.text("", size: 34, weight: .semibold)
    private let countdown = SyncUI.text("", size: 12, secondary: true)
    private let pending = SettingsLayout.vertical([], spacing: 10)
    private let spinner = NSProgressIndicator()
    private var primary: SyncActionButton!
    private var cancel: SyncActionButton!
    private var refreshButton: SyncActionButton?
    private var copyCode: SyncActionButton?
    private var copyConnection: SyncActionButton?
    private var fields: [NSControl] = []
    private var timer: Timer?
    private var working = false, refreshing = false, closing = false, cancelling = false
    private var expiry: Date?
    private var scanUntil: Date?
    private var discovered: [[String: Any]] = []
    private var pendingIDs: [String] = []
    private var invitationValue: [String: Any]?
    private var approved = false, consumed = false
    var finished: (() -> Void)?
    var approve: ((String, String) -> Void)?
    var reject: ((String) -> Void)?

    init(mode: Mode, sync: DeviceSync) {
        self.mode = mode; self.sync = sync
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: mode == .create ? 470 : 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        super.init(window: window); window.contentView = root
        let footer = NSView(), page = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false; page.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(page); root.addSubview(footer)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.topAnchor.constraint(equalTo: root.topAnchor), page.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 76)
        ])
        error.textColor = .systemRed; error.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        SettingsLayout.scrollPage([content, error, SyncUI.row([spinner, status, SyncUI.spacer()], spacing: 8)], in: page)
        cancel = SyncActionButton(mode == .invite ? "关闭邀请" : "取消") { [weak self] in self?.dismiss() }
        cancel.keyEquivalent = "\u{1b}"
        primary = SyncActionButton(mode == .create ? "创建并开启" : mode == .join ? "加入同步组" : "重新生成", primary: mode != .invite) { [weak self] in self?.submit() }
        primary.keyEquivalent = "\r"
        let buttons = SyncUI.row([SyncUI.spacer(), cancel, primary])
        SyncUI.pin(buttons, to: footer, inset: 20)
        for field in [deviceName, groupName, code, address, invitation] { field.delegate = self }
        fields = [deviceName, groupName, code, address, invitation, nearby, manual]
        if mode == .create { buildCreate() } else if mode == .join { buildJoin() } else { buildInvite() }
        validate()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    private func buildCreate() {
        SyncUI.replace(content, with: [
            SettingsLayout.heading("创建同步组", subtitle: "从这台电脑开始，再邀请你的其他电脑加入。"),
            SettingsCard([
                SyncUI.field("这台电脑的名称", value: deviceName, placeholder: "例如：我的 MacBook"),
                SyncUI.field("同步组名称", value: groupName, placeholder: "例如：我的设备")
            ], padding: 20, spacing: 18),
            SyncUI.footer("创建后开启本地网络发现。拒绝网络授权仍可正常输入和学习。"),
            SyncUI.text("加入组的电脑会互相分享已有及后续的个人词条与学习权重。", size: 12, secondary: true)
        ])
    }
    private func buildJoin() {
        nearby.controlSize = .large; nearby.target = self; nearby.action = #selector(selectNearby)
        nearby.setAccessibilityLabel("附近正在邀请的设备")
        nearby.addItem(withTitle: "正在查找附近设备…")
        let refresh = SyncActionButton("重新查找", symbol: "arrow.clockwise") { [weak self] in self?.discover() }; refreshButton = refresh
        manual.target = self; manual.action = #selector(toggleManual)
        code.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        code.alignment = .center; code.placeholderString = "6 位数字"
        let paste = SyncActionButton("粘贴连接信息", symbol: "doc.on.clipboard") { [weak self] in self?.pasteConnection() }
        SyncUI.replace(manualFields, with: [
            SyncUI.field("连接地址", value: address, placeholder: "例如：192.168.1.8:12345"),
            SyncUI.field("邀请标识", value: invitation, placeholder: "从原设备的邀请窗口复制"),
            paste
        ]); manualFields.isHidden = true
        SyncUI.replace(content, with: [
            SettingsLayout.heading("加入同步组", subtitle: "先在另一台电脑打开“添加设备”，再选择它并输入配对码。"),
            SettingsCard([
                SyncUI.field("这台电脑的名称", value: deviceName, placeholder: "设备名称"),
                SettingsLayout.vertical([SyncUI.text("附近正在邀请的设备", size: 12, weight: .medium, secondary: true), SyncUI.row([nearby, refresh])], spacing: 7),
                SettingsLayout.vertical([SyncUI.text("另一台电脑上的配对码", size: 12, weight: .medium, secondary: true), SettingsCard([code], padding: 8)], spacing: 7),
                manual, manualFields
            ], padding: 20, spacing: 17),
            SyncUI.footer("查找设备需要本地网络权限。加入前，另一台电脑还需要确认。")
        ])
        code.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        code.isBordered = false; code.isBezeled = false; code.drawsBackground = false
        code.setAccessibilityLabel("另一台电脑上的配对码")
    }
    private func buildInvite() {
        pairingCode.alignment = .center; pairingCode.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        countdown.alignment = .center
        let copy = SyncActionButton("复制配对码", symbol: "doc.on.doc") { [weak self] in
            guard let self, let value = invitationValue?["code"] as? String, expiry.map({ $0 > Date() }) == true else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            status.stringValue = "配对码已复制"
        }; copyCode = copy
        let connection = SyncActionButton("复制连接信息", symbol: "link") { [weak self] in self?.copyManualConnection() }; copyConnection = connection
        let steps = SettingsLayout.vertical([
            SyncUI.text("1  在另一台电脑选择“加入已有同步组”", size: 13),
            SyncUI.text("2  选中这台电脑，并输入上方配对码", size: 13),
            SyncUI.text("3  回到这里，确认允许它加入", size: 13)
        ], spacing: 12)
        pending.isHidden = true
        SyncUI.replace(content, with: [
            SettingsLayout.heading("添加设备", subtitle: "保持此窗口打开，在你的另一台电脑上完成配对。"), pending,
            SettingsCard([codeCaption, pairingCode, countdown,
                SyncUI.centered(copy)], padding: 22, spacing: 12),
            steps,
            SyncUI.row([SyncUI.text("附近找不到这台电脑？", size: 12, secondary: true), SyncUI.spacer(), connection])
        ])
        status.stringValue = "正在生成邀请…"
    }
    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        if mode != .create { startTimer() }
        if mode == .invite { generateInvite() } else if mode == .join { discover() }
        window.makeFirstResponder(mode == .create ? deviceName : mode == .join ? code : primary)
    }
    private func setWorking(_ value: Bool, message: String? = nil) {
        working = value; fields.forEach { $0.isEnabled = !value }
        cancel.isEnabled = !value || mode == .join && !cancelling
        cancel.title = mode == .join && value ? "取消加入" : mode == .invite ? "关闭邀请" : "取消"
        refreshButton?.isEnabled = !value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if let message { status.stringValue = message }
        validate()
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === code {
            let cleaned = code.stringValue.compactMap(\.wholeNumberValue).filter { (0...9).contains($0) }.prefix(6).map(String.init).joined()
            if code.stringValue != cleaned { code.stringValue = cleaned }
        }
        validate()
    }
    private var connection: (String, String)? {
        if manual.state == .on {
            let a = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let i = invitation.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return a.isEmpty || i.isEmpty ? nil : (a, i)
        }
        guard let item = nearby.selectedItem?.representedObject as? [String: Any],
              let a = item["address"] as? String, let i = item["invite"] as? String else { return nil }
        return (a, i)
    }
    private func validate() {
        func validName(_ text: String) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 128 && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        let named = validName(deviceName.stringValue)
        let validCode = code.stringValue.count == 6 && code.stringValue.utf8.allSatisfy { (48...57).contains($0) }
        primary.isEnabled = !working && (mode == .invite || named && (mode == .create ? validName(groupName.stringValue) : validCode && connection != nil))
    }
    @objc private func selectNearby() { validate() }
    @objc private func toggleManual() {
        manualFields.isHidden = manual.state != .on; validate(); root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        if manual.state == .on { window?.makeFirstResponder(address); address.scrollToVisible(address.bounds) }
    }
    private func submit() {
        guard primary.isEnabled else { return }
        if mode == .invite { generateInvite(); return }
        let values: [String: Any]
        if mode == .create {
            values = ["action": "create", "group": groupName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), "name": deviceName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            guard let (address, invite) = connection else { return }
            values = ["action": "join", "address": address, "invite": invite, "code": code.stringValue, "name": deviceName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        reportError(nil)
        setWorking(true, message: mode == .create ? "正在创建同步组…" : "等待另一台电脑确认加入，最长约两分钟…")
        Task {
            do {
                try await sync.ensureStarted(retry: true); _ = try await sync.request(values)
                sync.markStarted(); setWorking(false); closeSheet()
            } catch {
                if cancelling { closeSheet() }
                else {
                    setWorking(false, message: "请检查后重试，个人词库仍保留在本机。")
                    reportError(error.localizedDescription)
                }
            }
        }
    }
    private func discover() {
        guard !working else { return }
        scanUntil = Date().addingTimeInterval(8); status.stringValue = "正在查找附近正在邀请的设备…"
        spinner.startAnimation(nil); reportError(nil)
        Task {
            do { try await sync.ensureStarted(retry: true); update(state: try await sync.request(["action": "discover"])) }
            catch { spinner.stopAnimation(nil); reportError(error.localizedDescription) }
        }
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { [weak self] in await self?.refresh() } }
    }
    private func generateInvite() {
        guard !working else { return }
        startTimer()
        setWorking(true, message: "正在生成邀请…"); reportError(nil)
        Task {
            do {
                try await sync.ensureStarted()
                if invitationValue != nil { _ = try await sync.request(["action": "cancel_invite"]) }
                invitationValue = try await sync.request(["action": "invite"])
                expiry = Date().addingTimeInterval(TimeInterval(invitationValue?["expires_in"] as? Int ?? 300))
                approved = false; consumed = false; pairingCode.stringValue = invitationValue?["code"] as? String ?? ""
                setWorking(false, message: "等待另一台电脑输入配对码…"); updateCountdown()
            } catch { setWorking(false, message: "邀请未能生成，可点击重新生成。"); reportError(error.localizedDescription) }
        }
    }
    private func refresh() async {
        guard !refreshing, !closing else { return }; refreshing = true; defer { refreshing = false }
        updateCountdown()
        do { update(state: try await sync.request(["action": "status"])) }
        catch { if !working { reportError(error.localizedDescription) } }
    }
    func update(state: [String: Any]) {
        if mode == .join {
            let list = (state["discovered"] as? [[String: Any]] ?? []).filter { !($0["invite"] as? String ?? "").isEmpty }
            let old = (nearby.selectedItem?.representedObject as? [String: Any])?["invite"] as? String
            let oldIDs = discovered.map { ($0["address"] as? String ?? "") + ($0["invite"] as? String ?? "") }
            let newIDs = list.map { ($0["address"] as? String ?? "") + ($0["invite"] as? String ?? "") }
            if oldIDs != newIDs {
                discovered = list; nearby.removeAllItems(); nearby.addItem(withTitle: "选择要连接的电脑")
                for item in list {
                    nearby.addItem(withTitle: item["name"] as? String ?? "Rime Q 设备"); nearby.lastItem?.representedObject = item
                    if old == item["invite"] as? String { nearby.select(nearby.lastItem) }
                }
                if nearby.indexOfSelectedItem == 0 && list.count == 1 { nearby.selectItem(at: 1) }
            }
            if !working {
                if !list.isEmpty { spinner.stopAnimation(nil); status.stringValue = "找到 \(list.count) 台正在邀请的设备" }
                else if scanUntil.map({ $0 <= Date() }) == true {
                    spinner.stopAnimation(nil); status.stringValue = "暂未找到设备。确认在同一网络，或展开手动连接。"
                }
            }
            validate()
        } else if mode == .invite {
            let list = state["pending"] as? [[String: Any]] ?? []
            let ids = list.compactMap { $0["id"] as? String }
            pending.isHidden = ids.isEmpty
            guard ids != pendingIDs else { return }; pendingIDs = ids
            if !ids.isEmpty { consumed = true }
            updateCountdown()
            SyncUI.replace(pending, with: list.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let name = item["name"] as? String ?? "新设备"
                return SettingsCard([SyncUI.text("“\(name)”请求加入", weight: .medium),
                    SyncUI.row([SyncUI.spacer(), SyncActionButton("拒绝") { [weak self] in self?.reject?(id) },
                        SyncActionButton("允许加入", primary: true) { [weak self] in self?.approve?(id, name) }])], padding: 14, spacing: 10)
            })
        }
    }
    private func updateCountdown() {
        guard mode == .invite, !approved else { return }
        if consumed {
            pairingCode.stringValue = pendingIDs.isEmpty ? "邀请已结束" : "等待确认"
            codeCaption.stringValue = pendingIDs.isEmpty ? "本次邀请已结束" : "等待你的确认"
            countdown.stringValue = pendingIDs.isEmpty ? "如需继续添加，请重新生成配对码" : "请核对设备名称，再允许加入"
            status.stringValue = pendingIDs.isEmpty ? "需要添加设备时，可重新生成邀请。" : "已收到加入请求，请确认是否为你的设备。"
            copyCode?.isEnabled = false; copyConnection?.isEnabled = false
            return
        }
        let seconds = max(0, Int(ceil(expiry?.timeIntervalSinceNow ?? 0)))
        codeCaption.stringValue = seconds > 0 ? "在另一台电脑输入" : "配对码已失效"
        countdown.stringValue = seconds > 0 ? String(format: "%d:%02d 后过期", seconds / 60, seconds % 60) : "配对码已过期，请重新生成"
        copyCode?.isEnabled = seconds > 0 && !working; copyConnection?.isEnabled = seconds > 0 && !working
        if seconds == 0 && invitationValue != nil { pairingCode.stringValue = "已过期" }
    }
    func showApproved(_ name: String) {
        approved = true; codeCaption.stringValue = "已允许设备加入"; countdown.stringValue = "设备已获准加入"; pairingCode.stringValue = "已确认"
        status.stringValue = "“\(name)”已获准加入，连接后会自动同步。"
        copyCode?.isEnabled = false; copyConnection?.isEnabled = false
        timer?.invalidate(); timer = nil
    }
    func reportError(_ message: String?) { error.stringValue = message ?? ""; error.isHidden = message == nil }
    private func copyManualConnection() {
        guard let value = invitationValue, let invite = value["invite"] as? String,
              let port = value["port"] as? Int, expiry.map({ $0 > Date() }) == true else { return }
        let addresses = Host.current().addresses.filter { address in
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 10 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 169 && parts[1] == 254
        }
        guard let address = addresses.first else { reportError("没有找到可用的局域网地址，请检查网络后重试。"); return }
        if addresses.count > 1, let copyConnection {
            let menu = NSMenu()
            let title = NSMenuItem(title: "选择另一台电脑能连接的地址", action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
            for address in addresses {
                let item = NSMenuItem(title: address, action: #selector(copyAddress(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = address; menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: copyConnection.bounds.height + 4), in: copyConnection)
            return
        }
        copyConnectionText(address: address, port: port, invite: invite)
    }
    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String, let value = invitationValue,
              let invite = value["invite"] as? String, let port = value["port"] as? Int,
              !consumed, !approved, expiry.map({ $0 > Date() }) == true else { return }
        copyConnectionText(address: address, port: port, invite: invite)
    }
    private func copyConnectionText(address: String, port: Int, invite: String) {
        let text = "Rime Q 连接信息\n连接地址：\(address):\(port)\n邀请标识：\(invite)"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        status.stringValue = "连接信息已复制。在另一台电脑的“手动连接”中粘贴。"
    }
    private func pasteConnection() {
        guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 4096,
              let address = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("连接地址：") }),
              let invite = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("邀请标识：") }) else {
            reportError("剪贴板中没有 Rime Q 连接信息，请从原设备的邀请窗口复制。"); return
        }
        self.address.stringValue = String(address.dropFirst("连接地址：".count))
        invitation.stringValue = String(invite.dropFirst("邀请标识：".count)); reportError(nil); validate()
    }
    private func dismiss() {
        if mode == .join && working && !cancelling {
            cancelling = true; cancel.isEnabled = false; status.stringValue = "正在取消加入…"
            Task {
                do { _ = try await sync.request(["action": "cancel_join"]) }
                catch { cancelling = false; cancel.isEnabled = true; reportError(error.localizedDescription) }
            }
            return
        }
        guard !working, !closing else { return }
        if mode != .invite { closeSheet(); return }
        closing = true; setWorking(true, message: "正在关闭邀请…")
        Task {
            do { _ = try await sync.request(["action": "cancel_invite"]); closeSheet() }
            catch { closing = false; setWorking(false); reportError(error.localizedDescription) }
        }
    }
    private func closeSheet() {
        timer?.invalidate(); timer = nil
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        finished?()
    }
    func joinForSmoke(address: String, invite: String, code: String) throws {
        manual.state = .on; toggleManual()
        deviceName.stringValue = "取消验证设备"
        self.address.stringValue = address; invitation.stringValue = invite
        self.code.stringValue = "12"; validate()
        try EngineSmoke.check(!primary.isEnabled, "incomplete pairing code enabled Join")
        self.code.stringValue = code; validate()
        try EngineSmoke.check(primary.isEnabled, "valid pairing form could not join")
        primary.performClick(nil)
        try EngineSmoke.check(working && cancel.isEnabled, "joining did not expose cancellation")
    }
    func cancelForSmoke() { cancel.performClick(nil) }

    private func capturePreview(to path: URL, appearance: NSAppearance.Name) throws {
        guard let window, let view = window.contentView else { return }
        window.appearance = NSAppearance(named: appearance); window.orderFront(nil); window.makeFirstResponder(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LexiconError.message("sync sheet bitmap unavailable") }
        window.appearance!.performAsCurrentDrawingAppearance { view.displayIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LexiconError.message("sync sheet PNG unavailable") }
        try LexiconFiles.write(data, to: path)
    }
    static func renderPreviews(to directory: URL) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for mode in [Mode.create, .join, .invite] {
                let sheet = DeviceSyncSheet(mode: mode, sync: .shared)
                sheet.deviceName.stringValue = "我的 MacBook Pro"
                if mode == .invite {
                    sheet.pairingCode.stringValue = "••• •••"; sheet.countdown.stringValue = "配对码仅在邀请时显示"
                    sheet.status.stringValue = "等待另一台电脑输入配对码…"
                } else if mode == .join {
                    sheet.update(state: ["discovered": [["address": "192.0.2.1:1", "invite": "synthetic", "name": "家里的 Mac mini"]]])
                }
                let name = mode == .create ? "create" : mode == .join ? "join" : "invite"
                try sheet.capturePreview(to: directory.appendingPathComponent("\(name)-\(suffix).png"), appearance: appearance)
                if mode == .invite {
                    sheet.update(state: ["pending": [["id": "synthetic", "name": "办公室的 MacBook Air"]]])
                    try sheet.capturePreview(to: directory.appendingPathComponent("approve-\(suffix).png"), appearance: appearance)
                }
            }
        }
    }
}
