import SwiftUI
import FanCurveKit

@main
struct FanCurveApp: App {
    @StateObject private var store = DaemonStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("FanCurve", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 820, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("すべてのファンをシステム制御へ戻す") { store.resetToSystem() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the app's lifetime. Closing the window leaves this app resident in the menu bar,
    /// and App Nap would then throttle its polling — but that polling is the heartbeat the
    /// daemon uses to decide whether boosting is still allowed. A stalled poll would drop the
    /// fans back to macOS mid-workload. `allowingIdleSystemSleep` keeps normal sleep working.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "ファン制御の生存確認を送り続けるため")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Menu-bar title: hottest sensor plus the fastest fan, which is what you glance at.
struct MenuBarLabel: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades.fill")
            if let s = store.status {
                Text(String(format: "%.0f°", s.systemMaxC ?? 0)).monospacedDigit()
                if let fastest = s.fans.map(\.actualRPM).max(), fastest > 0 {
                    Text("\(Int(fastest))").monospacedDigit()
                }
            }
        }
        .onAppear { store.start() }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var store: DaemonStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = store.status {
                HStack {
                    Text("FanCurve").font(.headline)
                    Spacer()
                    Text(s.mode.displayName)
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }

                if s.emergency {
                    Label("緊急冷却中", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold()).foregroundStyle(.red)
                }

                Divider()

                ForEach(s.fans) { f in
                    HStack {
                        Image(systemName: "fan.fill").foregroundStyle(f.controlled ? Color.accentColor : .secondary)
                        Text(f.name).font(.callout)
                        Spacer()
                        Text("\(Int(f.actualRPM)) rpm").font(.system(.callout, design: .monospaced))
                    }
                }

                Divider()

                ForEach([SensorGroup.cpu, .gpu, .ssd, .battery], id: \.self) { g in
                    if let v = s.groupMax[g.rawValue] {
                        HStack {
                            Text(g.displayName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f °C", v)).font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                Divider()

                Picker("", selection: Binding(
                    get: { s.mode },
                    set: { store.setMode($0) })) {
                    ForEach(ControlMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

            } else {
                Label("fancurved に接続できません", systemImage: "bolt.horizontal.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button("ウインドウを開く") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { store.start() }
    }
}
