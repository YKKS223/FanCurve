import Foundation

/// A floor the user's curve cannot dig under.
///
/// Its only job is that holding `Ftst` never leaves the machine worse cooled than macOS would
/// have left it. Locking the OS out is the harm this program can do; being quieter than the user
/// asked for is not, and being *louder* than they asked for is not safety either.
///
/// So the numbers are read straight off the stock controller, measured over 900 s on this
/// machine rather than picked:
///
/// | temperature | stock behaviour            |
/// |-------------|----------------------------|
/// | below 80 °C | fans stopped               |
/// | 80–106 °C   | pinned at 2,317 rpm (min)  |
/// | 106–117 °C  | ramps to 5,006 rpm (73 %)  |
///
/// Below ~100 °C nothing is needed here at all: `BoostPlan`'s flat 2,500 rpm floor, which applies
/// whenever control is held, already exceeds the 2,317 rpm the firmware pins across that whole
/// band. This floor only has to cover the ramp stock performs above 106 °C.
///
/// An earlier version demanded 92 % of maximum at 95 °C — roughly three times what the firmware
/// does there — and silently overrode the user's own ceiling. That was a cooling preference
/// wearing a safety label.
public enum SafetyFloor {

    /// (temperature, fraction of the fan's maximum RPM).
    public static let points: [(tempC: Double, fraction: Double)] = [
        (100, 0.00),   // stock is still at its minimum; the flat boost floor already beats it
        (106, 0.34),   // where stock begins to ramp
        (112, 0.55),
        (117, 0.75),   // stock's measured peak was 73 %
        (120, 1.00),
    ]

    /// The lowest RPM the app may command at this temperature.
    public static func minimumRPM(tempC: Double, maxRPM: Double) -> Double {
        guard maxRPM > 0, tempC.isFinite else { return 0 }
        return maxRPM * fraction(tempC: tempC)
    }

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
}
