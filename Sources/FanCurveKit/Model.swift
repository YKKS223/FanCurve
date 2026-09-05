import Foundation

public enum ControlMode: String, Codable, CaseIterable, Sendable {
    case system   // hands off — the Mac's own thermal controller runs the fans
    case curve    // temperature → RPM from the user's curve
    case manual   // fixed RPM per fan

    public var displayName: String {
        switch self {
        case .system: return "システム標準"
        case .curve:  return "カーブ"
        case .manual: return "手動"
        }
    }
}

public struct CurvePoint: Codable, Hashable, Sendable, Identifiable, Comparable {
    public var tempC: Double
    public var rpm: Double
    public var id: String { "\(tempC)-\(rpm)" }

    public init(tempC: Double, rpm: Double) { self.tempC = tempC; self.rpm = rpm }

    public static func < (a: CurvePoint, b: CurvePoint) -> Bool { a.tempC < b.tempC }
}

public struct FanCurve: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var name: String
    public var enabled: Bool
    public var source: SensorSource
    public var points: [CurvePoint]
    /// Temperature the reading must fall by before the target is lowered again.
    public var hysteresisC: Double
    /// Exponential smoothing time constant applied to the temperature reading.
    public var smoothingSeconds: Double
    /// Ramp limits, in RPM per second, so the fan does not step audibly.
    public var rampUpRPMPerSec: Double
    public var rampDownRPMPerSec: Double
    /// A curve point of 0 RPM means "let the Mac decide" rather than "stop the fan".
    public var zeroMeansSystem: Bool
    public var manualRPM: Double
    /// A hard ceiling the curve may never exceed, in rpm. 0 means "the fan's own maximum".
    ///
    /// Exists because the fan's rated maximum is not a speed anyone has to use: measured over
    /// 900 s, Apple's own controller never went past 5,006 rpm of a 6,898 rpm fan even at
    /// 117.6 °C. Running at the top of the range costs noise and wear for little extra airflow.
    /// The safety floor still wins over this cap — cooling is never traded for quiet.
    public var maxRPMCap: Double

    public var id: Int { index }

    public init(index: Int, name: String, maxRPM: Double) {
        self.index = index
        self.name = name
        self.enabled = true
        self.source = .systemMax
        self.points = FanCurve.balancedPoints(maxRPM: maxRPM)
        self.hysteresisC = 2.0
        self.smoothingSeconds = 4.0
        self.rampUpRPMPerSec = 600
        self.rampDownRPMPerSec = 250
        self.zeroMeansSystem = true
        self.manualRPM = 0
        self.maxRPMCap = (maxRPM * 0.80).rounded()
    }

    /// Tolerant decoding, so a config written by an older build keeps the user's curves instead
    /// of being thrown away and silently replaced with defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index             = try c.decode(Int.self, forKey: .index)
        name              = try c.decodeIfPresent(String.self, forKey: .name) ?? "ファン \(try c.decode(Int.self, forKey: .index) + 1)"
        enabled           = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source            = try c.decodeIfPresent(SensorSource.self, forKey: .source) ?? .systemMax
        points            = try c.decodeIfPresent([CurvePoint].self, forKey: .points) ?? []
        hysteresisC       = try c.decodeIfPresent(Double.self, forKey: .hysteresisC) ?? 2
        smoothingSeconds  = try c.decodeIfPresent(Double.self, forKey: .smoothingSeconds) ?? 4
        rampUpRPMPerSec   = try c.decodeIfPresent(Double.self, forKey: .rampUpRPMPerSec) ?? 600
        rampDownRPMPerSec = try c.decodeIfPresent(Double.self, forKey: .rampDownRPMPerSec) ?? 250
        zeroMeansSystem   = try c.decodeIfPresent(Bool.self, forKey: .zeroMeansSystem) ?? true
        manualRPM         = try c.decodeIfPresent(Double.self, forKey: .manualRPM) ?? 0
        maxRPMCap         = try c.decodeIfPresent(Double.self, forKey: .maxRPMCap) ?? 0
    }

    /// Piecewise-linear evaluation. Returns nil when the curve asks for system control.
    public func rpm(at tempC: Double) -> Double? {
        let pts = points.sorted()
        guard let first = pts.first, let last = pts.last else { return nil }
        var value: Double
        if tempC <= first.tempC {
            value = first.rpm
        } else if tempC >= last.tempC {
            value = last.rpm
        } else {
            value = last.rpm
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                if tempC >= a.tempC && tempC <= b.tempC {
                    let span = b.tempC - a.tempC
                    let f = span <= 0 ? 0 : (tempC - a.tempC) / span
                    value = a.rpm + (b.rpm - a.rpm) * f
                    break
                }
            }
        }
        if value <= 0 && zeroMeansSystem { return nil }
        return max(0, value)
    }

    // MARK: - Presets
    //
    // Shaped against the measured stock behaviour of this class of machine rather than round
    // numbers: Apple holds the fans at 0 rpm to 80 °C, pins 2,317 rpm from there to 106 °C,
    // and peaks near 5,000 rpm at 117 °C. Every preset below starts earlier than that and
    // stops short of the fan's rated maximum, which stock never uses.

    public static func balancedPoints(maxRPM: Double) -> [CurvePoint] {
        [ CurvePoint(tempC: 62, rpm: 0),
          CurvePoint(tempC: 70, rpm: (maxRPM * 0.38).rounded()),
          CurvePoint(tempC: 82, rpm: (maxRPM * 0.58).rounded()),
          CurvePoint(tempC: 95, rpm: (maxRPM * 0.75).rounded()),
          CurvePoint(tempC: 105, rpm: (maxRPM * 0.90).rounded()) ]
    }

    public static func quietPoints(maxRPM: Double) -> [CurvePoint] {
        [ CurvePoint(tempC: 72, rpm: 0),
          CurvePoint(tempC: 82, rpm: (maxRPM * 0.36).rounded()),
          CurvePoint(tempC: 95, rpm: (maxRPM * 0.55).rounded()),
          CurvePoint(tempC: 106, rpm: (maxRPM * 0.75).rounded()) ]
    }

    public static func coolingPoints(maxRPM: Double) -> [CurvePoint] {
        [ CurvePoint(tempC: 55, rpm: 0),
          CurvePoint(tempC: 62, rpm: (maxRPM * 0.38).rounded()),
          CurvePoint(tempC: 75, rpm: (maxRPM * 0.62).rounded()),
          CurvePoint(tempC: 88, rpm: (maxRPM * 0.85).rounded()),
          CurvePoint(tempC: 98, rpm: maxRPM) ]
    }

    public static func maxPoints(maxRPM: Double) -> [CurvePoint] {
        [ CurvePoint(tempC: 20, rpm: maxRPM), CurvePoint(tempC: 105, rpm: maxRPM) ]
    }
}

public enum CurvePreset: String, Codable, CaseIterable, Sendable {
    case quiet, balanced, cooling, maximum

    public var displayName: String {
        switch self {
        case .quiet:    return "静音"
        case .balanced: return "バランス"
        case .cooling:  return "冷却重視"
        case .maximum:  return "最大"
        }
    }

    public func points(maxRPM: Double) -> [CurvePoint] {
        switch self {
        case .quiet:    return FanCurve.quietPoints(maxRPM: maxRPM)
        case .balanced: return FanCurve.balancedPoints(maxRPM: maxRPM)
        case .cooling:  return FanCurve.coolingPoints(maxRPM: maxRPM)
        case .maximum:  return FanCurve.maxPoints(maxRPM: maxRPM)
        }
    }
}

public struct AppConfig: Codable, Hashable, Sendable {
    public var mode: ControlMode
    public var fans: [FanCurve]
    public var updateIntervalMs: Int
    /// Above this temperature every fan goes to maximum regardless of the curve.
    public var emergencyTempC: Double
    /// Only boost while on wall power. Running the fans costs a few watts, and on battery the
    /// machine is usually doing less anyway. Emergency cooling ignores this.
    public var boostRequiresCharging: Bool
    /// Only boost while the GUI is running and checking in.
    ///
    /// This is the deadman the hardware does not provide. Measured: a SIGKILLed process leaves
    /// `Ftst` set and macOS never takes the fans back. Requiring a live heartbeat means the
    /// permissive state decays on its own when the app quits, crashes, or the user logs out —
    /// holding control becomes the thing that needs current, rather than the resting state.
    public var boostRequiresApp: Bool
    /// How stale the GUI's last check-in may be. The app polls once a second.
    public var appHeartbeatTimeoutSec: Double

    /// Whether `F%dMd` must be forced before `F%dTg` takes effect.
    ///
    /// Defaults to **false** and is only believed once `modeKeyConfirmed` is set by an actual
    /// probe. Writing `F%dMd` speculatively is not safe: on an M3 Max the firmware value is 3,
    /// a write of 1 sticks, and 3 can never be written back (SMC status 0x82) — the fan is then
    /// left in a mode only a reboot clears. `F%dTg` alone drives the fan on this hardware.
    public var requiresModeKey: Bool
    /// Set only by `probe`, after it has seen `F%dTg` alone fail and the mode key help.
    public var modeKeyConfirmed: Bool
    /// `F%dMd` as the firmware leaves it, keyed by fan index. Recorded on the first ever run,
    /// before anything is forced, and never overwritten — it is what "give the fan back" means.
    public var firmwareFanMode: [String: Int]

    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["FANCURVE_CONFIG"]
            ?? "/Library/Application Support/FanCurve/config.json"
    }

    public init(mode: ControlMode = .system,
                fans: [FanCurve] = [],
                updateIntervalMs: Int = 1000,
                emergencyTempC: Double = 105,
                boostRequiresCharging: Bool = true,
                boostRequiresApp: Bool = true,
                appHeartbeatTimeoutSec: Double = 10,
                requiresModeKey: Bool = false,
                modeKeyConfirmed: Bool = false,
                firmwareFanMode: [String: Int] = [:]) {
        self.mode = mode
        self.fans = fans
        self.updateIntervalMs = updateIntervalMs
        self.emergencyTempC = emergencyTempC
        self.boostRequiresCharging = boostRequiresCharging
        self.boostRequiresApp = boostRequiresApp
        self.appHeartbeatTimeoutSec = appHeartbeatTimeoutSec
        self.requiresModeKey = requiresModeKey
        self.modeKeyConfirmed = modeKeyConfirmed
        self.firmwareFanMode = firmwareFanMode
    }

    public static func makeDefault(hardware: [FanHardware]) -> AppConfig {
        AppConfig(mode: .system,
                  fans: hardware.map { FanCurve(index: $0.index, name: $0.defaultName, maxRPM: $0.maxRPM) })
    }

    /// Fills in curves for fans the stored config does not mention and drops unknown ones.
    public mutating func reconcile(hardware: [FanHardware]) {
        var result: [FanCurve] = []
        for hw in hardware {
            if var existing = fans.first(where: { $0.index == hw.index }) {
                existing.points = existing.points.map {
                    CurvePoint(tempC: $0.tempC, rpm: min($0.rpm, hw.maxRPM))
                }
                result.append(existing)
            } else {
                result.append(FanCurve(index: hw.index, name: hw.defaultName, maxRPM: hw.maxRPM))
            }
        }
        fans = result
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode             = try c.decodeIfPresent(ControlMode.self, forKey: .mode) ?? .system
        fans             = try c.decodeIfPresent([FanCurve].self, forKey: .fans) ?? []
        updateIntervalMs = try c.decodeIfPresent(Int.self, forKey: .updateIntervalMs) ?? 1000
        emergencyTempC   = try c.decodeIfPresent(Double.self, forKey: .emergencyTempC) ?? 105
        boostRequiresCharging     = try c.decodeIfPresent(Bool.self, forKey: .boostRequiresCharging) ?? true
        boostRequiresApp          = try c.decodeIfPresent(Bool.self, forKey: .boostRequiresApp) ?? true
        appHeartbeatTimeoutSec    = try c.decodeIfPresent(Double.self, forKey: .appHeartbeatTimeoutSec) ?? 10
        // Older configs stored `true` from the days when the mode key was written blindly;
        // ignore that unless a probe actually confirmed it.
        modeKeyConfirmed = try c.decodeIfPresent(Bool.self, forKey: .modeKeyConfirmed) ?? false
        requiresModeKey  = modeKeyConfirmed
            ? (try c.decodeIfPresent(Bool.self, forKey: .requiresModeKey) ?? false)
            : false
        firmwareFanMode  = try c.decodeIfPresent([String: Int].self, forKey: .firmwareFanMode) ?? [:]
    }

    public static func load(from path: String) -> AppConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func save(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
