import Foundation
import FanCurveKit

/// Root-side control loop. Everything that touches SMC write keys lives here.
final class Daemon {

    private let lock = NSRecursiveLock()
    private let fanController = FanController()
    private let catalog = SensorCatalog()

    private var config: AppConfig
    private var configPath: String

    /// Per-fan control state carried between ticks.
    private struct FanState {
        var smoothedTemp: Double?
        var hysteresisTemp: Double?
        var appliedRPM: Double = 0
        var releasedToSystem = true
    }
    private var state: [Int: FanState] = [:]

    private var lastTick = Date()
    private var loggedModeFallback: Set<Int> = []
    private var loggedFloor: Set<Int> = []

    /// Health counters. Any of these tripping hands the fans back to the firmware, which is
    /// the only behaviour that is safe in both directions: a fan that will not spin when it
    /// is needed and one that spins when it is not are both failures.
    private var readFailures = 0
    private var writeFailures = 0
    private var frozenTicks = 0
    private var healthyTicks = 0
    private var emergencyTicks = 0
    private var lastRawSystemMax: Double?
    private var failsafeReason: String?
    /// Last time the GUI checked in. Distant past means "no app", which is the resting state.
    private var lastAppHeartbeat = Date.distantPast
    private var boostBlockedReason: String?
    private var loggedBlockReason: String?

    /// Consecutive bad ticks before the corresponding failsafe engages.
    private static let readFailureLimit = 3
    private static let writeFailureLimit = 3
    /// A die probe jitters constantly; a bit-identical value for this many ticks means the
    /// reading is stale, not that the machine is unusually steady.
    private static let frozenTickLimit = 120
    private static let recoveryTicks = 10
    /// The emergency override needs corroboration so one glitched probe cannot pin the fans.
    private static let emergencySensorQuorum = 2
    private static let emergencyTickLimit = 2

    /// Read by the watchdog thread, which must never take `lock`.
    private let tickStampLock = NSLock()
    private var lastTickStamp = Date()
    private var lastError: String?
    private var emergency = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fancurved.control")

    init(configPath: String) {
        self.configPath = configPath
        self.config = AppConfig()
    }

    // MARK: - Lifecycle

    func start() throws {
        try SMC.shared.open()

        // Before anything else — before enumerating fans, before the 2,800-key sensor scan —
        // undo a diagnostic flag left set by a previous instance that was killed. Nothing on
        // this machine clears it for us (measured: still set 90 s after SIGKILL), and launchd
        // restarts us in ~0.12 s, so this write is what bounds the exposure window.
        if let stale = fanController.forceTestValue(), stale != 0 {
            fanController.restoreSystemControl()
            log("起動時に \(FanController.forceTestKey)=\(stale) が残っていたため 0 に戻しました"
                + "（前回のインスタンスが後片付けせずに終了しています）")
        }

        fanController.enumerateFans()
        catalog.discover()

        log("ファン \(fanController.fans.count) 基、温度センサー \(catalog.sensors.count) 個を検出")
        for f in fanController.fans {
            log("  fan\(f.index): \(Int(f.minRPM))–\(Int(f.maxRPM)) rpm")
        }

        if var loaded = AppConfig.load(from: configPath) {
            loaded.reconcile(hardware: fanController.fans)
            config = loaded
        } else {
            config = AppConfig.makeDefault(hardware: fanController.fans)
            try? config.save(to: configPath)
            log("既定の設定を作成: \(configPath)")
        }
        fanController.requiresModeKey = config.requiresModeKey

        // Learn what "system controlled" looks like on this machine, once, while the fans are
        // still untouched. On an M3 Max F%dMd reads 3, not the 0 most write-ups assume.
        if config.firmwareFanMode.isEmpty {
            let defaults = fanController.captureFirmwareDefaults()
            config.firmwareFanMode = Dictionary(uniqueKeysWithValues: defaults.map { (String($0.key), Int($0.value)) })
            try? config.save(to: configPath)
            log("ファームウェア既定モードを記録: " + defaults.map { "F\($0.key)Md=\($0.value)" }.joined(separator: " "))
        }
        fanController.firmwareDefaultMode = Dictionary(uniqueKeysWithValues:
            config.firmwareFanMode.compactMap { key, value in
                Int(key).map { ($0, UInt8(clamping: value)) }
            })

        // Self-heal: if a previous run was killed while holding the fans, reclaim them now.
        fanController.forceReleaseAll()

        for f in fanController.fans { state[f.index] = FanState() }

        scheduleTimer()
        startWatchdog()
    }

    /// If the control loop stops ticking, the fans keep whatever they were last told —
    /// possibly full speed, possibly too slow. Neither is acceptable, so exit and let
    /// launchd restart us; start-up unconditionally releases the fans.
    private func startWatchdog() {
        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 2)
                guard let self else { return }
                self.tickStampLock.lock()
                let age = Date().timeIntervalSince(self.lastTickStamp)
                self.tickStampLock.unlock()
                if age > 10 {
                    self.log("制御ループが \(Int(age)) 秒停止しました。終了して launchd に再起動させます" +
                             "（再起動時にファンは解放されます）")
                    exit(1)
                }
            }
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(250, config.updateIntervalMs)
        t.schedule(deadline: .now() + .milliseconds(interval),
                   repeating: .milliseconds(interval))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Hand every fan back to the firmware. Safe to call more than once.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil
        fanController.restoreSystemControl()
        log("\(FanController.forceTestKey)=0 を書いてシステム制御に戻しました")
    }

    // MARK: - Control loop

    private func tick() {
        tickStampLock.lock(); lastTickStamp = Date(); tickStampLock.unlock()

        lock.lock(); defer { lock.unlock() }

        let now = Date()
        let dt = max(0.05, min(5.0, now.timeIntervalSince(lastTick)))
        lastTick = now

        let readings = catalog.readAll()

        // --- health checks -------------------------------------------------------------
        readFailures = readings.isEmpty ? readFailures + 1 : 0

        let rawSystemMax = catalog.systemMax(in: readings)
        if let raw = rawSystemMax, let previous = lastRawSystemMax, raw == previous {
            frozenTicks += 1
        } else {
            frozenTicks = 0
        }
        lastRawSystemMax = rawSystemMax

        if let reason = failsafeTrigger() {
            engageFailsafe(reason)
            return
        }
        if failsafeReason != nil {
            healthyTicks += 1
            guard healthyTicks >= Self.recoveryTicks else { return }
            log("状態が回復したため通常制御に戻ります（\(failsafeReason ?? "")）")
            failsafeReason = nil
            lastError = nil
            healthyTicks = 0
        }
        guard !readings.isEmpty else { return }

        let sysMax = rawSystemMax ?? 0

        // One probe reading hot is not enough to justify running every fan flat out.
        let hotSensors = readings.filter {
            $0.group != .battery && $0.group != .ambient && $0.value >= config.emergencyTempC
        }.count
        if hotSensors >= Self.emergencySensorQuorum {
            emergencyTicks += 1
        } else {
            emergencyTicks = 0
        }
        let wasEmergency = emergency
        emergency = emergencyTicks >= Self.emergencyTickLimit
        if emergency != wasEmergency {
            log(emergency ? "緊急冷却を開始します（\(hotSensors) 個のセンサーが \(Int(config.emergencyTempC)) °C 超）"
                          : "緊急冷却を解除しました")
        }

        // Issue permits for this cycle. Anything that cannot be positively justified simply
        // does not produce one, and a cycle with no permits is the instruction to let go.
        var permits: [BoostPermit] = []
        // What each fan's curve actually asked for, before BoostPlan raises it to the floor.
        // The ramp must carry this value forward, not the floored one: storing the floored
        // value made the ramp bottom out at the floor, so the "let go" threshold below it was
        // unreachable and the fans held 2,500 rpm at 52 °C forever.
        var requestedByFan: [Int: Double] = [:]

        // Preconditions for ordinary boost. Emergency ignores them: an override that stops
        // working because the laptop was unplugged would not be an override.
        let onAC = PowerSource.isOnACPower()
        let blocked = BoostPreconditions.blockReason(
            requiresCharging: config.boostRequiresCharging,
            onACPower: onAC,
            requiresApp: config.boostRequiresApp,
            secondsSinceAppHeartbeat: Date().timeIntervalSince(lastAppHeartbeat),
            heartbeatTimeout: config.appHeartbeatTimeoutSec)
        boostBlockedReason = blocked
        if blocked != loggedBlockReason {
            loggedBlockReason = blocked
            log(blocked.map { "ブーストを見合わせます: \($0)" } ?? "ブーストの条件が揃いました")
        }

        for hw in fanController.fans {
            guard let curve = config.fans.first(where: { $0.index == hw.index }) else { continue }
            var st = state[hw.index] ?? FanState()

            let raw = curve.source.value(in: readings) ?? sysMax
            let alpha = curve.smoothingSeconds <= 0 ? 1.0 : min(1.0, dt / curve.smoothingSeconds)
            let smoothed = st.smoothedTemp.map { $0 + (raw - $0) * alpha } ?? raw
            st.smoothedTemp = smoothed

            let gate = st.hysteresisTemp ?? smoothed
            let effective: Double
            if smoothed >= gate { effective = smoothed }
            else if smoothed <= gate - curve.hysteresisC { effective = smoothed }
            else { effective = gate }
            st.hysteresisTemp = effective

            var wanted: Double?
            if emergency {
                wanted = hw.maxRPM
            } else if blocked != nil {
                wanted = nil
            } else if !curve.enabled {
                wanted = nil
            } else {
                switch config.mode {
                case .system: wanted = nil
                case .manual: wanted = curve.manualRPM > 0 ? curve.manualRPM : nil
                case .curve:  wanted = curve.rpm(at: effective)
                }
            }

            if let target = wanted {
                // Ramp so the fan does not step audibly between cycles. The floor is applied
                // afterwards by BoostPlan, so this can never ramp down into an unsafe value.
                let current = st.releasedToSystem ? BoostPlan.defaultFloorRPM : st.appliedRPM
                let limit = target > current
                    ? current + max(1, curve.rampUpRPMPerSec) * dt
                    : current - max(1, curve.rampDownRPMPerSec) * dt
                let stepped = target > current ? min(target, limit) : max(target, limit)

                // Two different floors, for two different failures:
                //  * SafetyFloor is temperature-driven and guards against a curve drawn weaker
                //    than macOS would be — while we hold the flag, macOS cannot correct it.
                //    It is applied after the ramp limiter, because safety must not be rate-limited.
                //  * BoostPlan's flat floor is applied later and guards the stuck-flag case.
                let safety = SafetyFloor.minimumRPM(tempC: max(effective, sysMax), maxRPM: hw.maxRPM)
                if stepped < safety, !loggedFloor.contains(hw.index) {
                    loggedFloor.insert(hw.index)
                    log("fan\(hw.index): \(Int(sysMax)) °C のため指示を安全下限 \(Int(safety)) rpm へ引き上げました")
                } else if safety <= 0 {
                    loggedFloor.remove(hw.index)
                }

                // The user's ceiling applies to ordinary running only. An emergency is the one
                // case where noise and wear stop mattering.
                let ceilinged = emergency
                    ? max(stepped, safety)
                    : BoostPlan.applyCap(max(stepped, safety),
                                         cap: curve.maxRPMCap,
                                         safetyFloorRPM: safety,
                                         maxRPM: hw.maxRPM)
                let requested = BoostPlan.requestedSpeed(rampedRPM: ceilinged, maxRPM: hw.maxRPM)

                // Anything below the floor cannot be delivered, only rounded up to it. Taking
                // control to run *faster* than the user asked would be worse than doing nothing,
                // so below the floor we issue no permit and macOS keeps the fans.
                requestedByFan[hw.index] = requested
                if emergency || BoostPlan.worthHolding(requestedRPM: requested,
                                                       alreadyHolding: fanController.forceTestEngaged) {
                    permits.append(BoostPermit(fanIndex: hw.index, rpm: requested))
                }
            }

            state[hw.index] = st
        }

        let plan = BoostPlan.make(permits: permits,
                                  hardware: fanController.fans,
                                  floorRPM: BoostPlan.defaultFloorRPM)
        let problems = fanController.applyBoost(plan)

        for hw in fanController.fans {
            var st = state[hw.index] ?? FanState()
            if plan?[hw.index] != nil, problems.isEmpty {
                st.appliedRPM = requestedByFan[hw.index] ?? BoostPlan.defaultFloorRPM
                st.releasedToSystem = false
            } else {
                st.appliedRPM = 0
                st.releasedToSystem = true
            }
            state[hw.index] = st
        }

        if problems.isEmpty {
            lastError = nil
        } else {
            lastError = problems.joined(separator: " / ")
        }
        writeFailures = problems.isEmpty ? 0 : writeFailures + 1
    }

    // MARK: - Failsafe

    /// Why the daemon must stop driving the fans, or nil while everything is trustworthy.
    ///
    /// Every trigger resolves to the same action — hand the fans back to the firmware — because
    /// that is the only response that is safe in both directions. A fan that will not spin when
    /// it is needed and a fan that spins when it is not are both failures of this program.
    private func failsafeTrigger() -> String? {
        if readFailures >= Self.readFailureLimit {
            return "温度センサーを読み取れません"
        }
        if frozenTicks >= Self.frozenTickLimit {
            return "温度の値が \(frozenTicks) ティック更新されていません（センサー停止の疑い）"
        }
        if writeFailures >= Self.writeFailureLimit {
            return "SMC への書き込みが \(writeFailures) 回連続で失敗しています"
        }
        return nil
    }

    private func engageFailsafe(_ reason: String) {
        healthyTicks = 0
        guard failsafeReason == nil else { return }
        failsafeReason = reason
        lastError = "フェイルセーフ: \(reason) — ファンをシステム制御に戻しました"
        fanController.restoreSystemControl()
        resetStates()
        log(lastError ?? reason)
    }

    // MARK: - Request handling

    func handle(_ req: DaemonRequest) -> DaemonResponse {
        lock.lock(); defer { lock.unlock() }

        // Only the GUI's own polling counts as liveness. A `fancurvectl status` in a loop must
        // not be able to keep the fans held on the app's behalf.
        if req.client == DaemonRequest.guiClient { lastAppHeartbeat = Date() }

        switch req.cmd {
        case .ping:
            return DaemonResponse(ok: true)

        case .status:
            return DaemonResponse(ok: true, status: buildStatus(), hardware: fanController.fans)

        case .getConfig:
            return DaemonResponse(ok: true, config: config, hardware: fanController.fans)

        case .setConfig:
            guard var incoming = req.config else { return .failure("config がありません") }
            incoming.reconcile(hardware: fanController.fans)
            let intervalChanged = incoming.updateIntervalMs != config.updateIntervalMs
            config = incoming
            fanController.requiresModeKey = config.requiresModeKey
            do { try config.save(to: configPath) }
            catch { return .failure("設定を保存できません: \(error)") }
            if intervalChanged { scheduleTimer() }
            if config.mode == .system { fanController.restoreSystemControl(); resetStates() }
            return DaemonResponse(ok: true, config: config, hardware: fanController.fans)

        case .setMode:
            guard let m = req.mode else { return .failure("mode がありません") }
            config.mode = m
            try? config.save(to: configPath)
            if m == .system { fanController.restoreSystemControl(); resetStates() }
            return DaemonResponse(ok: true, config: config)

        case .setManual:
            guard let i = req.fanIndex, let rpm = req.rpm else { return .failure("fanIndex / rpm がありません") }
            guard let idx = config.fans.firstIndex(where: { $0.index == i }) else { return .failure("ファン \(i) がありません") }
            config.fans[idx].manualRPM = rpm
            try? config.save(to: configPath)
            return DaemonResponse(ok: true, config: config)

        case .listSensors:
            return DaemonResponse(ok: true, sensors: catalog.readAll(), hardware: fanController.fans)

        case .probe:
            guard geteuid() == 0 else { return .failure("probe には root 権限が必要です") }
            let i = req.fanIndex ?? fanController.fans.first?.index ?? 0
            let want = req.rpm ?? 3500
            timer?.suspend()
            fanController.releaseAll()
            let result = fanController.probeControlMode(fanIndex: i, requestRPM: want)
            // Only a probe that actually moved the fan is allowed to authorise mode-key writes.
            config.requiresModeKey = result.needsModeKey && result.worked
            config.modeKeyConfirmed = result.worked
            fanController.requiresModeKey = config.requiresModeKey
            try? config.save(to: configPath)
            resetStates()
            timer?.resume()
            return DaemonResponse(ok: result.worked,
                                  error: result.worked ? nil : "ファンが応答しませんでした",
                                  config: config, probe: result)

        case .reset:
            fanController.restoreSystemControl()
            config.mode = .system
            try? config.save(to: configPath)
            resetStates()
            return DaemonResponse(ok: true, config: config)
        }
    }

    private func resetStates() {
        for f in fanController.fans { state[f.index] = FanState() }
    }

    private func buildStatus() -> SystemStatus {
        let readings = catalog.readAll()
        var groups: [String: Double] = [:]
        for g in SensorGroup.allCases {
            if let v = catalog.maxOf(group: g, in: readings) { groups[g.rawValue] = v }
        }
        let fans: [FanStatus] = fanController.fans.map { hw in
            let curve = config.fans.first { $0.index == hw.index }
            let src = curve?.source ?? .systemMax
            return FanStatus(index: hw.index,
                             name: curve?.name ?? hw.defaultName,
                             actualRPM: fanController.actualRPM(hw.index),
                             minRPM: hw.minRPM,
                             maxRPM: hw.maxRPM,
                             targetRPM: fanController.targetRPM(hw.index),
                             commandedRPM: state[hw.index]?.releasedToSystem == false
                                 ? state[hw.index]?.appliedRPM : nil,
                             modeByte: Int(fanController.modeByte(hw.index)),
                             controlled: fanController.isControlled(hw.index),
                             sourceLabel: src.label,
                             sourceTempC: state[hw.index]?.smoothedTemp ?? src.value(in: readings))
        }
        return SystemStatus(timestamp: Date().timeIntervalSince1970,
                            mode: config.mode,
                            fans: fans,
                            groupMax: groups,
                            systemMaxC: catalog.systemMax(in: readings),
                            emergency: emergency,
                            isRoot: geteuid() == 0,
                            lastError: lastError,
                            failsafeReason: failsafeReason,
                            holdingControl: fanController.forceTestEngaged,
                            boostFloorRPM: BoostPlan.defaultFloorRPM,
                            boostBlockedReason: boostBlockedReason,
                            onACPower: PowerSource.isOnACPower())
    }

    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }
}
