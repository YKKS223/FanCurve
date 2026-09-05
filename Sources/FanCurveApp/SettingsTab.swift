import SwiftUI
import FanCurveKit

struct SettingsTab: View {
    @EnvironmentObject var store: DaemonStore
    @State private var probeFan = 0
    @State private var probeRPM = 3500.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                section("ブーストの条件", icon: "checklist") {
                    Toggle("充電中のみブーストする", isOn: $store.config.boostRequiresCharging)
                    Text("バッテリー駆動中はファンを回さず macOS に任せます。ファンの消費は数 W あり、"
                         + "アイドル時のシステム全体（約 8 W）に対しては無視できない割合です。")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("このアプリの起動中のみブーストする", isOn: $store.config.boostRequiresApp)
                    Text("デーモンはこのアプリからの生存確認が \(Int(store.config.appHeartbeatTimeoutSec)) 秒途切れると"
                         + "自動でファンを macOS へ返します。アプリを終了・クラッシュ・ログアウトしても、"
                         + "誰かが後片付けをする必要がありません。\n"
                         + "⌘Q で終了するとブーストは止まります（ウィンドウを閉じるだけでは常駐したままです）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("どちらの条件も緊急冷却には適用されません。")
                        .font(.caption).foregroundStyle(.orange)
                }

                section("制御", icon: "slider.horizontal.3") {
                    LabeledContent("更新間隔") {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(store.config.updateIntervalMs) },
                                set: { store.config.updateIntervalMs = Int($0) }), in: 250...5000, step: 250)
                            .frame(width: 220)
                            Text("\(store.config.updateIntervalMs) ms")
                                .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                        }
                    }
                    LabeledContent("緊急冷却しきい値") {
                        HStack {
                            Slider(value: $store.config.emergencyTempC, in: 85...115, step: 1).frame(width: 220)
                            Text("\(Int(store.config.emergencyTempC)) °C")
                                .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                        }
                    }
                    Text("いずれかのセンサーがしきい値を超えると、カーブと上限を無視して全ファンを最大回転にします。\n"
                         + "実測では Apple 標準はこの機体を 117 °C まで許容し、106 °C までファンを最低回転に保ちます。"
                         + "低く設定しすぎると、高負荷のたびに緊急冷却が常態化します。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ForEach($store.config.fans) { $fan in
                    section(fan.name, icon: "fan") {
                        LabeledContent("ヒステリシス") {
                            HStack {
                                Slider(value: $fan.hysteresisC, in: 0...8, step: 0.5).frame(width: 220)
                                Text(String(format: "%.1f °C", fan.hysteresisC))
                                    .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                            }
                        }
                        LabeledContent("温度の平滑化") {
                            HStack {
                                Slider(value: $fan.smoothingSeconds, in: 0...20, step: 0.5).frame(width: 220)
                                Text(String(format: "%.1f 秒", fan.smoothingSeconds))
                                    .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                            }
                        }
                        LabeledContent("加速の上限") {
                            HStack {
                                Slider(value: $fan.rampUpRPMPerSec, in: 50...3000, step: 50).frame(width: 220)
                                Text("\(Int(fan.rampUpRPMPerSec)) rpm/s")
                                    .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                            }
                        }
                        LabeledContent("減速の上限") {
                            HStack {
                                Slider(value: $fan.rampDownRPMPerSec, in: 50...3000, step: 50).frame(width: 220)
                                Text("\(Int(fan.rampDownRPMPerSec)) rpm/s")
                                    .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                            }
                        }
                        LabeledContent("回転数の上限") {
                            HStack {
                                Slider(value: $fan.maxRPMCap,
                                       in: 2500...(store.hardware(for: fan.index)?.maxRPM ?? 7450),
                                       step: 50).frame(width: 220)
                                Text("\(Int(fan.maxRPMCap)) rpm")
                                    .font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
                            }
                        }
                        Text("カーブがこれを超えても、ここで頭打ちになります（緊急冷却時を除く）。"
                             + "実測では Apple 自身は 117.6 °C でも定格の 73 % までしか回しませんでした。")
                            .font(.caption).foregroundStyle(.secondary)

                        Toggle("0 rpm の区間はシステム制御に任せる", isOn: $fan.zeroMeansSystem)
                        Text("オフにすると 0 rpm でファンを止めます。発熱時も止まったままになるため、通常はオンのままにしてください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("ファン制御の動作確認", icon: "checkmark.seal") {
                    Text("ファンを約15秒間まわして、この Mac で書き込みが効くかを実測します。終了後は元の状態に戻します。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("ファン", selection: $probeFan) {
                            ForEach(store.hardware) { hw in Text(hw.defaultName).tag(hw.index) }
                        }
                        .frame(width: 180)
                        Slider(value: $probeRPM, in: 2000...6000, step: 100).frame(width: 180)
                        Text("\(Int(probeRPM)) rpm").font(.system(.callout, design: .monospaced)).frame(width: 80)
                        Button(store.isProbing ? "実行中…" : "テスト実行") {
                            store.runProbe(fanIndex: probeFan, rpm: probeRPM)
                        }
                        .disabled(store.isProbing)
                    }
                    if let p = store.probeResult {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.worked ? "✅ 制御できます" : "❌ ファンが応答しませんでした")
                                .font(.callout.bold())
                                .foregroundStyle(p.worked ? .green : .red)
                            Text("開始 \(Int(p.baselineRPM)) rpm → 目標のみ \(Int(p.tgOnlyRPM)) rpm"
                                 + (p.tgPlusModeRPM >= 0 ? " → Md=1 併用 \(Int(p.tgPlusModeRPM)) rpm" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("方式: " + (p.needsModeKey ? "F\(p.fanIndex)Md=1 が必要" : "F\(p.fanIndex)Tg のみで有効"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }
                }

                section("状態", icon: "info.circle") {
                    LabeledContent("このアプリのビルド",
                                   value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "不明")
                    LabeledContent("デーモン", value: store.isConnected ? "接続中" : "未接続")
                    LabeledContent("root 権限", value: (store.status?.isRoot ?? false) ? "あり" : "なし")
                    LabeledContent("電源", value: (store.status?.onACPower ?? false) ? "AC 電源" : "バッテリー")
                    LabeledContent("ブースト", value: store.status?.boostBlockedReason ?? "条件を満たしています")
                    LabeledContent("設定ファイル", value: AppConfig.defaultPath)
                    LabeledContent("ソケット", value: IPC.socketPath)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
    }
}
