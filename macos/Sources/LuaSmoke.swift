import Foundation
import QRimeBridge

enum LuaSmoke {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimeq-lua-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Engine.start(user: root)
        defer { QRimeStop() }
        for schema in ["rime_q", "rime_q_grammar"] {
            let session = QRimeCreateSession()
            defer { QRimeDestroySession(session) }
            try EngineSmoke.check(QRimeSchema(session, schema), "Lua test schema missing")
            QRimeSetOption(session, "ascii_mode", false)
            let examples: [(String, String)] = [
                ("rq", #"^\d{4}-\d{2}-\d{2}$"#), ("sj", #"^\d{2}:\d{2}$"#),
                ("xq", "^星期[一二三四五六日天]$"), ("dt", #"^\d{4}-\d{2}-\d{2}T"#),
                ("ts", #"^\d{10}$"#), ("rqzh", "年.*月.*日$"), ("rqen", #"[A-Za-z]+.*\d{4}$"#),
                ("nl", "年.*月"), ("N20240210", "甲辰龙年正月初一"),
                ("uuid", #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#),
                ("U62fc", "^拼$"), ("R123.45", "壹佰贰拾叁元肆角伍分"), ("cC1+2*3", "^7$"),
                ("cC(1+2)*3", "^9$")
            ]
            for (input, pattern) in examples {
                QRimeClear(session)
                _ = QRimeTakeCommit(session)
                EngineSmoke.type(input, session: session)
                let candidates = Engine.snapshot(session).candidates
                guard let match = candidates.first(where: { $0.text.range(of: pattern, options: .regularExpression) != nil }) else {
                    throw LexiconError.message("Lua \(schema)/\(input) missing expected result; candidates=\(candidates.map(\.text))")
                }
                try EngineSmoke.choose(match.text, session: session)
                try EngineSmoke.check(String(cString: QRimeTakeCommit(session)) == match.text, "Lua candidate did not commit: \(input)")
            }
            for (key, expected) in [("[", "你"), ("]", "好")] {
                QRimeClear(session); EngineSmoke.type("nihao", session: session)
                EngineSmoke.type(key, session: session)
                try EngineSmoke.check(String(cString: QRimeTakeCommit(session)) == expected, "Word character selection failed")
            }
            QRimeClear(session); EngineSmoke.type("nihao", session: session)
            try EngineSmoke.choose("你好", session: session)
            try EngineSmoke.check(String(cString: QRimeTakeCommit(session)) == "你好", "Lua utilities changed normal pinyin input")
            print("PASS Lua \(schema): date/time/week/ISO/timestamp/calendar/UUID/Unicode/amount/calculator/character selection; candidates commit correctly")
        }
    }
}
