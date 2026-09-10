import AppKit
import Carbon

enum UpdateQuitRequest {
    static let name = Notification.Name("com.asmoyou.rimeq.requestUpdateQuit")

    static func accepts(_ notification: Notification, appPath: String, processID: Int32) -> Bool {
        guard notification.name == name, notification.object as? String == appPath,
              let target = notification.userInfo?["targetPID"] as? NSNumber,
              let sender = notification.userInfo?["senderPID"] as? NSNumber else { return false }
        return target.int32Value == processID && sender.int32Value > 0 && sender.int32Value != processID
    }
}

enum ReleaseLookup {
    case unpublished, current, available(String), invalid

    static func version(_ text: String) -> [Int]? {
        let clean = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard let base = clean.split(separator: "-", maxSplits: 1).first else { return nil }
        let parts = base.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 && numbers.allSatisfy { $0 >= 0 } ? numbers : nil
    }

    static func parse(data: Data, status: Int, installed: String) -> ReleaseLookup {
        if status == 404 { return .unpublished }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let latest = version(tag), let current = version(installed) else { return .invalid }
        return current.lexicographicallyPrecedes(latest) ? .available(tag) : .current
    }
}

enum AppMaintenance {
    static let releases = Product.downloads
    private static var checkingUpdates = false

    static func openAbout() {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let credits = NSMutableAttributedString(string: "免费开源 · 官方版本无需购买\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        credits.append(NSAttributedString(string: "项目主页", attributes: [.link: Product.homepage, .paragraphStyle: paragraph]))
        credits.append(NSAttributedString(string: "  ·  "))
        credits.append(NSAttributedString(string: "官方下载", attributes: [.link: Product.downloads, .paragraphStyle: paragraph]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Rime Q", .applicationVersion: Product.version, .version: Product.build,
            .credits: credits
        ])
    }

    static func openProject() { NSWorkspace.shared.open(Product.homepage) }
    static func openDownloads() { NSWorkspace.shared.open(Product.downloads) }

    static func openHelp() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Help") {
            NSWorkspace.shared.open(url)
        }
    }

    static func checkForUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        let installed = Product.version
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/asmoyou/rime-Q/releases/latest")!)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RimeQ/" + installed, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = error == nil
                ? ReleaseLookup.parse(data: data ?? Data(), status: (response as? HTTPURLResponse)?.statusCode ?? 0, installed: installed)
                : .invalid
            DispatchQueue.main.async {
                checkingUpdates = false
                let alert = NSAlert()
                switch result {
                case .unpublished:
                    alert.messageText = "暂时没有公开发布的更新"
                    alert.informativeText = "当前版本：\(installed)（开发预览）。项目尚未发布可供检查的正式版本。"
                case .current:
                    alert.messageText = "没有发现更新版本"
                    alert.informativeText = "当前版本：\(installed)。"
                case .available(let tag):
                    alert.messageText = "发现新版本 \(tag)"
                    alert.informativeText = "当前版本：\(installed)。可以前往发布页面查看说明并下载。"
                case .invalid:
                    alert.messageText = "暂时无法检查更新"
                    alert.informativeText = "请稍后再试，或打开发布页面查看。"
                }
                alert.addButton(withTitle: "关闭")
                alert.addButton(withTitle: "打开发布页面")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releases) }
            }
        }.resume()
    }

    private static func sourceString(_ source: TISInputSource, _ key: CFString) -> String {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func sourceBool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "RimeQ.Maintenance", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// An updated bundle must not keep serving keys from an older running image.
    /// Request a normal quit only from other instances at this exact app path.
    static func prepareInstalledUpdate() throws {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Product.identifier).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
        guard !others.isEmpty else { return }
        if sourceString(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyBundleID) == Product.identifier {
            let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
            guard let fallback = sources.first(where: {
                sourceString($0, kTISPropertyBundleID) != Product.identifier
                    && sourceBool($0, kTISPropertyInputSourceIsASCIICapable)
                    && sourceBool($0, kTISPropertyInputSourceIsSelectCapable)
            }), TISSelectInputSource(fallback) == noErr else {
                throw error("请先切换到其他输入法，再完成 Rime Q 的安装。")
            }
        }
        // Current versions cooperate without asking to automate another app.
        // Only older versions lacking this listener need the Apple-events fallback.
        for application in others {
            DistributedNotificationCenter.default().postNotificationName(
                UpdateQuitRequest.name, object: Bundle.main.bundleURL.path,
                userInfo: ["targetPID": application.processIdentifier,
                           "senderPID": ProcessInfo.processInfo.processIdentifier], deliverImmediately: true)
        }
        let cooperativeDeadline = Date().addingTimeInterval(0.8)
        while others.contains(where: { !$0.isTerminated }) && Date() < cooperativeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for application in others where !application.isTerminated { _ = application.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard others.allSatisfy({ $0.isTerminated }) else {
            throw error("旧版本尚未退出，请关闭旧版本后重新打开安装包。")
        }
    }

    private static func leaveAndDisableInputSource() throws {
        let enabled = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           sourceString(current, kTISPropertyBundleID) == Product.identifier {
            guard let fallback = enabled.first(where: {
                sourceString($0, kTISPropertyBundleID) != Product.identifier
                    && sourceBool($0, kTISPropertyInputSourceIsASCIICapable)
                    && sourceBool($0, kTISPropertyInputSourceIsSelectCapable)
            }), TISSelectInputSource(fallback) == noErr,
            sourceString(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyBundleID) != Product.identifier else {
                throw error("请先从菜单栏切换到其他输入法，再卸载 Rime Q。")
            }
        }
        let all = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
        for identifier in [Product.identifier + ".Hans", Product.identifier] {
            for source in all where sourceString(source, kTISPropertyInputSourceID) == identifier {
                guard TISDisableInputSource(source) == noErr else { throw error("输入法停用未完成，请稍后重试。") }
            }
        }
    }

    static func uninstall(preview: Bool = false) {
        let app = Bundle.main.bundleURL.standardizedFileURL
        let systemApp = URL(fileURLWithPath: "/Library/Input Methods/RimeQ.app")
        let userApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/RimeQ.app")
        guard preview || app == systemApp || app == userApp else {
            showError("请从已安装的 Rime Q 菜单执行卸载。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "卸载 Rime Q？"
        alert.informativeText = "将停用并移除 Rime Q 应用。个人词库和学习记录会保留，其他输入法不受影响。\n移除系统目录中的应用时，macOS 会要求管理员认证。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "卸载应用")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn, !preview else { return }
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let previousID = sourceString(previous, kTISPropertyInputSourceID)
        do {
            try leaveAndDisableInputSource()
            let unregister = Process()
            unregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            unregister.arguments = ["-u", app.path]
            try unregister.run()
            unregister.waitUntilExit()
            if app == systemApp {
                guard let helper = Bundle.main.url(forResource: "uninstall-system", withExtension: "sh") else {
                    throw error("卸载组件缺失，请按使用说明中的步骤卸载。")
                }
                let command = "/bin/bash " + shellQuote(helper.path)
                let source = "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
                var details: NSDictionary?
                guard let script = NSAppleScript(source: source) else { throw error("无法启动卸载认证。") }
                script.executeAndReturnError(&details)
                if let details { throw error(details[NSAppleScript.errorMessage] as? String ?? "卸载已取消。") }
            } else {
                try FileManager.default.trashItem(at: app, resultingItemURL: nil)
            }
            guard !FileManager.default.fileExists(atPath: app.path) else { throw error("应用尚未移除，卸载未完成。") }
            // Remove only our own pending retry. Personal Rime data stays untouched.
            _ = try? InstallationFiles.current.record(.failed, app: app, isLoginRetry: true)
            let done = NSAlert()
            done.messageText = "Rime Q 已卸载"
            done.informativeText = "个人词库仍保留在“\(Product.userRoot.path)”。"
            done.addButton(withTitle: "完成")
            done.runModal()
            NSApp.terminate(nil)
        } catch {
            if FileManager.default.fileExists(atPath: app.path) {
                _ = installInputSource()
                let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
                if let source = sources.first(where: { sourceString($0, kTISPropertyInputSourceID) == previousID }) {
                    _ = TISSelectInputSource(source)
                }
            }
            showError(error.localizedDescription)
        }
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "卸载未完成"
        alert.informativeText = text
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    static func smoke() throws {
        let appPath = "/Library/Input Methods/RimeQ.app"
        let quit = Notification(name: UpdateQuitRequest.name, object: appPath,
                                userInfo: ["targetPID": 101, "senderPID": 202])
        let selfQuit = Notification(name: UpdateQuitRequest.name, object: appPath,
                                    userInfo: ["targetPID": 101, "senderPID": 101])
        guard UpdateQuitRequest.accepts(quit, appPath: appPath, processID: 101),
              !UpdateQuitRequest.accepts(quit, appPath: appPath, processID: 303),
              !UpdateQuitRequest.accepts(quit, appPath: "/another/app", processID: 101),
              !UpdateQuitRequest.accepts(selfQuit, appPath: appPath, processID: 101) else {
            throw error("更新退出请求的进程与路径限制测试失败。")
        }
        guard case .available("v0.1.10") = ReleaseLookup.parse(data: Data(#"{"tag_name":"v0.1.10"}"#.utf8), status: 200, installed: "0.1.2"),
              case .current = ReleaseLookup.parse(data: Data(#"{"tag_name":"0.1.2"}"#.utf8), status: 200, installed: "0.1.10"),
              case .unpublished = ReleaseLookup.parse(data: Data(), status: 404, installed: "0.1.2"),
              case .invalid = ReleaseLookup.parse(data: Data(), status: 403, installed: "0.1.2"),
              ReleaseLookup.version("malformed") == nil,
              ReleaseLookup.version("") == nil else { throw error("更新版本比较测试失败。") }
        let session = InputSession()
        let menu = session.makeMenu()!
        for item in menu.items {
            guard let selector = item.action else { continue }
            guard NSStringFromSelector(selector).hasSuffix(":"), session.responds(to: selector),
                  RimeQController.instancesRespond(to: selector) else {
                throw error("InputMethodKit 菜单动作必须接收 sender，并由控制器响应。")
            }
        }
        print("PASS maintenance: update-quit scope, numeric versions, release errors, and IMK menu action signatures")
    }
}
