import Foundation

/// Permission to drive one fan for a single control cycle.
///
/// Permits are issued, never latched. A cycle that cannot satisfy every precondition simply
/// issues none, and issuing none *is* the instruction to hand the fans back — there is no
/// "release" branch that could be skipped. Holding control is the active case; letting go is
/// what happens by default.
public struct BoostPermit: Hashable, Sendable {
    public let fanIndex: Int
    public let rpm: Double
    public init(fanIndex: Int, rpm: Double) {
        self.fanIndex = fanIndex
        self.rpm = rpm
    }
}

/// The targets to actually write, derived from a cycle's permits.
///
/// Pure value logic, so the safety rules can be tested without an SMC. Two invariants matter,
/// both learned by measurement:
///
///  * **Never below the floor.** `Ftst` has no hardware deadman — a SIGKILLed process leaves the
///    flag set and macOS does not take the fans back (measured: still set after 90 s). The floor
///    guarantees that a stuck state is a fan running *too fast*, which is merely loud. Apple's
///    own controller holds 2,317 rpm from 80 °C to 106 °C, so a floor at or above that is never
///    worse than stock in that range.
///  * **All fans or none.** `Ftst` is machine-wide: while it is held, macOS cannot drive *any*
///    fan. Covering only some of them would leave the rest unmanaged with the OS locked out.
public enum BoostPlan {

    /// Targets per fan index, or nil meaning "hold nothing, let macOS have the fans".
    public static func make(permits: [BoostPermit],
                            hardware: [FanHardware],
                            floorRPM: Double) -> [Int: Double]? {
        guard !permits.isEmpty, !hardware.isEmpty else { return nil }

        var plan: [Int: Double] = [:]
        for hw in hardware {
            let requested = permits.first { $0.fanIndex == hw.index }?.rpm ?? 0
            // The floor is raised to the fan's own minimum where the firmware asks for more,
            // and everything is clamped to the fan's maximum.
            let floor = max(floorRPM, hw.minRPM)
            plan[hw.index] = min(hw.maxRPM, max(requested, floor))
        }
        return plan
    }

    /// The default floor: above the 2,317 rpm Apple pins from 80 °C to 106 °C, so a stuck
    /// boost is never quieter than stock through that whole band.
    public static let defaultFloorRPM: Double = 2500

    /// What the curve is asking for this cycle, limited only at the top.
    ///
    /// Deliberately *not* raised to the fan's own minimum. That raise belongs after the decision
    /// to take control, and doing it first hid the decision entirely: a fan whose minimum is
    /// 2,502 rpm made every request come out at or above the 2,500 rpm floor, so the gate below
    /// always said yes and the fans held 2,500 rpm at 53 °C.
    public static func requestedSpeed(rampedRPM: Double, maxRPM: Double) -> Double {
        min(max(rampedRPM, 0), maxRPM)
    }

    /// Applies the user's ceiling, but never below what safety demands.
    ///
    /// A cap is a preference about noise and wear; the safety floor is not negotiable. When the
    /// two conflict the floor wins, so a low cap can make the machine quieter but never hotter
    /// than it would otherwise be allowed to get.
    public static func applyCap(_ rpm: Double,
                                cap: Double,
                                safetyFloorRPM: Double,
                                maxRPM: Double) -> Double {
        let ceiling = cap <= 0 ? maxRPM : min(cap, maxRPM)
        return min(maxRPM, max(min(rpm, ceiling), safetyFloorRPM))
    }

    /// Whether a requested speed is worth taking control for at all.
    ///
    /// Holding `Ftst` has a fixed minimum cost: the floor. A request below it cannot be
    /// honoured — it would be raised to the floor — so taking control would leave the machine
    /// *louder* than letting macOS idle the fans, and pull in more dust, for no benefit. Below
    /// the floor the honest answer is to hold nothing.
    ///
    /// The threshold is lower once already holding, so a curve sitting near the floor does not
    /// make the fans flap between stopped and 2,500 rpm.
    public static func worthHolding(requestedRPM: Double,
                                    floorRPM: Double = defaultFloorRPM,
                                    alreadyHolding: Bool) -> Bool {
        requestedRPM >= (alreadyHolding ? floorRPM * 0.85 : floorRPM)
    }
}
