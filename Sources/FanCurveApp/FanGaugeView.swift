import SwiftUI
import FanCurveKit

/// Compact live readout for one fan: current RPM as an arc plus the driving temperature.
struct FanGaugeView: View {
    let fan: FanStatus

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.1, to: 0.1 + 0.8 * animatedFraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    // Driven by the quantised value, and short enough to settle between the
                    // one-second updates. A tachometer reading wanders by a few rpm every poll;
                    // animating the raw value restarted a 0.6 s animation every second, so it
                    // never came to rest and held the process at 11–13 % CPU whenever a fan was
                    // turning. An animation whose input changes faster than it settles is the
                    // same problem as one that repeats forever.
                    .animation(.easeOut(duration: 0.25), value: animatedFraction)
                VStack(spacing: 0) {
                    Text("\(Int(fan.actualRPM))")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("rpm").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text(fan.name).font(.headline)
                HStack(spacing: 5) {
                    Image(systemName: fan.controlled ? "slider.horizontal.3" : "applelogo")
                        .font(.caption2)
                    Text(fan.controlled ? "アプリが制御中" : "システム制御")
                        .font(.caption)
                }
                .foregroundStyle(fan.controlled ? Color.accentColor : Color.secondary)

                if let t = fan.sourceTempC {
                    Text(String(format: "%@ %.1f °C", fan.sourceLabel, t))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("範囲 \(Int(fan.minRPM))–\(Int(fan.maxRPM)) rpm　"
                     + (fan.commandedRPM.map { "指示 \(Int($0)) rpm" } ?? "指示なし"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var fraction: Double {
        guard fan.maxRPM > 0 else { return 0 }
        return min(1, max(0, fan.actualRPM / fan.maxRPM))
    }

    /// The fraction rounded to half a percent, so a few rpm of tachometer wander does not read
    /// as a change. A real ramp still moves it; a fan holding steady leaves it alone.
    private var animatedFraction: Double {
        (fraction * 200).rounded() / 200
    }

    private var color: Color {
        switch fraction {
        case ..<0.4:  return .green
        case ..<0.75: return .orange
        default:      return .red
        }
    }
}
