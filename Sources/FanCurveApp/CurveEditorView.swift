import SwiftUI
import FanCurveKit

/// Interactive temperature → RPM curve. Drag points, double-click to add,
/// ⌥-click to delete, or nudge the selected point with the steppers below.
struct CurveEditorView: View {
    @Binding var curve: FanCurve
    let maxRPM: Double
    let liveTempC: Double?
    let liveRPM: Double?
    let enabled: Bool

    @State private var dragIndex: Int?
    @State private var selection: Int?

    // Stock runs this machine to 117.6 °C and the safety floor is defined to 120 °C, so an axis
    // that stopped at 105 °C hid exactly the range those two are about.
    private let tempMin: Double = 20
    private let tempMax: Double = 125
    private let hitRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let plot = plotRect(in: geo.size)
                Canvas { ctx, _ in
                    drawGrid(ctx, plot)
                    drawSafetyFloor(ctx, plot)
                    drawStockBaseline(ctx, plot)
                    drawCurve(ctx, plot)
                    drawLive(ctx, plot)
                    drawPoints(ctx, plot)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(plot: plot))
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { v in addPoint(at: v.location, plot: plot) }
                )
                .simultaneousGesture(
                    SpatialTapGesture().modifiers(.option).onEnded { v in deletePoint(at: v.location, plot: plot) }
                )
                .accessibilityLabel("ファンカーブ編集")
            }
            .frame(minHeight: 220)
            .opacity(enabled ? 1 : 0.45)

            pointControls
        }
    }

    // MARK: - Point editing controls

    private var pointControls: some View {
        HStack(spacing: 10) {
            if let i = selection, i < sortedPoints.count {
                let p = sortedPoints[i]
                HStack(spacing: 4) {
                    Text("点 \(i + 1)").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: Binding(
                        get: { p.tempC },
                        set: { updatePoint(i, tempC: $0, rpm: nil) }), in: tempMin...tempMax, step: 1) {
                            Text("\(Int(p.tempC)) °C").font(.system(.caption, design: .monospaced)).frame(width: 52, alignment: .leading)
                        }
                    Stepper(value: Binding(
                        get: { p.rpm },
                        set: { updatePoint(i, tempC: nil, rpm: $0) }), in: 0...maxRPM, step: 100) {
                            Text("\(Int(p.rpm)) rpm").font(.system(.caption, design: .monospaced)).frame(width: 78, alignment: .leading)
                        }
                }
            } else {
                Text("点をクリックで選択　/　ダブルクリックで追加　/　⌥クリックで削除")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("点を追加") { addPointInLargestGap() }
                .buttonStyle(.bordered).controlSize(.small)
            Button("削除") { if let i = selection { removePoint(i) } }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(selection == nil || curve.points.count <= 2)
        }
    }

    // MARK: - Geometry

    private var sortedPoints: [CurvePoint] { curve.points.sorted() }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 40, y: 8, width: max(10, size.width - 52), height: max(10, size.height - 28))
    }

    private func x(_ t: Double, _ r: CGRect) -> CGFloat {
        r.minX + r.width * CGFloat((t - tempMin) / (tempMax - tempMin))
    }
    private func y(_ rpm: Double, _ r: CGRect) -> CGFloat {
        r.maxY - r.height * CGFloat(maxRPM <= 0 ? 0 : min(1, rpm / maxRPM))
    }
    private func temp(fromX px: CGFloat, _ r: CGRect) -> Double {
        tempMin + (tempMax - tempMin) * Double((px - r.minX) / max(1, r.width))
    }
    private func rpm(fromY py: CGFloat, _ r: CGRect) -> Double {
        maxRPM * Double((r.maxY - py) / max(1, r.height))
    }

    // MARK: - Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ r: CGRect) {
        var grid = Path()
        for t in stride(from: tempMin, through: tempMax, by: 10) {
            grid.move(to: CGPoint(x: x(t, r), y: r.minY))
            grid.addLine(to: CGPoint(x: x(t, r), y: r.maxY))
        }
        let rpmStep = max(500.0, (maxRPM / 6).rounded(.down) / 500 * 500)
        for v in stride(from: 0.0, through: maxRPM, by: rpmStep) {
            grid.move(to: CGPoint(x: r.minX, y: y(v, r)))
            grid.addLine(to: CGPoint(x: r.maxX, y: y(v, r)))
        }
        ctx.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 1)

        ctx.stroke(Path(r), with: .color(.secondary.opacity(0.3)), lineWidth: 1)

        for t in stride(from: tempMin, through: tempMax, by: 20) {
            ctx.draw(Text("\(Int(t))°").font(.system(size: 9)).foregroundColor(.secondary),
                     at: CGPoint(x: x(t, r), y: r.maxY + 10))
        }
        for v in stride(from: 0.0, through: maxRPM, by: rpmStep * 2) {
            ctx.draw(Text("\(Int(v))").font(.system(size: 9)).foregroundColor(.secondary),
                     at: CGPoint(x: r.minX - 18, y: y(v, r)), anchor: .center)
        }

        // The band where a 0-RPM point hands the fan back to the Mac's own controller.
        if curve.zeroMeansSystem {
            let band = CGRect(x: r.minX, y: y(maxRPM * 0.02, r), width: r.width, height: r.maxY - y(maxRPM * 0.02, r))
            ctx.fill(Path(band), with: .color(.green.opacity(0.10)))
            ctx.draw(Text("システム制御").font(.system(size: 9)).foregroundColor(.green.opacity(0.9)),
                     at: CGPoint(x: r.minX + 44, y: r.maxY - 7))
        }
    }

    /// The hard minimum the daemon enforces on top of the curve. Drawn so the rule is visible
    /// rather than a surprise: anything the user draws below this line is raised to it.
    private func drawSafetyFloor(_ ctx: GraphicsContext, _ r: CGRect) {
        var line = Path()
        var started = false
        for t in stride(from: tempMin, through: tempMax, by: 1) {
            let rpm = SafetyFloor.minimumRPM(tempC: t, maxRPM: maxRPM)
            let p = CGPoint(x: x(t, r), y: y(rpm, r))
            if started { line.addLine(to: p) } else { line.move(to: p); started = true }
        }
        ctx.stroke(line, with: .color(.red.opacity(0.65)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

        var shade = line
        shade.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        shade.addLine(to: CGPoint(x: x(SafetyFloor.points.first!.tempC, r), y: r.maxY))
        shade.closeSubpath()
        ctx.fill(shade, with: .color(.red.opacity(0.10)))

        ctx.draw(Text("安全下限").font(.system(size: 9)).foregroundColor(.red.opacity(0.9)),
                 at: CGPoint(x: x(112, r), y: y(SafetyFloor.minimumRPM(tempC: 112, maxRPM: maxRPM), r) + 11))

        // The flat floor that applies whenever control is held at all, so a crash leaves the
        // fan running rather than stopped.
        let flat = max(BoostPlan.defaultFloorRPM, 0)
        var flatLine = Path()
        flatLine.move(to: CGPoint(x: r.minX, y: y(flat, r)))
        flatLine.addLine(to: CGPoint(x: r.maxX, y: y(flat, r)))
        ctx.stroke(flatLine, with: .color(.red.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        ctx.draw(Text("ブースト中の最低 \(Int(flat)) rpm").font(.system(size: 9)).foregroundColor(.red.opacity(0.8)),
                 at: CGPoint(x: r.minX + 78, y: y(flat, r) - 8))

        // The user's own ceiling, which the curve is clipped to outside an emergency.
        let cap = curve.maxRPMCap
        if cap > 0, cap < maxRPM {
            var capLine = Path()
            capLine.move(to: CGPoint(x: r.minX, y: y(cap, r)))
            capLine.addLine(to: CGPoint(x: r.maxX, y: y(cap, r)))
            ctx.stroke(capLine, with: .color(.purple.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [6, 3]))
            ctx.draw(Text("上限 \(Int(cap)) rpm").font(.system(size: 9)).foregroundColor(.purple.opacity(0.9)),
                     at: CGPoint(x: r.maxX - 46, y: y(cap, r) - 8))
        }
    }

    /// What the Mac would be doing on its own. Drawn so the point of the app — and the size of
    /// the difference — is visible rather than asserted.
    private func drawStockBaseline(_ ctx: GraphicsContext, _ r: CGRect) {
        var line = Path()
        var started = false
        for t in stride(from: tempMin, through: tempMax, by: 0.5) {
            let p = CGPoint(x: x(t, r), y: y(StockBaseline.rpm(tempC: t, maxRPM: maxRPM), r))
            if started { line.addLine(to: p) } else { line.move(to: p); started = true }
        }
        ctx.stroke(line, with: .color(.secondary.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
        ctx.draw(Text("Apple 標準（実測）").font(.system(size: 9)).foregroundColor(.secondary),
                 at: CGPoint(x: x(93, r), y: y(maxRPM * 0.336, r) - 9))
    }

    private func drawCurve(_ ctx: GraphicsContext, _ r: CGRect) {
        let pts = sortedPoints
        guard let first = pts.first, let last = pts.last else { return }

        var line = Path()
        line.move(to: CGPoint(x: r.minX, y: y(first.rpm, r)))
        for p in pts { line.addLine(to: CGPoint(x: x(p.tempC, r), y: y(p.rpm, r))) }
        line.addLine(to: CGPoint(x: r.maxX, y: y(last.rpm, r)))

        var fill = line
        fill.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        fill.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [.accentColor.opacity(0.28), .accentColor.opacity(0.02)]),
            startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        ctx.stroke(line, with: .color(.accentColor), lineWidth: 2)
    }

    private func drawPoints(_ ctx: GraphicsContext, _ r: CGRect) {
        for (i, p) in sortedPoints.enumerated() {
            let c = CGPoint(x: x(p.tempC, r), y: y(p.rpm, r))
            let isSel = selection == i
            let radius: CGFloat = isSel ? 7 : 5
            let rect = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(isSel ? .accentColor : Color(nsColor: .windowBackgroundColor)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.accentColor), lineWidth: 2)
        }
    }

    private func drawLive(_ ctx: GraphicsContext, _ r: CGRect) {
        guard let t = liveTempC, t.isFinite else { return }
        let px = x(min(max(t, tempMin), tempMax), r)
        var v = Path()
        v.move(to: CGPoint(x: px, y: r.minY)); v.addLine(to: CGPoint(x: px, y: r.maxY))
        ctx.stroke(v, with: .color(.orange.opacity(0.8)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        ctx.draw(Text(String(format: "%.0f°C", t)).font(.system(size: 10, weight: .semibold)).foregroundColor(.orange),
                 at: CGPoint(x: min(px + 22, r.maxX - 14), y: r.minY + 8))

        if let rp = liveRPM, rp > 0 {
            let c = CGPoint(x: px, y: y(rp, r))
            let d = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: d), with: .color(.orange))
        }
    }

    // MARK: - Interaction

    private func dragGesture(plot r: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragIndex == nil {
                    guard let i = nearestPoint(to: value.startLocation, plot: r) else { return }
                    dragIndex = i
                    selection = i
                }
                guard let i = dragIndex else { return }
                updatePoint(i,
                            tempC: temp(fromX: value.location.x, r),
                            rpm: rpm(fromY: value.location.y, r))
            }
            .onEnded { _ in dragIndex = nil }
    }

    private func nearestPoint(to loc: CGPoint, plot r: CGRect) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in sortedPoints.enumerated() {
            let c = CGPoint(x: x(p.tempC, r), y: y(p.rpm, r))
            let d = hypot(c.x - loc.x, c.y - loc.y)
            if d <= hitRadius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// Moves a point, keeping the curve monotonic in temperature so the array stays sorted.
    private func updatePoint(_ index: Int, tempC: Double?, rpm newRPM: Double?) {
        var pts = sortedPoints
        guard index >= 0, index < pts.count else { return }
        let lower = index > 0 ? pts[index - 1].tempC + 1 : tempMin
        let upper = index < pts.count - 1 ? pts[index + 1].tempC - 1 : tempMax
        if let t = tempC { pts[index].tempC = min(max(t, lower), min(upper, tempMax)).rounded() }
        if let v = newRPM { pts[index].rpm = min(max(v, 0), maxRPM).rounded() }
        curve.points = pts
    }

    private func addPoint(at loc: CGPoint, plot r: CGRect) {
        let t = min(max(temp(fromX: loc.x, r), tempMin), tempMax).rounded()
        let v = min(max(rpm(fromY: loc.y, r), 0), maxRPM).rounded()
        guard !curve.points.contains(where: { abs($0.tempC - t) < 1 }) else { return }
        var pts = sortedPoints
        pts.append(CurvePoint(tempC: t, rpm: v))
        pts.sort()
        curve.points = pts
        selection = pts.firstIndex { abs($0.tempC - t) < 0.5 }
    }

    private func addPointInLargestGap() {
        var pts = sortedPoints
        guard pts.count >= 2 else { return }
        var bestGap = 0.0, bestIndex = 0
        for i in 0..<(pts.count - 1) {
            let gap = pts[i + 1].tempC - pts[i].tempC
            if gap > bestGap { bestGap = gap; bestIndex = i }
        }
        guard bestGap >= 2 else { return }
        let a = pts[bestIndex], b = pts[bestIndex + 1]
        pts.insert(CurvePoint(tempC: ((a.tempC + b.tempC) / 2).rounded(),
                              rpm: ((a.rpm + b.rpm) / 2).rounded()), at: bestIndex + 1)
        curve.points = pts
        selection = bestIndex + 1
    }

    private func deletePoint(at loc: CGPoint, plot r: CGRect) {
        guard let i = nearestPoint(to: loc, plot: r) else { return }
        removePoint(i)
    }

    private func removePoint(_ index: Int) {
        var pts = sortedPoints
        guard pts.count > 2, index >= 0, index < pts.count else { return }
        pts.remove(at: index)
        curve.points = pts
        selection = nil
    }
}
