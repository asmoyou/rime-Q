import Foundation
import CryptoKit
import QRimeBridge

struct ModelDescriptor: Codable {
    let file: String
    let bytes: Int64
    let sha256: String
    let url: URL

    static var bundled: ModelDescriptor? {
        guard let url = Bundle.main.url(forResource: "optional-model", withExtension: "json"),
              let data = try? Data(contentsOf: url), let descriptor = try? JSONDecoder().decode(Self.self, from: data),
              descriptor.file == "wanxiang-lts-zh-hans.gram", descriptor.bytes > 0,
              descriptor.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              descriptor.url.scheme == "https", descriptor.url.host == "github.com" else { return nil }
        return descriptor
    }
    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func verify(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == bytes else {
            throw LexiconError.message("模型文件不完整，请重新下载。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw LexiconError.message("模型校验未通过，请重新下载。")
        }
    }
}

enum ModelState: Equatable {
    case missing, checking, downloading(Int64), verifying, waiting, ready, failed(String)
    var busy: Bool {
        switch self { case .checking, .downloading, .verifying, .waiting: return true; default: return false }
    }
}

/// The model is an explicitly downloaded resource. No network activity on init/start.
/// State changes stay on the main thread; download and SHA-256 run off that thread.
final class OptionalModel: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = OptionalModel(root: Product.userRoot)
    static let didChange = Notification.Name("RimeQ.OptionalModel.didChange")
    let root: URL
    let descriptor: ModelDescriptor?
    private let defaults: UserDefaults
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()
    private var task: URLSessionDownloadTask?
    private var operation = UUID().uuidString
    private var enableAfterDownload = false
    private var lastProgress: TimeInterval = 0 // download delegate queue only
    private(set) var state: ModelState = .missing
    private(set) var available = false
    private(set) var activeOptimization = false
    var enabled: Bool { available && defaults.bool(forKey: "sentenceOptimization") }
    var directory: URL { root.appendingPathComponent("models", isDirectory: true) }
    var fileURL: URL { directory.appendingPathComponent(descriptor?.file ?? "wanxiang-lts-zh-hans.gram") }
    private var linkURL: URL { root.appendingPathComponent("rime", isDirectory: true).appendingPathComponent(fileURL.lastPathComponent) }

    init(root: URL, defaults: UserDefaults = .standard, descriptor: ModelDescriptor? = .bundled,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.root = root; self.defaults = defaults; self.descriptor = descriptor
        self.configuration = configuration
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        super.init()
    }
    var statusDescription: String {
        switch state {
        case .missing: return "未下载 · \(descriptor?.sizeDescription ?? "模型信息不可用")"
        case .checking: return "正在检查本地模型…"
        case .downloading(let received):
            return "正在下载 \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(descriptor?.sizeDescription ?? "")"
        case .verifying: return "下载完成，正在校验…"
        case .waiting: return "等待当前输入结束后生效…"
        case .ready: return enabled ? "已下载 · 整句优化已开启" : "已下载 · 可离线使用"
        case .failed(let reason): return reason
        }
    }
    private func change(_ state: ModelState) {
        precondition(Thread.isMainThread)
        self.state = state
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    func restore() {
        guard !state.busy, !available, let descriptor,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        operation = UUID().uuidString
        let id = operation, url = fileURL
        change(.checking)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try descriptor.verify(url) }
            DispatchQueue.main.async {
                guard self.operation == id else { return }
                do { try result.get(); try self.activate(id: id, enable: false) }
                catch { self.change(.failed(error.localizedDescription)) }
            }
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard available else { return }
        defaults.set(enabled, forKey: "sentenceOptimization")
        Engine.whenInputFinished { [weak self] in
            guard let self else { return }
            self.activeOptimization = self.available && self.defaults.bool(forKey: "sentenceOptimization")
            self.change(self.state)
        }
        change(state)
    }
    private func attach() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if let target = try? fm.destinationOfSymbolicLink(atPath: linkURL.path), target == fileURL.path { return }
        guard (try? fm.attributesOfItem(atPath: linkURL.path)) == nil else {
            throw LexiconError.message("个人数据目录中已有同名模型文件，请先移走该文件后重试。")
        }
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
    }
    private func activate(id: String, enable: Bool) throws {
        try attach()
        change(.waiting)
        Engine.whenInputFinished { [weak self] in
            guard let self, self.operation == id else { return }
            self.available = true
            if enable { self.defaults.set(true, forKey: "sentenceOptimization") }
            self.activeOptimization = self.defaults.bool(forKey: "sentenceOptimization")
            self.change(.ready)
        }
    }
    func download(enableAfterwards: Bool = true) {
        guard !state.busy else { return }
        if available { if enableAfterwards { setEnabled(true) }; return }
        guard let descriptor else { change(.failed("模型信息不可用，请重新安装 Rime Q。")); return }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { change(.failed("无法保存模型，请检查个人数据目录。")); return }
        operation = UUID().uuidString
        enableAfterDownload = enableAfterwards
        var request = URLRequest(url: descriptor.url)
        request.setValue("RimeQ/" + Product.version, forHTTPHeaderField: "User-Agent")
        task = session.downloadTask(with: request)
        task?.taskDescription = operation
        change(.downloading(0))
        task?.resume()
    }
    func cancel() {
        guard state.busy else { return }
        operation = UUID().uuidString
        task?.cancel(); task = nil
        change(available ? .ready : .missing)
    }
    func shutdown() { cancel(); session.invalidateAndCancel() }
    func remove() throws {
        guard available, !state.busy else { return }
        defaults.set(false, forKey: "sentenceOptimization")
        operation = UUID().uuidString
        let id = operation
        change(.waiting)
        Engine.whenInputFinished { [weak self] in
            guard let self, self.operation == id else { return }
            do {
                self.activeOptimization = false
                let fm = FileManager.default
                if (try? fm.destinationOfSymbolicLink(atPath: self.linkURL.path)) == self.fileURL.path {
                    try fm.removeItem(at: self.linkURL)
                }
                try fm.removeItem(at: self.fileURL)
                self.available = false
                if Engine.ready, Engine.userDirectory?.standardizedFileURL == self.linkURL.deletingLastPathComponent().standardizedFileURL,
                   let shared = Engine.sharedDirectory {
                    try Engine.useResources(shared, persist: {})
                }
                self.change(.missing)
            } catch { self.change(.failed("模型移除未完成：" + error.localizedDescription)) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let descriptor, let id = downloadTask.taskDescription else { return }
        if totalBytesWritten > descriptor.bytes {
            downloadTask.cancel()
            DispatchQueue.main.async {
                guard self.operation == id else { return }
                self.operation = UUID().uuidString; self.task = nil
                self.change(.failed("下载内容与模型信息不一致，请稍后重试。"))
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgress >= 0.1 || totalBytesWritten == descriptor.bytes else { return }
        lastProgress = now
        DispatchQueue.main.async {
            guard self.operation == id else { return }
            self.change(.downloading(totalBytesWritten))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let descriptor, let id = downloadTask.taskDescription, UUID(uuidString: id) != nil else { return }
        let staged = directory.appendingPathComponent(".download-" + id)
        let result = Result { () throws -> URL in
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LexiconError.message("模型下载暂时不可用，请稍后重试。")
            }
            try FileManager.default.moveItem(at: location, to: staged)
            DispatchQueue.main.async { if self.operation == id { self.change(.verifying) } }
            try descriptor.verify(staged)
            return staged
        }
        DispatchQueue.main.async {
            defer { try? FileManager.default.removeItem(at: staged) }
            guard self.operation == id else { return }
            self.task = nil
            do {
                let source = try result.get()
                let fm = FileManager.default
                if fm.fileExists(atPath: self.fileURL.path) { try fm.removeItem(at: self.fileURL) }
                try fm.moveItem(at: source, to: self.fileURL)
                try self.activate(id: id, enable: self.enableAfterDownload)
            } catch { self.change(.failed(error.localizedDescription)) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let id = task.taskDescription else { return }
        DispatchQueue.main.async {
            guard self.operation == id else { return }
            self.task = nil
            self.change(.failed("下载失败，请检查网络后重试。"))
        }
    }
}
