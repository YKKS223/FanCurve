import Foundation

public enum ClientError: Error, CustomStringConvertible {
    case notRunning
    case ioFailed(String)
    case badReply

    public var description: String {
        switch self {
        case .notRunning:      return "fancurved が起動していません（sudo ./scripts/install.sh を実行してください）"
        case .ioFailed(let m): return "通信エラー: \(m)"
        case .badReply:        return "デーモンの応答を解釈できません"
        }
    }
}

/// Synchronous newline-delimited-JSON client for the daemon's Unix socket.
/// Call from a background queue; `FanCurveApp` wraps it in an actor.
public final class DaemonClient {
    private let path: String

    public init(path: String = IPC.socketPath) { self.path = path }

    public func send(_ request: DaemonRequest) throws -> DaemonResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.ioFailed("socket() 失敗") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.ioFailed("ソケットパスが長すぎます")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.notRunning }

        var tv = timeval(tv_sec: 20, tv_usec: 0)   // the probe command takes ~15 s
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0a)
        try payload.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { throw ClientError.ioFailed("write() 失敗") }
                off += n
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { throw ClientError.ioFailed("read() 失敗") }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.last == 0x0a { break }
        }
        guard !buffer.isEmpty else { throw ClientError.badReply }
        if buffer.last == 0x0a { buffer.removeLast() }
        guard let reply = try? JSONDecoder().decode(DaemonResponse.self, from: buffer) else {
            throw ClientError.badReply
        }
        return reply
    }
}
