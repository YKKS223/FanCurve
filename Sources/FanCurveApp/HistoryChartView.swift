import SwiftUI
import FanCurveKit

/// Rolling 5-minute trace of the driving temperature and the resulting fan speed.
struct HistoryChartView: View {
    let samples: [HistorySample]
    let fanIndex: Int
    let maxRPM: Double

    private let tempMin = 20.0
    private let tempMax = 125.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Label("温度", systemImage: "thermometer.medium").foregroundStyle(.orange)
                Label("回転数", systemImage: "fan").foregroundStyle(Color.accentColor)
                Spacer()
                Text("直近 \(max(1, samples.count)) 秒").foregroundStyle(.secondary)
            }
            .font(.caption)

            GeometryReader { geo in
                Canvas { ctx, size in
                    let r = CGRect(x: 0, y: 4, width: size.width, height: size.height - 8)
                    ctx.stroke(Path(r), with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                    guard samples.count > 1 else { return }

                    let n = samples.count
                    func px(_ i: Int) -> CGFloat { r.minX + r.width * CGFloat(i) / CGFloat(max(1, n - 1)) }

                    var tempPath = Path()
                    var rpmPath = Path()
                    for (i, s) in samples.enumerated() {
                        let t = s.fanTempC[fanIndex] ?? s.systemMaxC
                        let ty = r.maxY - r.height * CGFloat(min(1, max(0, (t - tempMin) / (tempMax - tempMin))))
                        let v = s.fanRPM[fanIndex] ?? 0
                        let vy = r.maxY - r.height * CGFloat(maxRPM <= 0 ? 0 : min(1, v / maxRPM))
                        if i == 0 { tempPath.move(to: CGPoint(x: px(i), y: ty)); rpmPath.move(to: CGPoint(x: px(i), y: vy)) }
                        else { tempPath.addLine(to: CGPoint(x: px(i), y: ty)); rpmPath.addLine(to: CGPoint(x: px(i), y: vy)) }
                    }
                    ctx.stroke(rpmPath, with: .color(.accentColor), lineWidth: 1.5)
                    ctx.stroke(tempPath, with: .color(.orange), lineWidth: 1.5)
                }
            }
            .frame(height: 90)
        }
    }
}
