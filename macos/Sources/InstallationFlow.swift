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
    func record(_ readiness: InstallationReadiness, app: URL, isLoginRetry: Bool, runtimePID: Int32? = nil) throws -> Bool {
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
        var value: [String: Any] = ["state": readiness.rawValue, "retryScheduled": retry,
                                    "updatedAt": Date(), "appPath": app.path,
                                    "inputServerReady": readiness == .ready && runtimePID != nil,
                                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
        if let runtimePID { value["runtimePID"] = runtimePID }
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

/// true transfers this LaunchServices-launched process into the normal input
/// server. Never exit after registration while leaving no serving process.
func completeInputSourceInstallation(isLoginRetry: Bool) -> Bool {
    _ = NSApplication.shared
    // Keep only installation diagnostics here; no keystrokes or user text.
    try? FileManager.default.createDirectory(at: Product.userRoot, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let logPath = Product.userRoot.appendingPathComponent("installation.log").path
    // Retain the previous activation attempt, including before a login retry.
    if let attributes = try? FileManager.default.attributesOfItem(atPath: logPath),
       (attributes[.size] as? NSNumber)?.intValue ?? 0 > 512 * 1024,
       attributes[.type] as? FileAttributeType == .typeRegular {
        let previous = Product.userRoot.appendingPathComponent("installation-previous.log")
        do {
            try LexiconFiles.write(Data(contentsOf: URL(fileURLWithPath: logPath)), to: previous)
            try FileManager.default.removeItem(atPath: logPath)
        } catch { /* Keep the existing diagnostics if rotation fails. */ }
    }
    InstallationDiagnostics.append("activation-begin loginRetry=\(isLoginRetry)")
    let savedOut = dup(STDOUT_FILENO), savedError = dup(STDERR_FILENO)
    defer {
        fflush(stdout); fflush(stderr)
        if savedOut >= 0 { _ = dup2(savedOut, STDOUT_FILENO); close(savedOut) }
        if savedError >= 0 { _ = dup2(savedError, STDERR_FILENO); close(savedError) }
    }
    let logDescriptor = Darwin.open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    if logDescriptor >= 0 {
        _ = dup2(logDescriptor, STDOUT_FILENO)
        _ = dup2(logDescriptor, STDERR_FILENO)
        close(logDescriptor)
    }
    guard inputSourceInstallPhaseExitStatus(arguments: ["RimeQ", "--rimeq-tis-validate-bundle"]) == 0 else {
        showInstallationResult(.failed, retryScheduled: false)
        return false
    }
    let existing = RuntimeReadiness.probe(timeout: 0.35)
    if existing == nil {
        do { try AppMaintenance.prepareInstalledUpdate() }
        catch {
            showInstallationResult(.failed, retryScheduled: false, detail: error.localizedDescription)
            return false
        }
    }
    let readiness: InstallationReadiness = installInputSource() ? .ready : .pending
    if readiness == .ready {
        if let existing {
            _ = try? InstallationFiles.current.record(.ready, app: Bundle.main.bundleURL,
                isLoginRetry: isLoginRetry, runtimePID: existing.pid)
            InstallationDiagnostics.append("activation-complete existing-server pid=\(existing.pid)")
            return false
        }
        do {
            // Invalidate stale success from a prior build. Start the service in
            // this process; AppDelegate records ready only after initialization.
            _ = try InstallationFiles.current.record(.pending, app: Bundle.main.bundleURL, isLoginRetry: true)
        } catch { print("installation: could not record startup phase: \(error.localizedDescription)") }
        InstallationDiagnostics.append("sources-enabled; continuing as input server")
        return true
    }
    do {
        let retry = try InstallationFiles.current.record(readiness, app: Bundle.main.bundleURL,
                                                        isLoginRetry: isLoginRetry)
        print("installation: state=\(readiness.rawValue) retryScheduled=\(retry)")
        fflush(stdout)
        // Successful installation is silent; Installer already has a completion page.
        if readiness != .ready {
            showInstallationResult(readiness, retryScheduled: retry)
        }
    } catch {
        // A storage failure must not misreport the actual input-source state.
        print("installation: could not record result: \(error.localizedDescription)")
        if readiness != .ready {
            showInstallationResult(readiness, retryScheduled: false, detail: error.localizedDescription)
        }
    }
    return false
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
    try require(InputSourceInstallRules.validConnectionName(Product.connection, bundleID: Product.identifier), "Runtime connection does not match bundle identifier")
    try require(!InputSourceInstallRules.validConnectionName("RimeQ_Connection", bundleID: Product.identifier), "Legacy connection name accepted")
    try require(!InputSourceInstallRules.validConnectionName(nil, bundleID: Product.identifier), "Missing connection name accepted")
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
    try require(status["inputServerReady"] as? Bool == false, "TIS-only result claimed serving readiness")
    _ = try files.record(.ready, app: app, isLoginRetry: false, runtimePID: 321)
    let serving = try PropertyListSerialization.propertyList(from: Data(contentsOf: files.status), format: nil) as! [String: Any]
    try require(serving["inputServerReady"] as? Bool == true && serving["runtimePID"] as? Int == 321,
                "Serving process identity was not recorded")
    try Data("unrelated contents".utf8).write(to: files.retryAgent)
    do {
        _ = try files.record(.ready, app: app, isLoginRetry: false)
        throw NSError(domain: "RimeQ.InstallationTest", code: 2)
    } catch {
        try require(try String(contentsOf: files.retryAgent) == "unrelated contents", "Unrelated file was replaced")
    }
    print("PASS installation flow: pending state, LaunchServices retry, single retry, success cleanup, unrelated file protection")
}
