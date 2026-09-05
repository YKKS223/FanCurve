import Foundation
import IOKit.ps

/// Conditions that must hold before ordinary boost is allowed.
///
/// These are preconditions, not switches: failing one produces no permit, and no permit means
/// the fans go back to macOS. Nothing here has a "turn it off again" branch that could be missed.
///
/// Emergency cooling deliberately ignores all of them. A safety override that stops working
/// because a laptop was unplugged, or because a window was closed, would not be a safety override.
public enum BoostPreconditions {

    /// Human-readable reason ordinary boost is not allowed, or nil when it is.
    public static func blockReason(requiresCharging: Bool,
                                   onACPower: Bool,
                                   requiresApp: Bool,
                                   secondsSinceAppHeartbeat: Double,
                                   heartbeatTimeout: Double) -> String? {
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
