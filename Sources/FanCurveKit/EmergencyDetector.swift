import Foundation

/// Decides when to abandon the curve and run every fan flat out.
///
/// Rewritten after it fired 35 times in one session with on/off cycles as short as one second.
/// Three things were wrong, and each is fixed here:
///
///  * It read raw sensor values. Individual probes swing 15 °C in half a second (measured at
///    idle), so instantaneous readings cross any threshold constantly. It now works from a
///    smoothed temperature.
///  * Entry was debounced but **exit was not**, so it dropped out the moment a single sample
///    dipped. Exit now needs the temperature to fall a margin below the threshold and stay
///    there, and an activation lasts a minimum time regardless.
///  * A single glitched probe could trigger it, so a quorum of sensors is still required.
public struct EmergencyDetector: Sendable {

    public var thresholdC: Double
    /// How far below the threshold the temperature must fall before releasing. Without this,
    /// the fans pump up and down around the threshold instead of settling.
    public var releaseMarginC: Double = 5
    public var enterTicks: Int = 3
    public var exitTicks: Int = 3
    /// Once engaged, stay engaged at least this long. Emergency cooling that lasts two seconds
    /// achieves nothing except noise.
    public var minimumHoldSeconds: Double = 15
    /// Guards against one bad probe pinning every fan at maximum.
    public var sensorQuorum: Int = 2

    public private(set) var isEngaged = false
    private var hotTicks = 0
    private var coolTicks = 0
    private var engagedAt: Date?

    public init(thresholdC: Double) {
        self.thresholdC = thresholdC
    }

    /// - Parameters:
    ///   - smoothedMaxC: temperature after smoothing, not a raw sample.
    ///   - sensorsAtOrAboveThreshold: how many probes currently read at or above the threshold.
    @discardableResult
    public mutating func update(smoothedMaxC: Double,
                                sensorsAtOrAboveThreshold: Int,
                                now: Date = Date()) -> Bool {
        let hot = smoothedMaxC >= thresholdC && sensorsAtOrAboveThreshold >= sensorQuorum
        let cool = smoothedMaxC <= thresholdC - releaseMarginC

        hotTicks = hot ? hotTicks + 1 : 0
        coolTicks = cool ? coolTicks + 1 : 0

        if !isEngaged {
            if hotTicks >= enterTicks {
                isEngaged = true
                engagedAt = now
                coolTicks = 0
            }
        } else {
            let heldLongEnough = engagedAt.map { now.timeIntervalSince($0) >= minimumHoldSeconds } ?? true
            if coolTicks >= exitTicks && heldLongEnough {
                isEngaged = false
                engagedAt = nil
                hotTicks = 0
            }
        }
        return isEngaged
    }

    /// Drops the emergency without waiting, for when the app stops controlling the fans at all.
    public mutating func reset() {
        isEngaged = false
        hotTicks = 0
        coolTicks = 0
        engagedAt = nil
    }
}
