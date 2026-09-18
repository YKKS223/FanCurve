import Foundation
import IOKit.ps

/// Conditions that must hold before ordinary boost is allowed.
///
/// These are preconditions, not switches: failing one produces no permit, and no permit means
/// the fans go back to macOS. Nothing here has a "turn it off again" branch that could be missed.
///
/// Emergency cooling is gated by them too: it only exists while this app is the one driving.
public enum BoostPreconditions {

    /// macOS major versions on which handing the fans back has been measured to work.
    ///
    /// Everything that makes letting go the safe default — `Ftst = 0` returns every fan to
    /// mode 3 within about 3 s — was measured on macOS 26. On macOS 27.0 the same write left
    /// both fans in mode 1 at 0 rpm for over five minutes, released at 91 °C, until the Mac
    /// was put to sleep. On an OS where letting go is not known to hand control back, taking
    /// control at all is unsafe, so an unlisted version never gets a permit. Add a version
    /// here only after measuring the release on it.
    public static let verifiedOSMajorVersions: Set<Int> = [26]

    public static var currentOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// Human-readable reason ordinary boost is not allowed, or nil when it is.
    public static func blockReason(osMajorVersion: Int = currentOSMajorVersion,
                                   requiresCharging: Bool,
                                   onACPower: Bool,
                                   requiresApp: Bool,
                                   secondsSinceAppHeartbeat: Double,
                                   heartbeatTimeout: Double) -> String? {
        // First, and not configurable: the other conditions decide whether boosting is
        // wanted, this one whether it can be undone.
        if !verifiedOSMajorVersions.contains(osMajorVersion) {
            return "macOS \(osMajorVersion) ではファンの返却が未検証のため、制御しません"
        }
        if requiresCharging, !onACPower {
            return "バッテリー駆動中"
        }
        if requiresApp, secondsSinceAppHeartbeat > heartbeatTimeout {
            return "FanCurve アプリが起動していません"
        }
        return nil
    }
}

/// Reads whether the Mac is running on wall power.
public enum PowerSource {

    /// True when drawing from AC.
    ///
    /// An unreadable power source counts as *not* on AC. That is the conservative answer: it
    /// costs a boost, whereas guessing the other way would keep `Ftst` held on evidence we do
    /// not have. Desktops report AC, so they are unaffected.
    public static func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        else { return false }
        return type == kIOPSACPowerValue
    }

    /// Battery percentage, or nil on a machine without one.
    public static func batteryPercentage() -> Double? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let current = info[kIOPSCurrentCapacityKey] as? Double,
               let max = info[kIOPSMaxCapacityKey] as? Double, max > 0 {
                return current / max * 100
            }
        }
        return nil
    }
}
