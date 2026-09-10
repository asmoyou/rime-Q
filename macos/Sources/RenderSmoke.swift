import AppKit

enum RenderSmoke {
    static func run(destination: URL) throws {
        _ = NSApplication.shared
        let state = Composition(preedit: "ni hao", input: "nihao", cursorUTF16: 6, highlighted: 0,
                                candidates: [CandidateItem(text: "你好", comment: ""),
                                             CandidateItem(text: "您好", comment: ""),
                                             CandidateItem(text: "拟好", comment: ""),
                                             CandidateItem(text: "你", comment: "nǐ"),
                                             CandidateItem(text: "呢", comment: "ní")])
        let view = CandidateCanvas(frame: .zero)
        view.composition = state
        view.appearance = NSAppearance(named: .aqua)
        view.setFrameSize(view.measuredSize())
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "RimeQRender", code: 1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RimeQRender", code: 2)
        }
        try png.write(to: destination)
        print("Rendered native candidate view")
    }
}
