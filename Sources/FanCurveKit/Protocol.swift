import Foundation

public enum IPC {
    /// Overridable with FANCURVE_SOCKET so the daemon can be exercised without installing it.
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["FANCURVE_SOCKET"] ?? "/var/run/fancurved.sock"
    }
    public static let version = "1.0"
}

public struct DaemonRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case status, getConfig, setConfig, setMode, setManual, listSensors, probe, reset, ping
    }
    public var cmd: Command
    public var config: AppConfig?
    public var mode: ControlMode?
    public var fanIndex: Int?
    public var rpm: Double?
    /// Identifies the caller. Only "gui" counts as the liveness heartbeat that keeps boost
    /// permitted; a CLI poll must not be able to stand in for the app being open.
    public var client: String?

    public init(cmd: Command, config: AppConfig? = nil, mode: ControlMode? = nil,
                fanIndex: Int? = nil, rpm: Double? = nil, client: String? = nil) {
        self.cmd = cmd; self.config = config; self.mode = mode
        self.fanIndex = fanIndex; self.rpm = rpm; self.client = client
    }

    public static let guiClient = "gui"
}

public struct SystemStatus: Codable, Sendable {
    public var timestamp: Double
    public var mode: ControlMode
    public var fans: [FanStatus]
    public var groupMax: [String: Double]
    public var systemMaxC: Double?
    public var emergency: Bool
    public var isRoot: Bool
    public var lastError: String?
    /// Non-nil while the daemon has deliberately handed the fans back to the firmware
    /// because something it depends on stopped being trustworthy.
    public var failsafeReason: String?
    /// True while the diagnostic flag is held — the window in which macOS cannot manage the
    /// fans and this daemon is solely responsible for cooling. Surfaced so it is never invisible.
    public var holdingControl: Bool
    /// The floor enforced on every commanded speed while control is held.
    public var boostFloorRPM: Double
    /// Why ordinary boost is not permitted right now, or nil when it is. Shown rather than
    /// left for the user to deduce from a stopped fan.
    public var boostBlockedReason: String?
    public var onACPower: Bool

    public init(timestamp: Double, mode: ControlMode, fans: [FanStatus],
                groupMax: [String: Double], systemMaxC: Double?, emergency: Bool,
                isRoot: Bool, lastError: String?, failsafeReason: String? = nil,
                holdingControl: Bool = false, boostFloorRPM: Double = 0,
                boostBlockedReason: String? = nil, onACPower: Bool = true) {
        self.timestamp = timestamp; self.mode = mode; self.fans = fans
        self.groupMax = groupMax; self.systemMaxC = systemMaxC
        self.emergency = emergency; self.isRoot = isRoot; self.lastError = lastError
        self.failsafeReason = failsafeReason
        self.holdingControl = holdingControl
        self.boostFloorRPM = boostFloorRPM
        self.boostBlockedReason = boostBlockedReason
        self.onACPower = onACPower
    }
}

public struct DaemonResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var version: String
    public var status: SystemStatus?
    public var config: AppConfig?
    public var sensors: [SensorReading]?
    public var hardware: [FanHardware]?
    public var probe: FanController.ProbeResult?

    public init(ok: Bool, error: String? = nil, status: SystemStatus? = nil,
                config: AppConfig? = nil, sensors: [SensorReading]? = nil,
                hardware: [FanHardware]? = nil, probe: FanController.ProbeResult? = nil) {
        self.ok = ok; self.error = error; self.version = IPC.version
        self.status = status; self.config = config; self.sensors = sensors
        self.hardware = hardware; self.probe = probe
    }

    public static func failure(_ message: String) -> DaemonResponse {
        DaemonResponse(ok: false, error: message)
    }
}
