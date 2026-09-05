import Foundation
import CSMC

public enum SMCError: Error, CustomStringConvertible {
    case notAvailable
    case openFailed
    case keyNotFound(String)
    case callFailed(String, Int32, UInt8)
    case notRoot
    case sizeMismatch(String)

    public var description: String {
        switch self {
        case .notAvailable:            return "AppleSMC サービスが見つかりません"
        case .openFailed:              return "AppleSMC を開けません"
        case .keyNotFound(let k):      return "SMC キー \(k) がありません"
        case .callFailed(let k, let c, let smc):
            return "SMC 書き込み拒否 \(k) (rc=\(c), SMC status=0x\(String(smc, radix: 16)) \(Self.statusName(smc)))"
        case .notRoot:                 return "SMC への書き込みには root 権限が必要です"
        case .sizeMismatch(let k):     return "SMC キー \(k) のサイズが一致しません"
        }
    }
}

public extension SMCError {
    /// Firmware status codes seen in the wild; anything else is reported as-is.
    public static func statusName(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "成功"
        case 0x82: return "書き込み拒否（値が不正、またはキーがロック済み）"
        case 0x84: return "キーが存在しない"
        case 0x85: return "書き込み不可"
        case 0x89: return "引数が不正"
        default:   return "不明"
        }
    }
}

public struct SMCKeyMeta {
    public let key: String
    public let type: String
    public let size: UInt32
    public let attributes: UInt8
    public var isReadable: Bool { attributes & UInt8(CSMC_ATTR_READABLE) != 0 }
    public var isWritable: Bool { attributes & UInt8(CSMC_ATTR_WRITABLE) != 0 }
}

/// Thin, thread-safe Swift wrapper around the AppleSMC user client.
public final class SMC {
    public static let shared = SMC()

    private let lock = NSLock()
    private var isOpen = false

    private init() {}

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        if isOpen { return }
        let rc = csmc_open()
        switch rc {
        case CSMC_OK:              isOpen = true
        case CSMC_ERR_NO_SERVICE:  throw SMCError.notAvailable
        default:                   throw SMCError.openFailed
        }
    }

    /// Calls the user client's open selector. Harmless where it is not needed; returns the
    /// raw kern_return_t so diagnostics can report it.
    @discardableResult
    public func userClientOpen() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return Int32(csmc_user_client_open())
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        csmc_close()
        isOpen = false
    }

    // MARK: - Metadata

    public func meta(_ key: String) -> SMCKeyMeta? {
        lock.lock(); defer { lock.unlock() }
        var type: UInt32 = 0, size: UInt32 = 0, attr: UInt8 = 0
        guard csmc_key_info(key, &type, &size, &attr) == CSMC_OK else { return nil }
        var t = [CChar](repeating: 0, count: 5)
        csmc_type_to_string(type, &t)
        return SMCKeyMeta(key: key, type: String(cString: t), size: size, attributes: attr)
    }

    /// Every key the SMC enumerates. On an M3 Max this is ~2800 entries, so cache the result.
    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var count: UInt32 = 0
        guard csmc_key_count(&count) == CSMC_OK else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<count {
            if csmc_key_at_index(i, &buf) == CSMC_OK {
                keys.append(String(cString: buf))
            }
        }
        return keys
    }

    // MARK: - Reading

    public func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        lock.lock(); defer { lock.unlock() }
        var type: UInt32 = 0, size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard csmc_read(key, &type, &size, &bytes) == CSMC_OK else { return nil }
        var t = [CChar](repeating: 0, count: 5)
        csmc_type_to_string(type, &t)
        return (String(cString: t), Array(bytes[0..<Int(size)]))
    }

    public func readDouble(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        var type: UInt32 = 0, size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard csmc_read(key, &type, &size, &bytes) == CSMC_OK else { return nil }
        return csmc_decode(type, size, bytes)
    }

    /// The firmware status byte from the most recent SMC call, for diagnostics.
    public func lastStatus() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        return csmc_last_result()
    }

    public func readUInt8(_ key: String) -> UInt8? {
        guard let raw = readRaw(key), raw.bytes.count == 1 else { return nil }
        return raw.bytes[0]
    }

    // MARK: - Writing (root only)

    public func writeFloat(_ key: String, _ value: Float) throws {
        var v = value
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: &v) { src in
            for i in 0..<4 { bytes[i] = src[i] }      // SMC floats are little-endian
        }
        try writeBytes(key, bytes)
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeBytes(key, [value])
    }

    public func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let rc = bytes.withUnsafeBufferPointer { buf in
            csmc_write(key, UInt32(bytes.count), buf.baseAddress)
        }
        switch rc {
        case CSMC_OK:        return
        case CSMC_ERR_SIZE:  throw SMCError.sizeMismatch(key)
        default:
            let status = csmc_last_result()
            // A firmware status of 0 with a failed Mach call means the user client itself
            // refused us, which in practice means "not root".
            if status == 0, geteuid() != 0 { throw SMCError.notRoot }
            throw SMCError.callFailed(key, rc, status)
        }
    }
}
