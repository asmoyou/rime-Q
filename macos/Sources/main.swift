import AppKit
import Carbon
import InputMethodKit
import QRimeBridge

let arguments = CommandLine.arguments
if let status = inputSourceInstallPhaseExitStatus(arguments: arguments) { exit(status) }
if arguments.count > 1 {
    do {
        switch arguments[1] {
        case "--version": print("Rime Q \(Product.version) (\(Product.build))")
        case "--candidate-smoke": try CandidateAppearanceSmoke.run()
        case "--candidate-preview": CandidateAppearanceSmoke.preview(dark: arguments.contains("dark"))
        case "--smoke": try EngineSmoke.run()
        case "--benchmark": try EngineSmoke.benchmark()
        case "--controller-smoke": try ControllerSmoke.run()
        case "--installation-smoke": try installationFlowSmoke()
        case "--maintenance-smoke": try AppMaintenance.smoke()
        case "--uninstall-preview":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            AppMaintenance.uninstall(preview: true)
        case "--complete-install", "--retry-install":
            completeInputSourceInstallation(isLoginRetry: arguments[1] == "--retry-install")
        case "--installation-preview" where arguments.count == 3:
            guard let readiness = InstallationReadiness(rawValue: arguments[2]) else { exit(2) }
            showInstallationResult(readiness, retryScheduled: readiness == .pending, allowSystemActions: false)
        case "--render" where arguments.count == 3:
            try RenderSmoke.run(destination: URL(fileURLWithPath: arguments[2]))
        case "--smoke-phase" where arguments.count == 4:
            try EngineSmoke.phase(arguments[2], user: URL(fileURLWithPath: arguments[3]))
        case "--prepare" where arguments.count == 3:
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-deploy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Engine.start(user: temporary, deploy: true)
            QRimeStop()
            let destination = URL(fileURLWithPath: arguments[2])
            try FileManager.default.copyItem(at: temporary.appendingPathComponent("build"), to: destination)
            print("Prepared bundled dictionaries")
        case "--register", "--activate-source":
            guard installInputSource(selectAfterEnabling: arguments[1] == "--activate-source") else {
                exit(75)
            }
        default:
            fputs("Usage: RimeQ --smoke | --benchmark | --prepare DEST | --register\n", stderr)
            exit(2)
        }
        exit(0)
    } catch {
        fputs("Rime Q: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: IMKServer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(prepareUpdateQuit(_:)),
            name: UpdateQuitRequest.name, object: Bundle.main.bundleURL.path)
        // Do not expose an input controller while ensureSession() still fails.
        // IMK can finish connecting after launch instead of losing initial keys.
        do {
            try Engine.start(user: Product.userRoot.appendingPathComponent("rime"))
            Engine.ready = true
            server = IMKServer(name: Product.connection, bundleIdentifier: Product.identifier)
            guard server != nil else { NSApp.terminate(nil); return }
        } catch {
            Engine.failure = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "Rime Q 暂时无法启动"
            alert.informativeText = "输入资源未能加载，请重新安装。你的个人词库会保留。\n" + error.localizedDescription
            alert.runModal()
        }
    }
    @objc private func prepareUpdateQuit(_ notification: Notification) {
        guard UpdateQuitRequest.accepts(notification, appPath: Bundle.main.bundleURL.path,
                                       processID: ProcessInfo.processInfo.processIdentifier) else { return }
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        if Engine.ready { QRimeStop() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
