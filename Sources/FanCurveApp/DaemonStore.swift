import Foundation
import SwiftUI
import FanCurveKit

struct HistorySample: Identifiable {
    let id = UUID()
    let time: Date
    let systemMaxC: Double
    let fanRPM: [Int: Double]
    let fanTempC: [Int: Double]
}

/// Owns the connection to `fancurved`: polls status once a second and pushes
/// configuration changes back with a short debounce so dragging a curve point
/// does not flood the socket.
@MainActor
final class DaemonStore: ObservableObject {

    @Published private(set) var status: SystemStatus?
    @Published private(set) var hardware: [FanHardware] = []
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var connectionError: String?
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var probeResult: FanController.ProbeResult?
    @Published private(set) var isProbing = false

    /// The working copy the UI edits. Written back to the daemon on a debounce.
    @Published var config = AppConfig() {
        didSet { if !suppressPush && config != oldValue { schedulePush() } }
    }

    private var suppressPush = false
    private var pushWorkItem: DispatchWorkItem?
    private var pollTask: Task<Void, Never>?
    private let client = DaemonClient()
    private let historyLimit = 300      // 5 minutes at 1 Hz

    var isConnected: Bool { connectionError == nil && status != nil }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // At login after a reboot, macOS restores this app before the daemon is listening,
            // so the first fetch fails. Without retrying, the config stayed empty for the rest
            // of the session and the curve editor showed "ファンが見つかりません" forever.
            for attempt in 0..<10 {
                if await self?.loadConfig() == true { break }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Requests

    private func request(_ req: DaemonRequest) async -> DaemonResponse? {
        // Every call doubles as the liveness heartbeat: while this app is running and polling,
        // the daemon is allowed to boost. When it stops, boost lapses on its own.
        var req = req
        req.client = DaemonRequest.guiClient
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [client] in
                do {
                    continuation.resume(returning: try client.send(req))
                } catch {
                    Task { @MainActor [weak self] in self?.connectionError = "\(error)" }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @discardableResult
    func loadConfig() async -> Bool {
        guard let r = await request(DaemonRequest(cmd: .getConfig)), let cfg = r.config else { return false }
        suppressPush = true
        config = cfg
        suppressPush = false
        hardware = r.hardware ?? []
        connectionError = nil
        return true
    }

    private func poll() async {
        guard let r = await request(DaemonRequest(cmd: .status)) else { return }
        connectionError = nil
        guard let s = r.status else { return }
        status = s
        if let hw = r.hardware, hw != hardware { hardware = hw }

        // Belt and braces: if the daemon knows about fans but our copy of the config does not,
        // the initial fetch never landed. Pick it up rather than staying broken.
        if config.fans.isEmpty, !s.fans.isEmpty {
            await loadConfig()
        }

        var rpm: [Int: Double] = [:], temp: [Int: Double] = [:]
        for f in s.fans { rpm[f.index] = f.actualRPM; temp[f.index] = f.sourceTempC ?? 0 }
        history.append(HistorySample(time: Date(), systemMaxC: s.systemMaxC ?? 0,
                                     fanRPM: rpm, fanTempC: temp))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    func refreshSensors() async {
        guard let r = await request(DaemonRequest(cmd: .listSensors)) else { return }
        sensors = r.sensors ?? []
    }

    func setMode(_ mode: ControlMode) {
        suppressPush = true
        config.mode = mode
        suppressPush = false
        Task {
            _ = await request(DaemonRequest(cmd: .setMode, mode: mode))
            await loadConfig()
        }
    }

    func resetToSystem() {
        Task {
            _ = await request(DaemonRequest(cmd: .reset))
            await loadConfig()
        }
    }

    func runProbe(fanIndex: Int, rpm: Double) {
        guard !isProbing else { return }
        isProbing = true
        probeResult = nil
        Task {
            let r = await request(DaemonRequest(cmd: .probe, fanIndex: fanIndex, rpm: rpm))
            probeResult = r?.probe
            isProbing = false
            await loadConfig()
        }
    }

    // MARK: - Pushing edits

    private func schedulePush() {
        pushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.pushConfig() }
        }
        pushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func pushConfig() async {
        let snapshot = config
        guard let r = await request(DaemonRequest(cmd: .setConfig, config: snapshot)) else { return }
        if !r.ok { connectionError = r.error }
        if let hw = r.hardware { hardware = hw }
    }

    /// Force an immediate write, e.g. right before the window closes.
    func flush() {
        pushWorkItem?.cancel()
        Task { await pushConfig() }
    }

    // MARK: - Convenience

    func hardware(for index: Int) -> FanHardware? { hardware.first { $0.index == index } }

    func curveBinding(for index: Int) -> Binding<FanCurve>? {
        guard let i = config.fans.firstIndex(where: { $0.index == index }) else { return nil }
        return Binding(get: { self.config.fans[i] }, set: { self.config.fans[i] = $0 })
    }
}
