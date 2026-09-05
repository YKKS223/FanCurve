import Foundation

public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, soc, ssd, battery, ambient, power, other

    public var displayName: String {
        switch self {
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        case .soc:     return "SoC / 電源"
        case .ssd:     return "SSD"
        case .battery: return "バッテリー"
        case .ambient: return "筐体・外気"
        case .power:   return "電力"
        case .other:   return "その他"
        }
    }
}

public struct Sensor: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let group: SensorGroup
    public var id: String { key }

    public init(key: String, name: String, group: SensorGroup) {
        self.key = key; self.name = name; self.group = group
    }
}

public struct SensorReading: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let group: SensorGroup
    public let value: Double
    public var id: String { key }

    public init(key: String, name: String, group: SensorGroup, value: Double) {
        self.key = key; self.name = name; self.group = group; self.value = value
    }
}

/// Discovers and reads the SMC temperature sensors of an Apple-silicon Mac.
///
/// Apple silicon does not use the documented Intel key names (TC0P, TG0D, …). It exposes
/// hundreds of per-die probes instead, so sensors are classified by key prefix and the
/// curve is normally driven by a *group maximum* rather than a single probe.
public final class SensorCatalog {

    /// Keys that look like temperatures but never move. `Tf**` on M3 holds fixed
    /// calibration constants (measured: flat at 73.4 °C / 71.5 °C through a full CPU load).
    private static let deadPrefixes = ["Tf"]

    public private(set) var sensors: [Sensor] = []

    public init() {}

    public func discover() {
        var found: [Sensor] = []
        for key in SMC.shared.allKeys() {
            guard key.count == 4, key.hasPrefix("T") else { continue }
            guard let meta = SMC.shared.meta(key), meta.type == "flt ", meta.size == 4 else { continue }
            let prefix = String(key.prefix(2))
            if Self.deadPrefixes.contains(prefix) { continue }
            guard let v = SMC.shared.readDouble(key), v > 5, v < 130 else { continue }
            found.append(Sensor(key: key, name: Self.label(for: key), group: Self.group(for: key)))
        }
        sensors = found.sorted { ($0.group.rawValue, $0.key) < ($1.group.rawValue, $1.key) }
    }

    public static func group(for key: String) -> SensorGroup {
        let p2 = String(key.prefix(2))
        switch p2 {
        case "Tp", "Te":       return .cpu       // performance + efficiency core clusters
        case "Tg":             return .gpu
        case "TC", "TV", "TP", "TS", "TM", "Tm":
                               return .soc       // VRM / rails / memory
        case "TH", "Th":       return .ssd       // NAND / storage controller
        case "TB":             return .battery
        case "Ts", "Ta", "TA", "TW":
                               return .ambient   // skin, airflow, wireless
        default:               return .other
        }
    }

    public static func label(for key: String) -> String {
        switch key {
        case "TB0T", "TB1T", "TB2T": return "バッテリー \(key.dropFirst(2).prefix(1))"
        case "TW0P": return "無線モジュール"
        case "TaLP": return "吸気 左"
        case "TaRF": return "吸気 右"
        case "TaTP": return "吸気 上部"
        case "TAOL": return "外気"
        default:
            return "\(group(for: key).displayName) \(key)"
        }
    }

    // MARK: - Reading

    /// Readings outside what silicon can physically be are dropped rather than reported.
    /// A single glitched probe reading 200 °C would otherwise pin every fan at maximum.
    public static let plausibleRange: ClosedRange<Double> = -10...125

    public func readAll() -> [SensorReading] {
        sensors.compactMap { s in
            guard let v = SMC.shared.readDouble(s.key), v.isFinite,
                  Self.plausibleRange.contains(v) else { return nil }
            return SensorReading(key: s.key, name: s.name, group: s.group, value: v)
        }
    }

    public func maxOf(group: SensorGroup, in readings: [SensorReading]) -> Double? {
        readings.filter { $0.group == group }.map(\.value).max()
    }

    /// The hottest probe that a fan should react to: everything except battery and ambient,
    /// which lag far behind the die and would make the curve sluggish.
    public func systemMax(in readings: [SensorReading]) -> Double? {
        readings.filter { $0.group != .battery && $0.group != .ambient }.map(\.value).max()
    }
}

/// What a fan curve reads its temperature from.
public enum SensorSource: Codable, Hashable, Sendable {
    case systemMax
    case group(SensorGroup)
    case key(String)

    public var label: String {
        switch self {
        case .systemMax:      return "システム最高温度"
        case .group(let g):   return "\(g.displayName) 最高温度"
        case .key(let k):     return SensorCatalog.label(for: k)
        }
    }

    public func value(in readings: [SensorReading]) -> Double? {
        switch self {
        case .systemMax:
            return readings.filter { $0.group != .battery && $0.group != .ambient }.map(\.value).max()
        case .group(let g):
            return readings.filter { $0.group == g }.map(\.value).max()
        case .key(let k):
            return readings.first { $0.key == k }?.value
        }
    }

    // Codable as a tagged object so the JSON config stays readable/hand-editable.
    private enum CodingKeys: String, CodingKey { case kind, group, key }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "group": self = .group(try c.decode(SensorGroup.self, forKey: .group))
        case "key":   self = .key(try c.decode(String.self, forKey: .key))
        default:      self = .systemMax
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemMax:
            try c.encode("systemMax", forKey: .kind)
        case .group(let g):
            try c.encode("group", forKey: .kind); try c.encode(g, forKey: .group)
        case .key(let k):
            try c.encode("key", forKey: .kind); try c.encode(k, forKey: .key)
        }
    }
}
