import Foundation
import QRimeBridge

struct CandidateItem {
    let text: String
    let comment: String
}

struct Composition {
    var preedit = ""
    var input = ""
    var cursorUTF16 = 0
    var highlighted = 0
    var page = 0
    var lastPage = true
    var candidates: [CandidateItem] = []
    var active: Bool { !input.isEmpty || !preedit.isEmpty || !candidates.isEmpty }
}

enum Product {
    static let identifier = "com.asmoyou.inputmethod.RimeQ"
    static let homepage = URL(string: "https://github.com/asmoyou/rime-Q")!
    static let downloads = homepage.appendingPathComponent("releases")
    static let connection = identifier + "_Connection"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "本地"
    static var versionDescription: String { "版本 \(version) · 构建 \(build)" }
    static let userRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RimeQ", isDirectory: true)
    static var schema: String {
        OptionalModel.shared.activeOptimization ? "rime_q_grammar" : "rime_q"
    }
}

enum Engine {
    static var ready = false {
        didSet {
            if ready != oldValue { NotificationCenter.default.post(name: readinessChanged, object: nil) }
        }
    }
    static var failure: String?
    static let willMaintain = Notification.Name("RimeQWillMaintainEngine")
    static let readinessChanged = Notification.Name("RimeQEngineReadinessChanged")
    static var userDirectory: URL?
    static var sharedDirectory: URL?
    static var bundledShared: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport") }

    static func start(user: URL, deploy: Bool = false, shared: URL? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: user, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let resources = shared ?? bundledShared
        guard QRimeStart(contents.appendingPathComponent("Frameworks").path,
                         resources.path, user.path, deploy) else {
            throw NSError(domain: "RimeQ", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: QRimeError())])
        }
        userDirectory = user
        sharedDirectory = resources
        failure = nil
    }

    // All live-engine calls remain on the main thread. Compilation runs in a
    // separate helper process and cannot access the live learning dictionary.
    static func maintain<T>(_ operation: () throws -> T) throws -> T {
        precondition(Thread.isMainThread)
        guard ready else { throw LexiconError.message("输入引擎尚未就绪，请稍后重试。") }
        NotificationCenter.default.post(name: willMaintain, object: nil)
        ready = false
        defer { ready = failure == nil }
        return try operation()
    }

    static func useResources(_ shared: URL, persist: () throws -> Void) throws {
        guard let user = userDirectory, let previous = sharedDirectory else {
            throw LexiconError.message("输入引擎尚未就绪。")
        }
        try maintain {
            QRimeStop()
            do {
                try start(user: user, shared: shared)
                try persist()
            } catch {
                let originalError = error
                QRimeStop()
                do { try start(user: user, shared: previous) }
                catch {
                    failure = "词库切换失败，原词库也未能重新加载。请重新启动 Rime Q。"
                    throw LexiconError.message(failure!)
                }
                throw originalError
            }
        }
    }

    static func whenInputFinished(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard InputSession.hasComposition else { action(); return }
        // Exists only while an explicitly requested resource update is ready.
        // Never commit a user's partial composition when a compiler finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenInputFinished(action) }
    }

    static func snapshot(_ session: UInt) -> Composition {
        guard QRimeRead(session) else { return Composition() }
        let preedit = String(cString: QRimePreedit())
        let bytes = Array(preedit.utf8.prefix(max(0, Int(QRimeCursorBytes()))))
        return Composition(preedit: preedit, input: String(cString: QRimeInput()),
                           cursorUTF16: String(decoding: bytes, as: UTF8.self).utf16.count,
                           highlighted: Int(QRimeHighlighted()), page: Int(QRimePage()),
                           lastPage: QRimeLastPage(),
                           candidates: (0..<QRimeCandidateCount()).map {
                               CandidateItem(text: String(cString: QRimeCandidateText($0)),
                                             comment: String(cString: QRimeCandidateComment($0)))
                           })
    }
}
