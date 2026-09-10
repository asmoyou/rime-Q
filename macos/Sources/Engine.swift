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
    static let connection = "RimeQ_Connection"
    static let userRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RimeQ", isDirectory: true)
    static var schema: String {
        UserDefaults.standard.bool(forKey: "sentenceOptimization") ? "rime_q_grammar" : "rime_q"
    }
}

enum Engine {
    static var ready = false
    static var failure: String?

    static func start(user: URL, deploy: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: user, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        guard QRimeStart(contents.appendingPathComponent("Frameworks").path,
                         contents.appendingPathComponent("SharedSupport").path, user.path, deploy) else {
            throw NSError(domain: "RimeQ", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: QRimeError())])
        }
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
