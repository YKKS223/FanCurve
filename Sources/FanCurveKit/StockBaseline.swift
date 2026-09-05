import Foundation

/// What the Mac's own controller does, measured rather than assumed.
///
/// Taken from a 900-second run on a MacBook Pro (Mac15,10, M3 Max) with nothing driving the
/// fans: temperatures were pushed from 56 °C to 117.6 °C by a local LLM workload while only
/// reading the SMC. It is the reference every design decision in this app is judged against —
/// the curve should beat it, the safety floor should never fall under it, and it is drawn on
/// the editor so the difference is visible rather than claimed.
public enum StockBaseline {

    /// (temperature, fraction of the fan's maximum RPM).
    ///
    /// Both fans pin at their own minimum across the middle band, which works out to the same
    /// fraction on each: 2,317/6,898 and 2,502/7,450 are both ≈ 0.336.
    public static let points: [(tempC: Double, fraction: Double)] = [
        (79.9, 0.00),   // fans stopped right up to here
        (80.0, 0.336),  // starts, but only at the minimum
        (106.0, 0.336), // still at the minimum 26 °C later
        (117.6, 0.73),  // measured peak — the rated maximum is never used
        (125.0, 0.73),
    ]

    public static func fraction(tempC: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if tempC <= first.tempC { return first.fraction }
        if tempC >= last.tempC { return last.fraction }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if tempC >= a.tempC && tempC <= b.tempC {
                let span = b.tempC - a.tempC
                let t = span <= 0 ? 0 : (tempC - a.tempC) / span
                return a.fraction + (b.fraction - a.fraction) * t
            }
        }
        return last.fraction
    }

    public static func rpm(tempC: Double, maxRPM: Double) -> Double {
        guard maxRPM > 0, tempC.isFinite else { return 0 }
        return maxRPM * fraction(tempC: tempC)
    }
}
