import SwiftUI
import FanCurveKit

struct ContentView: View {
    @EnvironmentObject var store: DaemonStore
    @State private var selectedTab = 0
    @State private var selectedFan = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isConnected {
                TabView(selection: $selectedTab) {
                    curveTab.tabItem { Label("ファンカーブ", systemImage: "chart.xyaxis.line") }.tag(0)
                    SensorsView(selectedFan: $selectedFan).tabItem { Label("センサー", systemImage: "thermometer.medium") }.tag(1)
                    SettingsTab().tabItem { Label("設定", systemImage: "gearshape") }.tag(2)
                }
                .padding(12)
            } else {
                disconnected
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .onAppear { store.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "fanblades.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(spin))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)

            VStack(alignment: .leading, spacing: 1) {
                Text("FanCurve").font(.headline)
                if let s = store.status {
                    Text(String(format: "システム最高 %.1f °C", s.systemMaxC ?? 0))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Spacer()

            if let s = store.status {
                // While the flag is held macOS cannot touch the fans. That must never be
                // something the user has to infer from a fan gauge.
                Label(s.holdingControl ? "このアプリが制御中" : "macOS が制御中",
                      systemImage: s.holdingControl ? "lock.fill" : "applelogo")
                    .font(.caption.bold())
                    .foregroundStyle(s.holdingControl ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((s.holdingControl ? Color.accentColor : Color.secondary).opacity(0.14)))
                    .help(s.holdingControl
                          ? "Ftst を保持しています。macOS の自動制御は介入できず、冷却はこのアプリの責任です。下限 \(Int(s.boostFloorRPM)) rpm。"
                          : "ファンは macOS が管理しています。")
            }
            if let blocked = store.status?.boostBlockedReason, store.config.mode != .system {
                Label(blocked, systemImage: store.status?.onACPower == false ? "battery.50" : "pause.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("この条件が満たされるまで、ファンは macOS が管理します。緊急冷却は条件に関係なく働きます。")
            }
            if let f = store.status?.failsafeReason {
                Label(f, systemImage: "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            if store.status?.emergency == true {
                Label("緊急冷却", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold()).foregroundStyle(.red)
            }
            if let e = store.status?.lastError {
                Label(e, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            }

            // Driven by the daemon's reported mode, never a local copy: during a CLI-driven
            // test this picker showed "カーブ" while the daemon was actually in 手動.
            Picker("", selection: Binding(
                get: { store.status?.mode ?? store.config.mode },
                set: { store.setMode($0) })) {
                ForEach(ControlMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .labelsHidden()

            Button {
                store.resetToSystem()
            } label: {
                Label("解除", systemImage: "arrow.uturn.backward")
            }
            .help("すべてのファンをすぐに Mac 標準の制御へ戻します")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var spin: Double {
        (store.status?.fans.first?.actualRPM ?? 0) > 0 ? 360 : 0
    }

    private var disconnected: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 46)).foregroundStyle(.secondary)
            Text("fancurved に接続できません").font(.title3)
            Text(store.connectionError ?? "デーモンが起動していません")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("ターミナルで次を実行してください:").font(.caption).foregroundStyle(.secondary)
            Text("sudo \(installScriptPath)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
            Button("再接続") { Task { await store.loadConfig() } }
            Spacer()
        }
        .padding(30)
    }

    private var installScriptPath: String {
        Bundle.main.bundleURL.deletingLastPathComponent().path + "/scripts/install.sh"
    }

    // MARK: - Curve tab

    private var curveTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = store.status, s.fans.count > 1 {
                Picker("", selection: $selectedFan) {
                    ForEach(s.fans) { f in Text(f.name).tag(f.index) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let fanStatus = store.status?.fans.first(where: { $0.index == selectedFan }) {
                FanGaugeView(fan: fanStatus)
            }

            if let binding = store.curveBinding(for: selectedFan),
               let hw = store.hardware(for: selectedFan) {
                curveControls(binding: binding, hw: hw)

                CurveEditorView(curve: binding,
                                maxRPM: hw.maxRPM,
                                liveTempC: store.status?.fans.first(where: { $0.index == selectedFan })?.sourceTempC,
                                liveRPM: store.status?.fans.first(where: { $0.index == selectedFan })?.actualRPM,
                                enabled: store.config.mode == .curve && binding.wrappedValue.enabled,
                                emergencyTempC: store.config.emergencyTempC,
                                emergencyActive: store.status?.emergency ?? false)

                if store.config.mode == .manual {
                    manualControls(binding: binding, hw: hw)
                }

                HistoryChartView(samples: store.history, fanIndex: selectedFan, maxRPM: hw.maxRPM)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("設定を読み込めていません").foregroundStyle(.secondary)
                    Text("デーモンとの初回同期に失敗した可能性があります。再取得しています…")
                        .font(.caption).foregroundStyle(.tertiary)
                    Button("いま再取得する") { Task { await store.loadConfig() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .task { await store.loadConfig() }
            }
            Spacer(minLength: 0)
        }
    }

    private func curveControls(binding: Binding<FanCurve>, hw: FanHardware) -> some View {
        HStack(spacing: 12) {
            Toggle("有効", isOn: binding.enabled).toggleStyle(.checkbox)

            Picker("温度ソース", selection: Binding(
                get: { sourceTag(binding.wrappedValue.source) },
                set: { binding.wrappedValue.source = source(fromTag: $0) })) {
                Text("システム最高").tag("systemMax")
                ForEach(SensorGroup.allCases, id: \.self) { g in
                    Text(g.displayName).tag("group:\(g.rawValue)")
                }
                if case .key(let k) = binding.wrappedValue.source {
                    Divider()
                    Text(SensorCatalog.label(for: k)).tag("key:\(k)")
                }
            }
            .frame(width: 230)

            Spacer()

            Menu("プリセット") {
                ForEach(CurvePreset.allCases, id: \.self) { p in
                    Button(p.displayName) { binding.wrappedValue.points = p.points(maxRPM: hw.maxRPM) }
                }
            }
            .frame(width: 110)
        }
    }

    private func manualControls(binding: Binding<FanCurve>, hw: FanHardware) -> some View {
        HStack(spacing: 10) {
            Text("手動回転数").font(.callout)
            Slider(value: binding.manualRPM, in: 0...hw.maxRPM, step: 50)
            Text(binding.wrappedValue.manualRPM <= 0 ? "システム制御"
                                                     : "\(Int(binding.wrappedValue.manualRPM)) rpm")
                .font(.system(.callout, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func sourceTag(_ s: SensorSource) -> String {
        switch s {
        case .systemMax:    return "systemMax"
        case .group(let g): return "group:\(g.rawValue)"
        case .key(let k):   return "key:\(k)"
        }
    }

    private func source(fromTag tag: String) -> SensorSource {
        if tag.hasPrefix("group:"), let g = SensorGroup(rawValue: String(tag.dropFirst(6))) { return .group(g) }
        if tag.hasPrefix("key:") { return .key(String(tag.dropFirst(4))) }
        return .systemMax
    }
}
