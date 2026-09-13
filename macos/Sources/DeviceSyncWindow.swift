import AppKit

@MainActor final class DeviceSyncWindow: NSWindowController {
    private let content = NSStackView()
    private let status = SettingsUI.label("正在读取设备状态…", secondary: true)
    private let body = NSStackView()
    private let members = NSStackView(), pending = NSStackView()
    private let group = NSTextField(string: "我的电脑")
    private let name = NSTextField(string: Host.current().localizedName ?? "我的 Mac")
    private let address = NSTextField(), invitation = NSTextField(), code = NSTextField()
    private let nearby = NSPopUpButton()
    private let invitationDetails = SettingsUI.label("", secondary: true)
    private var timer: Timer?
    private var refreshing = false, working = false
    private var shownGroup: String?
    private var state: [String: Any] = [:]
    private var actions: [ObjectIdentifier: () async throws -> Void] = [:]

    init() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "附近设备同步"; window.minSize = .init(width: 560, height: 540); window.center()
        super.init(window: window)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; window.contentView = scroll
        for stack in [content, body, members, pending] { stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12 }
        content.edgeInsets = .init(top: 24, left: 24, bottom: 24, right: 24); content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        NSLayoutConstraint.activate([content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        content.addArrangedSubview(SettingsUI.label("附近设备同步", size: 23))
        content.addArrangedSubview(SettingsUI.label("每台电脑加入一次，组内自动同步已有及后续个人词条和学习权重。仅在信任的局域网开启；本地网络授权用于发现和连接设备，拒绝后仍可正常打字。", secondary: true))
        content.addArrangedSubview(status); content.addArrangedSubview(body)
        invitationDetails.isSelectable = true
        nearby.target = self; nearby.action = #selector(selectNearby)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in guard self?.window?.isVisible == true else { return }; Task { await self?.refresh() } } }
        Task { do { try await DeviceSync.shared.ensureStarted(); await refresh() } catch { status.stringValue = error.localizedDescription } }
    }
    deinit { timer?.invalidate() }
    private func button(_ title: String, action: @escaping () async throws -> Void) -> NSButton {
        let value = SettingsUI.button(title, target: self, action: #selector(invoke(_:)))
        actions[ObjectIdentifier(value)] = action; return value
    }
    @objc private func invoke(_ sender: NSButton) {
        guard !working, let action = actions[ObjectIdentifier(sender)] else { return }
        working = true; sender.isEnabled = false
        Task { defer { working = false; sender.isEnabled = true }
            do { try await action(); await refresh() } catch { status.stringValue = error.localizedDescription }
        }
    }
    private func field(_ label: String, _ value: NSTextField) {
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        body.addArrangedSubview(SettingsUI.label(label)); body.addArrangedSubview(value)
    }
    private func clear(_ stack: NSStackView) { for view in stack.arrangedSubviews { if let b = view as? NSButton { actions.removeValue(forKey: ObjectIdentifier(b)) }; stack.removeArrangedSubview(view); view.removeFromSuperview() } }
    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认")
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            try await DeviceSync.shared.ensureStarted()
            state = try await DeviceSync.shared.request(["action": "status"])
            let group = state["group"] as? [String: Any], id = group?["id"] as? String
            if shownGroup != id || body.arrangedSubviews.isEmpty { shownGroup = id; build(group != nil) }
            guard let group else {
                status.stringValue = "尚未加入同步组。可以创建，或加入现有设备的同步组。"
                nearby.removeAllItems(); nearby.addItem(withTitle: "选择附近正在邀请的设备")
                for item in (state["discovered"] as? [[String: Any]] ?? []) where !(item["invite"] as? String ?? "").isEmpty {
                    nearby.addItem(withTitle: item["name"] as? String ?? "Rime Q 设备"); nearby.lastItem?.representedObject = item
                }
                return
            }
            let devices = (state["members"] as? [[String: Any]] ?? []).filter { $0["removed"] as? Bool != true }
            status.stringValue = "\(group["name"] as? String ?? "我的电脑") · \(devices.count) 台设备 · \(devices.filter { $0["online"] as? Bool == true }.count) 台在线" + (state["enabled"] as? Bool == true ? "" : " · 已暂停")
            if let error = DeviceSync.shared.lastError { status.stringValue += "\n" + error }
            if let error = state["network_error"] as? String { status.stringValue += "\n" + error }
            clear(members); clear(pending)
            for device in devices {
                let name = device["name"] as? String ?? "设备", id = device["id"] as? String ?? ""
                let label = SettingsUI.label(name + (device["self"] as? Bool == true ? "（本机）" : "") + "\n" + (device["online"] as? Bool == true ? (device["applied"] as? Bool == true ? "已应用当前已知变更" : "正在同步或等待当前输入结束") : "等待上线"))
                members.addArrangedSubview(label)
                if device["self"] as? Bool != true && state["can_remove"] as? Bool == true { members.addArrangedSubview(button("移除设备") { [weak self] in
                    guard self?.confirm("移除“\(name)”？", detail: "本机立即停止与其同步，其他设备收到移除记录后生效。已经复制的词条无法远程收回。") == true else { return }
                    _ = try await DeviceSync.shared.request(["action": "remove", "id": id])
                }) }
            }
            for item in state["pending"] as? [[String: Any]] ?? [] {
                let id = item["id"] as? String ?? ""; pending.addArrangedSubview(SettingsUI.label("\(item["name"] as? String ?? "新设备") 请求加入"))
                pending.addArrangedSubview(button("确认加入") { _ = try await DeviceSync.shared.request(["action": "approve", "id": id]) })
                pending.addArrangedSubview(button("拒绝") { _ = try await DeviceSync.shared.request(["action": "reject", "id": id]) })
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func selectNearby() {
        guard let item = nearby.selectedItem?.representedObject as? [String: Any] else { return }
        address.stringValue = item["address"] as? String ?? ""; invitation.stringValue = item["invite"] as? String ?? ""
    }
    private func build(_ joined: Bool) {
        clear(body)
        if !joined {
            field("这台电脑的名称", name); field("新同步组名称", group)
            body.addArrangedSubview(button("创建同步组") { [weak self] in
                guard let self else { return }
                _ = try await DeviceSync.shared.request(["action": "create", "group": group.stringValue, "name": name.stringValue]); DeviceSync.shared.markStarted()
            })
            body.addArrangedSubview(button("查找附近正在邀请的设备") { _ = try await DeviceSync.shared.request(["action": "discover"]) })
            body.addArrangedSubview(nearby); field("连接地址（找不到设备时，由原设备复制）", address)
            field("邀请标识（选择附近设备后自动填写）", invitation); field("原设备显示的六位配对码", code)
            body.addArrangedSubview(button("加入同步组") { [weak self] in
                guard let self else { return }; status.stringValue = "正在配对，请在原设备确认加入…"
                _ = try await DeviceSync.shared.request(["action": "join", "address": address.stringValue, "invite": invitation.stringValue, "code": code.stringValue, "name": name.stringValue])
                code.stringValue = ""; DeviceSync.shared.markStarted()
            })
        } else {
            body.addArrangedSubview(SettingsUI.label("已授权设备均可邀请新电脑；移除设备请在创建同步组的电脑操作。日常同步无需创建者在线。", secondary: true))
            body.addArrangedSubview(members); body.addArrangedSubview(pending)
            body.addArrangedSubview(button("添加设备") { [weak self] in
                let value = try await DeviceSync.shared.request(["action": "invite"])
                let port = value["port"] as? Int ?? 0
                let addresses = (Host.current().addresses ?? []).filter { !$0.contains(":") && $0 != "127.0.0.1" }.map { "\($0):\(port)" }.joined(separator: "、")
                self?.invitationDetails.stringValue = "六位配对码：\(value["code"] as? String ?? "")\n五分钟内有效，输入后还需在此电脑确认。\n连接地址：\(addresses)\n邀请标识：\(value["invite"] as? String ?? "")"
            }); body.addArrangedSubview(invitationDetails)
            body.addArrangedSubview(button("取消邀请") { [weak self] in _ = try await DeviceSync.shared.request(["action": "cancel_invite"]); self?.invitationDetails.stringValue = "" })
            body.addArrangedSubview(button("立即同步") { _ = try await DeviceSync.shared.request(["action": "sync_now"]); await DeviceSync.shared.tick() })
            body.addArrangedSubview(button("暂停 / 恢复同步") { [weak self] in _ = try await DeviceSync.shared.request(["action": self?.state["enabled"] as? Bool == true ? "pause" : "resume"]) })
            body.addArrangedSubview(button("处理未完成的同步") { [weak self] in
                guard self?.confirm("采用本机当前词库继续？", detail: "这会覆盖本轮待应用的同步结果，并向其他设备同步本机的新增、修改与删除。两份快照会先备份。") == true else { return }
                try await DeviceSync.shared.recoverLocal()
            })
            body.addArrangedSubview(button("退出这台电脑") { [weak self] in
                guard self?.confirm("退出同步组？", detail: "保留本机个人词库，并归档同步记录。组内旧身份需创建者移除；如果本机就是创建者，退出后原组将无法再移除成员。重新加入会生成新身份。") == true else { return }
                try await DeviceSync.shared.leave()
            })
            body.addArrangedSubview(button("查看同步恢复快照") { let url = DeviceSync.shared.root.appendingPathComponent("backups"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) })
        }
    }
}
