import AppKit
import Carbon

enum InstallationReadiness: String {
    case ready, pending, failed
}

struct InstallationFiles {
    static let retryLabel = "com.asmoyou.rimeq.activation"
    let root: URL
    let agents: URL
    var status: URL { root.appendingPathComponent("installation-status.plist") }
    var retryAgent: URL { agents.appendingPathComponent(Self.retryLabel + ".plist") }

    static var current: InstallationFiles {
        InstallationFiles(root: Product.userRoot, agents: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true))
    }

    /// Retry once at the next GUI login. It also goes through LaunchServices;
    /// invoking the input-method executable from an installer shell is insufficient.
    func record(_ readiness: InstallationReadiness, app: URL, isLoginRetry: Bool) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let retry = readiness == .pending && !isLoginRetry
        if fm.fileExists(atPath: retryAgent.path) {
            guard (try? fm.destinationOfSymbolicLink(atPath: retryAgent.path)) == nil,
                  let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: retryAgent), format: nil) as? [String: Any],
                  value["Label"] as? String == Self.retryLabel else {
                throw NSError(domain: "RimeQ.Installation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "登录重试文件被其他内容占用。"])
            }
            try fm.removeItem(at: retryAgent)
        }
        if retry {
            try fm.createDirectory(at: agents, withIntermediateDirectories: true)
            let agent: [String: Any] = [
                "Label": Self.retryLabel,
                "ProgramArguments": ["/usr/bin/open", "-n", "-g", app.path, "--args", "--retry-install"],
                "RunAtLoad": true, "LimitLoadToSessionType": "Aqua", "ProcessType": "Background"
            ]
            try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                .write(to: retryAgent, options: .atomic)
        }
        let value: [String: Any] = ["state": readiness.rawValue, "retryScheduled": retry,
                                    "updatedAt": Date(), "appPath": app.path,
                                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: status, options: .atomic)
        return retry
    }
}

private func requestLogoutConfirmation() -> OSStatus {
    // kAELogOut asks loginwindow to show its normal logout confirmation.
    // Never use kAEReallyLogOut or a forced shutdown command here.
    var system = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
    var target = AEAddressDesc()
    var event = AppleEvent()
    var result = AECreateDesc(DescType(typeProcessSerialNumber), &system,
                             MemoryLayout<ProcessSerialNumber>.size, &target)
    guard result == noErr else { return OSStatus(result) }
    defer { AEDisposeDesc(&target) }
    result = AECreateAppleEvent(AEEventClass(kCoreEventClass), AEEventID(kAELogOut), &target,
                               AEReturnID(kAutoGenerateReturnID), AETransactionID(kAnyTransactionID), &event)
    guard result == noErr else { return OSStatus(result) }
    defer { AEDisposeDesc(&event) }
    return AESendMessage(&event, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
}

func showInstallationResult(_ readiness: InstallationReadiness, retryScheduled: Bool,
                            detail: String = "", allowSystemActions: Bool = true) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    switch readiness {
    case .ready:
        alert.messageText = "Rime Q 已启用"
        alert.informativeText = "现在可以从菜单栏的输入法菜单选择 Rime Q，开始输入。"
        alert.addButton(withTitle: "完成")
        alert.addButton(withTitle: "打开键盘设置")
    case .pending:
        alert.messageText = "Rime Q 已安装，尚未启用"
        alert.informativeText = retryScheduled
            ? "可以稍后处理，或保存工作后注销并重新登录。下次登录时会自动重试启用。"
            : "启用检查仍未通过。请打开键盘设置，尝试添加 Rime Q。"
        alert.addButton(withTitle: "稍后处理")
        if retryScheduled { alert.addButton(withTitle: "注销账户…") }
        alert.addButton(withTitle: "打开键盘设置")
    case .failed:
        alert.messageText = "Rime Q 安装尚未完成"
        alert.informativeText = "请重新打开安装包完成安装。" + (detail.isEmpty ? "" : "\n" + detail)
        alert.addButton(withTitle: "关闭")
    }
    // The default action never logs out; session changes require that button.
    alert.buttons.first?.keyEquivalent = "\r"
    app.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard allowSystemActions else { return }
    if readiness == .pending && retryScheduled && response == .alertSecondButtonReturn {
        let result = requestLogoutConfirmation()
        if result != noErr {
            let notice = NSAlert()
            notice.messageText = "请从苹果菜单注销"
            notice.informativeText = "保存工作后，选择苹果菜单中的“注销”，再重新登录。"
            notice.addButton(withTitle: "稍后处理")
            notice.runModal()
        }
    } else if readiness != .failed && response == (readiness == .pending && retryScheduled
                ? .alertThirdButtonReturn : .alertSecondButtonReturn) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

func completeInputSourceInstallation(isLoginRetry: Bool) {
    _ = NSApplication.shared
    guard inputSourceInstallPhaseExitStatus(arguments: ["RimeQ", "--rimeq-tis-validate-bundle"]) == 0 else {
        showInstallationResult(.failed, retryScheduled: false)
        return
    }
    if !isLoginRetry {
        do { try AppMaintenance.prepareInstalledUpdate() }
        catch {
            showInstallationResult(.failed, retryScheduled: false, detail: error.localizedDescription)
            return
        }
    }
    let readiness: InstallationReadiness = installInputSource() ? .ready : .pending
    do {
        let retry = try InstallationFiles.current.record(readiness, app: Bundle.main.bundleURL,
                                                        isLoginRetry: isLoginRetry)
        print("installation: state=\(readiness.rawValue) retryScheduled=\(retry)")
        // A successful automatic login retry requires no additional user action.
        if !(isLoginRetry && readiness == .ready) {
            showInstallationResult(readiness, retryScheduled: retry)
        }
    } catch {
        // A storage failure must not misreport the actual input-source state.
        print("installation: could not record result: \(error.localizedDescription)")
        showInstallationResult(readiness, retryScheduled: false, detail: error.localizedDescription)
    }
}

func installationFlowSmoke() throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent("rimeq-install-test-" + UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let files = InstallationFiles(root: temporary.appendingPathComponent("state"),
                                  agents: temporary.appendingPathComponent("agents"))
    let app = URL(fileURLWithPath: "/Library/Input Methods/RimeQ.app")
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "RimeQ.InstallationTest", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    try require(try files.record(.pending, app: app, isLoginRetry: false), "Pending activation did not schedule a retry")
    let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: files.retryAgent), format: nil) as! [String: Any]
    try require(agent["ProgramArguments"] as? [String] == ["/usr/bin/open", "-n", "-g", app.path, "--args", "--retry-install"],
                "Login retry must use the same LaunchServices path")
    try require(agent["RunAtLoad"] as? Bool == true && agent["KeepAlive"] == nil, "Retry must run once per login")
    try require(!(try files.record(.pending, app: app, isLoginRetry: true)), "A failed login retry must not create a retry loop")
    try require(!fm.fileExists(atPath: files.retryAgent.path), "Used login retry was not removed")
    _ = try files.record(.pending, app: app, isLoginRetry: false)
    _ = try files.record(.ready, app: app, isLoginRetry: false)
    try require(!fm.fileExists(atPath: files.retryAgent.path), "Successful activation left an automatic retry")
    let status = try PropertyListSerialization.propertyList(from: Data(contentsOf: files.status), format: nil) as! [String: Any]
    try require(status["state"] as? String == "ready" && status["retryScheduled"] as? Bool == false,
                "Saved installation state does not match activation")
    try Data("unrelated contents".utf8).write(to: files.retryAgent)
    do {
        _ = try files.record(.ready, app: app, isLoginRetry: false)
        throw NSError(domain: "RimeQ.InstallationTest", code: 2)
    } catch {
        try require(try String(contentsOf: files.retryAgent) == "unrelated contents", "Unrelated file was replaced")
    }
    print("PASS installation flow: pending state, LaunchServices retry, single retry, success cleanup, unrelated file protection")
}
