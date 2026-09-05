import SwiftUI
import FanCurveKit

/// Browses every temperature probe the SMC exposes and lets one drive a fan curve.
struct SensorsView: View {
    @EnvironmentObject var store: DaemonStore
    @Binding var selectedFan: Int
    @State private var filter = ""
    @State private var group: SensorGroup? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("キーまたは名前で絞り込み", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)

                Picker("", selection: $group) {
                    Text("すべて").tag(SensorGroup?.none)
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        Text(g.displayName).tag(SensorGroup?.some(g))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Spacer()
                Text("\(filtered.count) / \(store.sensors.count) 個")
                    .font(.caption).foregroundStyle(.secondary)
                Button("更新") { Task { await store.refreshSensors() } }
            }

            Table(filtered) {
                TableColumn("キー") { s in
                    Text(s.key).font(.system(.body, design: .monospaced))
                }
                .width(70)
                TableColumn("分類") { s in Text(s.group.displayName) }.width(100)
                TableColumn("温度") { s in
                    Text(String(format: "%.1f °C", s.value))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(color(for: s.value))
                }
                .width(80)
                TableColumn("このセンサーで制御") { s in
                    Button("ファン\(selectedFan) に割当") { assign(s) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .frame(minHeight: 320)

            Text("ヒント: 個別センサーは 1 コアだけを見るため揺れます。通常は「ファンカーブ」タブでグループ最高温度を使う方が安定します。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { Task { await store.refreshSensors() } }
    }

    private var filtered: [SensorReading] {
        store.sensors
            .filter { group == nil || $0.group == group }
            .filter { filter.isEmpty
                || $0.key.localizedCaseInsensitiveContains(filter)
                || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.value > $1.value }
    }

    private func assign(_ s: SensorReading) {
        guard let i = store.config.fans.firstIndex(where: { $0.index == selectedFan }) else { return }
        store.config.fans[i].source = .key(s.key)
    }

    private func color(for v: Double) -> Color {
        switch v {
        case ..<55:  return .green
        case ..<75:  return .orange
        default:     return .red
        }
    }
}
