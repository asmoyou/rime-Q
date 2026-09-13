import AppKit
import Carbon
import InputMethodKit
import QRimeBridge

let arguments = CommandLine.arguments
var finishInstallationAsServer = false
var installationIsLoginRetry = false
if let status = inputSourceInstallPhaseExitStatus(arguments: arguments) { exit(status) }
if arguments.count > 1 {
    do {
        switch arguments[1] {
        case "--version": print("Rime Q \(Product.version) (\(Product.build))")
        case "--compile-dictionaries" where arguments.count == 3:
            try DictionaryResources.compileHelper(URL(fileURLWithPath: arguments[2]))
        case "--settings-render" where arguments.count == 3:
            try SettingsWindow.render(to: URL(fileURLWithPath: arguments[2]))
        case "--sync-ui-render" where arguments.count == 3:
            _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
            try MainActor.assumeIsolated { try DeviceSyncWindow.renderPreviews(to: URL(fileURLWithPath: arguments[2])) }
        case "--sync-test-node" where arguments.count == 3:
            try MainActor.assumeIsolated { try DeviceSyncSmoke.node(root: URL(fileURLWithPath: arguments[2])) }
        case "--personal-dictionary-smoke": try DictionarySmoke.personal()
        case "--dictionary-resources-smoke": try DictionarySmoke.resources()
        case "--settings-ui-smoke": try SettingsWindow.smoke()
        case "--candidate-smoke": try CandidateAppearanceSmoke.run()
        case "--candidate-render" where arguments.count == 3:
            try CandidateAppearanceSmoke.render(to: URL(fileURLWithPath: arguments[2]))
        case "--candidate-preview": CandidateAppearanceSmoke.preview(dark: arguments.contains("dark"))
        case "--smoke": try EngineSmoke.run()
        case "--lua-smoke": try LuaSmoke.run()
        case "--benchmark": try EngineSmoke.benchmark()
        case "--controller-smoke": try ControllerSmoke.run()
        case "--installation-smoke": try installationFlowSmoke()
        case "--maintenance-smoke": try AppMaintenance.smoke()
        case "--maintenance-quit-worker" where arguments.count == 3:
            try AppMaintenance.quitWorker(root: URL(fileURLWithPath: arguments[2]))
        case "--update-smoke": try UpdateSmoke.run()
        case "--optional-model-smoke" where arguments.count == 3:
            try ModelSmoke.run(server: URL(string: arguments[2])!)
        case "--optional-model-reuse-smoke" where arguments.count == 5:
            try ModelSmoke.reuse(root: URL(fileURLWithPath: arguments[2]), server: URL(string: arguments[3])!, phase: arguments[4])
        case "--optional-model-live-smoke": try ModelSmoke.live()
        case "--optional-model-engine-smoke" where arguments.count == 3:
            try ModelSmoke.live(localSource: URL(fileURLWithPath: arguments[2]))
        case "--update-live-smoke" where arguments.count == 4:
            try UpdateSmoke.live(installed: arguments[2], expected: arguments[3])
        case "--runtime-smoke": try RuntimeReadinessSmoke.run()
        case "--runtime-smoke-worker" where arguments.count == 4:
            try RuntimeReadinessSmoke.worker(root: URL(fileURLWithPath: arguments[2]), ready: arguments[3] == "ready")
        case "--verify-runtime":
            _ = NSApplication.shared
            guard let identity = RuntimeReadiness.probe() else { fputs("Rime Q input server has not responded.\n", stderr); exit(75) }
            print("PASS input server responding: build=\(identity.build) pid=\(identity.pid)")
        case "--uninstall-preview":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            AppMaintenance.uninstall(preview: true)
        case "--complete-install", "--retry-install":
            installationIsLoginRetry = arguments[1] == "--retry-install"
            finishInstallationAsServer = completeInputSourceInstallation(isLoginRetry: installationIsLoginRetry)
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
        if !finishInstallationAsServer { exit(0) }
    } catch {
        fputs("Rime Q: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: IMKServer?
    var runtimeResponder: RuntimeResponder?
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = UpdateQuitObserver.shared
        // Do not expose an input controller while ensureSession() still fails.
        // IMK can finish connecting after launch instead of losing initial keys.
        do {
            let resources: URL
            do { resources = try DictionaryResources.shared.activeResources() }
            catch {
                resources = Engine.bundledShared
                DictionaryResources.shared.reportUnavailable(error.localizedDescription)
            }
            do { try Engine.start(user: Product.userRoot.appendingPathComponent("rime"), shared: resources) }
            catch {
                guard resources != Engine.bundledShared else { throw error }
                QRimeStop()
                DictionaryResources.shared.reportUnavailable("自定义词库未能加载，已使用内置词库。可在设置中重新应用或恢复内置配置。")
                try Engine.start(user: Product.userRoot.appendingPathComponent("rime"))
            }
            Engine.ready = true
            server = IMKServer(name: Product.connection, bundleIdentifier: Product.identifier)
            guard server != nil else { throw LexiconError.message("系统输入服务未能建立连接。") }
            runtimeResponder = RuntimeResponder { [weak self] in Engine.ready && self?.server != nil }
            InstallationDiagnostics.append("input-server-ready")
            DictionaryResources.shared.refreshBundledConfigurationIfNeeded()
            UpdateChecker.shared.start()
            OptionalModel.shared.restore()
            DeviceSync.shared.startIfEnabled()
            if finishInstallationAsServer {
                do {
                    _ = try InstallationFiles.current.record(.ready, app: Bundle.main.bundleURL,
                        isLoginRetry: false, runtimePID: ProcessInfo.processInfo.processIdentifier)
                } catch { InstallationDiagnostics.append("could-not-record-ready-status") }
                InstallationDiagnostics.append("activation-complete serving-in-installer-process")
            }
        } catch {
            Engine.failure = error.localizedDescription
            Engine.ready = false
            QRimeStop()
            if finishInstallationAsServer {
                _ = try? InstallationFiles.current.record(.pending, app: Bundle.main.bundleURL, isLoginRetry: installationIsLoginRetry)
            }
            InstallationDiagnostics.append("input-server-start-failed")
            let alert = NSAlert()
            alert.messageText = "Rime Q 暂时无法启动"
            alert.informativeText = "输入资源未能加载，请重新安装。你的个人词库会保留。\n" + error.localizedDescription
            alert.runModal()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        DeviceSync.shared.stop()
        if Engine.ready { QRimeStop() }
        InstallationDiagnostics.append("input-server-stopped")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
