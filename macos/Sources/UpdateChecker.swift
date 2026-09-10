import AppKit

struct ReleaseVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        let clean = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        guard clean.range(of: pattern, options: .regularExpression) == clean.startIndex..<clean.endIndex else { return nil }
        let version = clean.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
        numbers = version[0].split(separator: ".").compactMap { Int($0) }
        prerelease = version.count == 2 ? version[1].split(separator: ".").map(String.init) : []
        guard numbers.count == 3, !prerelease.contains(where: { Self.numeric($0) && $0.count > 1 && $0.hasPrefix("0") }) else { return nil }
    }

    private static func numeric(_ text: String) -> Bool { text.allSatisfy { $0.isASCII && $0.isNumber } }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = numeric(left), rn = numeric(right)
            if ln != rn { return ln }
            if ln && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum ReleaseLookup: Equatable {
    case unpublished, current, available(String), invalid

    static func parse(data: Data, status: Int, installed: String) -> ReleaseLookup {
        if status == 404 { return .unpublished }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let latest = ReleaseVersion(tag), latest.prerelease.isEmpty,
              let current = ReleaseVersion(installed) else { return .invalid }
        return current < latest ? .available(tag) : .current
    }

    var title: String {
        switch self {
        case .unpublished: return "暂时没有公开发布的版本"
        case .current: return "没有发现更新版本"
        case .available(let tag): return "发现新版本 \(tag)"
        case .invalid: return "暂时无法检查更新"
        }
    }
}

/// All state and callbacks stay on the main thread; networking never blocks input.
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let didChange = Notification.Name("RimeQ.UpdateChecker.didChange")
    static let interval: TimeInterval = 24 * 60 * 60
    static let endpoint = URL(string: "https://api.github.com/repos/asmoyou/rime-Q/releases/latest")!
    private let defaults: UserDefaults
    private let session: URLSession
    private let installed: String
    private let now: () -> Date
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var manualCompletion: ((ReleaseLookup) -> Void)?
    private(set) var isChecking = false
    private(set) var result: ReleaseLookup?

    init(defaults: UserDefaults = .standard, session: URLSession? = nil,
         installed: String = Product.version, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.installed = installed; self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
        if let tag = defaults.string(forKey: "updates.availableTag"),
           let latest = ReleaseVersion(tag), let current = ReleaseVersion(installed), current < latest {
            result = .available(tag)
        } else if defaults.string(forKey: "updates.resultVersion") == installed {
            switch defaults.string(forKey: "updates.lastResult") {
            case "current": result = .current
            case "unpublished": result = .unpublished
            case "invalid": result = .invalid
            default: break
            }
        }
    }
    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var automatic: Bool {
        get { defaults.object(forKey: "updates.automatic") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "updates.automatic")
            schedule(); changed()
        }
    }
    var lastAttempt: Date? { defaults.object(forKey: "updates.lastAttempt") as? Date }
    var availableTag: String? {
        guard let tag = defaults.string(forKey: "updates.availableTag"), let latest = ReleaseVersion(tag),
              let current = ReleaseVersion(installed), current < latest else { return nil }
        return tag
    }
    var nextAutomaticCheck: Date? {
        guard automatic else { return nil }
        let date = now()
        guard let lastAttempt, lastAttempt <= date else { return date }
        return max(date, lastAttempt.addingTimeInterval(Self.interval))
    }

    func start() {
        guard !started else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.schedule() }
        schedule()
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard started, !isChecking, let date = nextAutomaticCheck else { return }
        // Let launch/wake and input-service initialization settle first.
        let timer = Timer(timeInterval: max(30, date.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            self?.checkIfDue()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func checkIfDue() {
        guard let date = nextAutomaticCheck, date <= now() else { schedule(); return }
        check()
    }
    /// An explicit check bypasses the daily limit and joins any in-flight request.
    func check(manual: ((ReleaseLookup) -> Void)? = nil) {
        if let manual { manualCompletion = manual }
        guard !isChecking else { return }
        isChecking = true
        timer?.invalidate(); timer = nil
        // Count failed attempts too: an offline machine must not retry all day.
        defaults.set(now(), forKey: "updates.lastAttempt")
        changed()
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RimeQ/" + installed, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let outcome = error == nil
                ? ReleaseLookup.parse(data: data ?? Data(), status: (response as? HTTPURLResponse)?.statusCode ?? 0, installed: self.installed)
                : .invalid
            DispatchQueue.main.async {
                self.isChecking = false
                self.result = outcome
                if case .available(let tag) = outcome { self.defaults.set(tag, forKey: "updates.availableTag") }
                else if outcome != .invalid { self.defaults.removeObject(forKey: "updates.availableTag") }
                let summary: String
                switch outcome {
                case .available: summary = "available"
                case .current: summary = "current"
                case .unpublished: summary = "unpublished"
                case .invalid: summary = "invalid"
                }
                self.defaults.set(summary, forKey: "updates.lastResult")
                self.defaults.set(self.installed, forKey: "updates.resultVersion")
                let completion = self.manualCompletion
                self.manualCompletion = nil
                self.schedule(); self.changed()
                completion?(outcome)
            }
        }.resume()
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
