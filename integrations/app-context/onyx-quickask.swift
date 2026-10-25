// Read-only active-document metadata for Quick Ask. Onyx's answer runners stay read-only.
private final class OnyxQuickAskContext {
    private let listener: Int32
    private final class Reply {
        let lock = NSLock()
        var value: [String: Any]?
        func set(_ value: [String: Any]?) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
    }
    init?(snapshot: @escaping (@escaping ([String: Any]?) -> Void) -> Void) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuickAsk/Context")
        var info = stat()
        if lstat(directory.path, &info) == 0 && ((info.st_mode & S_IFMT) != S_IFDIR || info.st_uid != getuid()) { return nil }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        guard chmod(directory.path, 0o700) == 0 else { return nil }
        let path = directory.appendingPathComponent("onyx.sock").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return nil }
        let alive = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        close(probe)
        guard !alive else { return nil }
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard bound, chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { close(listener); return nil }
        let fd = listener
        DispatchQueue(label: "com.cx.onyx.quickask-context", qos: .userInitiated).async {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var buffer = [UInt8](repeating: 0, count: 256), data = Data()
                while data.count < 256 {
                    let count = Darwin.read(client, &buffer, min(buffer.count, 256 - data.count))
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    if data.contains(10) { break }
                }
                guard let query = try? JSONSerialization.jsonObject(with: data) as? [String: String], query == ["op": "context"] else { continue }
                let reply = Reply(), ready = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { snapshot { reply.set($0); ready.signal() } }
                let value: Any = ready.wait(timeout: .now() + 0.22) == .success ? (reply.get() as Any? ?? NSNull()) : NSNull()
                if var encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoded.count < 32_000 {
                    encoded.append(10)
                    encoded.withUnsafeBytes { _ = Darwin.write(client, $0.baseAddress, encoded.count) }
                }
            }
        }
    }
}
