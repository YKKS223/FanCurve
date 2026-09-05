import Foundation
import FanCurveKit

/// Minimal newline-delimited-JSON server on a Unix domain socket.
/// One thread accepts, one thread per connection handles requests.
final class SocketServer {
    private let path: String
    private let handler: (DaemonRequest) -> DaemonResponse
    private var listenFD: Int32 = -1
    private var running = false

    init(path: String, handler: @escaping (DaemonRequest) -> DaemonResponse) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        // sun_path is 104 bytes on macOS; a longer path would overrun the struct.
        let maxLen = MemoryLayout<sockaddr_un>.size - MemoryLayout<UInt8>.size * 2
        guard path.utf8.count < maxLen else {
            throw NSError(domain: "fancurved", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "ソケットパスが長すぎます (\(path.utf8.count) バイト、上限 \(maxLen - 1)): \(path)"])
        }
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "fancurved", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "socket() 失敗"]) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }

        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(listenFD)
            throw NSError(domain: "fancurved", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bind(\(path)) 失敗: \(String(cString: strerror(errno)))"])
        }

        // Readable/writable by root and the `staff` group, which every local account belongs to.
        // The GUI runs as the logged-in user and needs to reach the socket.
        chmod(path, 0o660)
        if let grp = getgrnam("staff") {
            chown(path, 0, grp.pointee.gr_gid)
        }

        guard Darwin.listen(listenFD, 8) == 0 else {
            Darwin.close(listenFD)
            throw NSError(domain: "fancurved", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "listen() 失敗"])
        }

        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd < 0 {
                if !running { return }
                if errno == EINTR { continue }
                usleep(100_000)
                continue
            }
            Thread.detachNewThread { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])

            // Handle every complete line currently in the buffer.
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard !line.isEmpty else { continue }

                let response: DaemonResponse
                if let req = try? JSONDecoder().decode(DaemonRequest.self, from: line) {
                    response = handler(req)
                } else {
                    response = .failure("リクエストを解釈できません")
                }
                guard var out = try? JSONEncoder().encode(response) else { return }
                out.append(0x0a)
                let sent: Bool = out.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let w = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                        if w <= 0 { return false }
                        off += w
                    }
                    return true
                }
                if !sent { return }
            }
        }
    }
}
