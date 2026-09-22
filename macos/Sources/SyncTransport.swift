import Foundation
import Darwin

// Called only on a utility queue. One authenticated loopback connection per
// request; no helper process launch and no access to dictionary contents here.
enum SyncTransport {
    static func request(root: URL, data: Data) throws -> [String: Any] {
        struct Descriptor: Decodable { let address: String; let token: String }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: root.appendingPathComponent("control.json")))
        let parts = descriptor.address.split(separator: ":")
        guard parts.count == 2, parts[0] == "127.0.0.1", let port = UInt16(parts[1]), port > 0 else {
            throw NSError(domain: "RimeQ.Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid control address"])
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 145, tv_usec: 0)
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else { throw socketError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw socketError() }
        let value = try JSONSerialization.jsonObject(with: data)
        let body = try JSONSerialization.data(withJSONObject: ["token": descriptor.token, "request": value])
        guard body.count <= 96 * 1024 * 1024 else { throw socketError(EMSGSIZE) }
        var count = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }; frame.append(body)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw socketError() }
                offset += sent
            }
        }
        func read(_ size: Int) throws -> Data {
            var result = Data(count: size)
            try result.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < size {
                    let received = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                    if received < 0 && errno == EINTR { continue }
                    guard received > 0 else { throw socketError(received == 0 ? ECONNRESET : errno) }
                    offset += received
                }
            }
            return result
        }
        let prefix = try read(4)
        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 96 * 1024 * 1024 else { throw socketError(EMSGSIZE) }
        guard let response = try JSONSerialization.jsonObject(with: read(size)) as? [String: Any] else { throw socketError(EPROTO) }
        guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
            throw NSError(domain: "RimeQ.Sync", code: 2, userInfo: [NSLocalizedDescriptionKey: response["error"] as? String ?? "sync request failed"])
        }
        return result
    }
    private static func socketError(_ code: Int32 = errno) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}
