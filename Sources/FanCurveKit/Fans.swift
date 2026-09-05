import Foundation

public struct FanHardware: Codable, Hashable, Sendable, Identifiable {
    public let index: Int
    public let minRPM: Double
    public let maxRPM: Double
    public var id: Int { index }

    public init(index: Int, minRPM: Double, maxRPM: Double) {
        self.index = index; self.minRPM = minRPM; self.maxRPM = maxRPM
    }

    /// The Mac's own label for the fan position; M3 Max MacBook Pros have two.
    public var defaultName: String {
        switch index {
        case 0:  return "ファン 左"
        case 1:  return "ファン 右"
        default: return "ファン \(index + 1)"
        }
    }
}

public struct FanStatus: Codable, Hashable, Sendable, Identifiable {
    public let index: Int
    public let name: String
    public let actualRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    /// What the SMC reports for `F%dTg`. Unreliable on Apple silicon — it returns 0 right
    /// after a successful write and stale values later — so the UI shows `commandedRPM`.
    public let targetRPM: Double
    /// What this daemon last asked for, which is the number that actually means something.
    public let commandedRPM: Double?
    public let modeByte: Int
    public let controlled: Bool
    public let sourceLabel: String
    public let sourceTempC: Double?
    public var id: Int { index }

    public init(index: Int, name: String, actualRPM: Double, minRPM: Double, maxRPM: Double,
                targetRPM: Double, commandedRPM: Double?, modeByte: Int, controlled: Bool,
                sourceLabel: String, sourceTempC: Double?) {
        self.index = index
        self.name = name
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.commandedRPM = commandedRPM
        self.modeByte = modeByte
        self.controlled = controlled
        self.sourceLabel = sourceLabel
        self.sourceTempC = sourceTempC
    }
}

/// Reads and (as root) drives the SMC fan keys.
///
/// The write path is deliberately conservative:
///   * the original `F%dMd` byte is captured before anything is forced and written back on release,
///   * targets are clamped to `[F%dMn, F%dMx]` as reported by the firmware,
///   * `release()` is idempotent so it is safe to call from a signal handler.
public final class FanController {

    public private(set) var fans: [FanHardware] = []
    /// `F%dMd` as it was before we touched it, so shutdown restores the exact firmware state.
    private var originalMode: [Int: UInt8] = [:]
    private var forced: Set<Int> = []

    /// The value `F%dMd` holds when the Mac's own controller owns the fan. This is **not**
    /// always 0 — an M3 Max MacBook Pro reports 3 — so it is captured on the daemon's very
    /// first run and persisted, and every release path writes it back rather than a guess.
    public var firmwareDefaultMode: [Int: UInt8] = [:]

    /// Some firmware honours `F%dTg` on its own; others only obey it once `F%dMd` is set to 1.
    /// Determined at runtime by `probeControlMode` and persisted in the daemon state.
    public var requiresModeKey: Bool = true

    public init() {}

    public func enumerateFans() {
        guard let n = SMC.shared.readUInt8("FNum") else { fans = []; return }
        var list: [FanHardware] = []
        for i in 0..<Int(n) {
            let minR = SMC.shared.readDouble("F\(i)Mn") ?? 0
            let maxR = SMC.shared.readDouble("F\(i)Mx") ?? 0
            guard maxR > 0 else { continue }
            list.append(FanHardware(index: i, minRPM: minR, maxRPM: maxR))
        }
        fans = list
    }

    public func actualRPM(_ i: Int) -> Double { SMC.shared.readDouble("F\(i)Ac") ?? 0 }
    public func targetRPM(_ i: Int) -> Double { SMC.shared.readDouble("F\(i)Tg") ?? 0 }
    public func modeByte(_ i: Int) -> UInt8   { SMC.shared.readUInt8("F\(i)Md") ?? 0 }

    public func isControlled(_ i: Int) -> Bool { forced.contains(i) }

    public func clamp(_ i: Int, _ rpm: Double) -> Double {
        guard let fan = fans.first(where: { $0.index == i }) else { return rpm }
        return min(max(rpm, fan.minRPM), fan.maxRPM)
    }

    // MARK: - Control

    /// Take over a fan and drive it to `rpm`. Values below the firmware minimum are raised to it;
    /// use `release` to hand the fan back to the system controller instead.
    ///
    /// `F%dMd` is written on a best-effort basis only. Some firmware rejects it outright — an
    /// M3 Max returns SMC status 0x85 for `F1Md` — and on those machines `F%dTg` alone is what
    /// drives the fan, so a refused mode write must never stop us from writing the target.
    @discardableResult
    public func setTarget(_ i: Int, rpm: Double) -> Result<Double, SMCError> {
        let target = clamp(i, rpm)
        if originalMode[i] == nil { originalMode[i] = modeByte(i) }

        if requiresModeKey, !forced.contains(i), !modeWriteRefused.contains(i) {
            do {
                try SMC.shared.writeUInt8("F\(i)Md", 1)
                wroteModeKey.insert(i)
            } catch {
                // Remember the refusal so we stop hammering a key this Mac will never accept,
                // and fall back to driving the target on its own.
                modeWriteRefused.insert(i)
                lastModeError[i] = "\(error)"
            }
        }

        do {
            try SMC.shared.writeFloat("F\(i)Tg", Float(target))
            forced.insert(i)
            return .success(target)
        } catch let e as SMCError {
            return .failure(e)
        } catch {
            return .failure(.callFailed("F\(i)Tg", -1, 0))
        }
    }

    /// Fans whose `F%dMd` this process actually changed, and therefore owes a restore.
    private var wroteModeKey: Set<Int> = []
    /// Fans whose `F%dMd` the firmware refused, so we only drive `F%dTg` for them.
    public private(set) var modeWriteRefused: Set<Int> = []
    /// The error text for the refusal, surfaced in the UI once we know the fallback worked.
    public private(set) var lastModeError: [Int: String] = [:]

    /// Hand the fan back to the Mac's own thermal controller.
    ///
    /// Clearing `F%dTg` is the whole job. `F%dMd` is only touched if this process forced it,
    /// because a speculative write there can leave the fan in a mode no write can undo.
    public func release(_ i: Int) {
        guard forced.contains(i) || wroteModeKey.contains(i) else { return }
        try? SMC.shared.writeFloat("F\(i)Tg", 0)
        if wroteModeKey.contains(i), let restore = firmwareDefaultMode[i] ?? originalMode[i] {
            try? SMC.shared.writeUInt8("F\(i)Md", restore)
            wroteModeKey.remove(i)
        }
        forced.remove(i)
    }

    public func releaseAll() {
        for fan in fans { release(fan.index) }
    }

    /// Unconditionally return every fan to firmware control, even ones this process never
    /// claimed. Used at daemon start-up and by `fancurvectl reset` to clean up after a crash.
    /// Never writes `F%dMd`: clearing the target is what hands the fan back, and a mode write
    /// here would be a guess at a value the firmware may refuse or refuse to undo.
    public func forceReleaseAll() {
        if fans.isEmpty { enumerateFans() }
        for fan in fans {
            try? SMC.shared.writeFloat("F\(fan.index)Tg", 0)
        }
        forced.removeAll()
        originalMode.removeAll()
        wroteModeKey.removeAll()
    }

    /// Reads the current `F%dMd` of every fan. Only meaningful before anything is forced.
    public func captureFirmwareDefaults() -> [Int: UInt8] {
        var result: [Int: UInt8] = [:]
        for fan in fans { result[fan.index] = modeByte(fan.index) }
        return result
    }

    // MARK: - Manual-control unlock (Apple silicon M3 and later)

    /// The diagnostic-mode flag. From M3 on, `thermalmonitord` holds the fans in mode 3 and the
    /// firmware answers mode-key writes with status 0x82. Writing `Ftst = 1` suppresses the
    /// daemon's reclaim and is what makes `F%dMd` / `F%dTg` writable at all; writing 0 hands
    /// control straight back, and the daemon reclaims within roughly 250–4000 ms.
    ///
    /// While this flag is set, macOS's normal thermal management is suppressed and keeping the
    /// machine cool is *our* responsibility. The firmware's own last-ditch protection stays
    /// active, and a crash is recovered by the daemon reclaiming, but every ordinary exit path
    /// must clear it.
    public static let forceTestKey = "Ftst"

    /// Mode 3 means the firmware has the fan parked; a `F%dTg` write in that state is accepted
    /// and then ignored, which is why writes appeared to succeed while nothing spun.
    public static let modeSystem: UInt8 = 3
    public static let modeAuto: UInt8 = 0
    public static let modeManual: UInt8 = 1

    public private(set) var forceTestEngaged = false

    public var supportsForceTest: Bool {
        SMC.shared.meta(Self.forceTestKey)?.isWritable ?? false
    }

    public func forceTestValue() -> UInt8? { SMC.shared.readUInt8(Self.forceTestKey) }

    /// M4 and earlier spell the mode key `F0Md`; M5 uses `F0md`. Probe rather than assume.
    public func modeKey(_ i: Int) -> String {
        let upper = "F\(i)Md"
        if SMC.shared.meta(upper) != nil { return upper }
        return "F\(i)md"
    }

    /// Some firmware answers a `F%dTg` write with 0x87 while still applying the value, so that
    /// status is treated as success rather than retried into a failure.
    private func writeTolerantly(_ key: String, float value: Float) throws {
        do { try SMC.shared.writeFloat(key, value) }
        catch let e as SMCError {
            if case .callFailed(_, _, let status) = e, status == 0x87 { return }
            throw e
        }
    }

    public struct UnlockReport: Sendable {
        public var usedForceTest = false
        public var initialMode: UInt8 = 0
        public var modeAfterForceTest: UInt8 = 0
        public var yieldSeconds: Double = 0
        public var modeWriteAttempts = 0
        public var finalMode: UInt8 = 0
        public var succeeded = false
        public var detail: String = ""
    }

    /// Puts one fan into manual mode, using the `Ftst` unlock only if a direct write is refused.
    ///
    /// M1-era machines accept `F%dMd = 1` outright, so the direct write is tried first and the
    /// diagnostic flag is only engaged when the firmware refuses — that keeps the window during
    /// which macOS's thermal management is suppressed as short as possible.
    public func unlockManualControl(fanIndex i: Int, timeout: Double = 10,
                                    writeRetryWindow: Double = 6) -> UnlockReport {
        var report = UnlockReport()
        let mdKey = modeKey(i)
        report.initialMode = SMC.shared.readUInt8(mdKey) ?? 0

        func tryModeWrite() -> Bool {
            report.modeWriteAttempts += 1
            do { try SMC.shared.writeUInt8(mdKey, Self.modeManual); return true }
            catch { return false }
        }

        if tryModeWrite() {
            report.finalMode = SMC.shared.readUInt8(mdKey) ?? 0
            report.succeeded = report.finalMode == Self.modeManual
            report.detail = report.succeeded ? "直接 \(mdKey)=1 が通りました" : "\(mdKey)=1 は受理されたが反映されず"
            if report.succeeded { forced.insert(i); return report }
        }

        guard supportsForceTest else {
            report.detail = "\(mdKey) を書けず、\(Self.forceTestKey) もありません"
            return report
        }

        // Engage diagnostic mode and wait for the daemon to let go of mode 3.
        report.usedForceTest = true
        do { try SMC.shared.writeUInt8(Self.forceTestKey, 1) }
        catch {
            report.detail = "\(Self.forceTestKey)=1 を書けません: \(error)"
            return report
        }
        forceTestEngaged = true

        let start = Date()
        var mode = SMC.shared.readUInt8(mdKey) ?? Self.modeSystem
        while mode == Self.modeSystem, Date().timeIntervalSince(start) < timeout {
            Thread.sleep(forTimeInterval: 0.1)
            mode = SMC.shared.readUInt8(mdKey) ?? Self.modeSystem
        }
        report.yieldSeconds = Date().timeIntervalSince(start)
        report.modeAfterForceTest = mode

        if mode == Self.modeSystem {
            report.detail = "\(Int(timeout)) 秒待っても mode 3 のままでした"
            return report
        }

        // The mode write can need a few tries while the daemon finishes handing over.
        let writeDeadline = Date().addingTimeInterval(writeRetryWindow)
        while Date() < writeDeadline {
            if tryModeWrite(), SMC.shared.readUInt8(mdKey) == Self.modeManual { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        report.finalMode = SMC.shared.readUInt8(mdKey) ?? 0
        report.succeeded = report.finalMode == Self.modeManual
        report.detail = report.succeeded
            ? "\(Self.forceTestKey)=1 → mode \(report.initialMode)→\(mode) → \(mdKey)=1"
            : "\(mdKey)=1 が反映されませんでした（mode=\(report.finalMode)）"
        if report.succeeded { forced.insert(i) }
        return report
    }

    /// Sets a target on a fan already unlocked by `unlockManualControl`.
    @discardableResult
    public func setManualTarget(_ i: Int, rpm: Double) -> Result<Double, SMCError> {
        let target = clamp(i, rpm)
        do {
            try writeTolerantly("F\(i)Tg", float: Float(target))
            forced.insert(i)
            return .success(target)
        } catch let e as SMCError {
            return .failure(e)
        } catch {
            return .failure(.callFailed("F\(i)Tg", -1, 0))
        }
    }

    /// Hands every fan back to macOS. Clearing `Ftst` is the whole job: `thermalmonitord`
    /// reclaims and restores mode 3 on its own. Idempotent, and safe to call from a signal path.
    public func restoreSystemControl() {
        if forceTestEngaged || (forceTestValue() ?? 0) != 0 {
            try? SMC.shared.writeUInt8(Self.forceTestKey, 0)
            forceTestEngaged = false
        }
        forced.removeAll()
    }

    /// Waits for the daemon to put the fan back into mode 3 after `restoreSystemControl`.
    @discardableResult
    public func waitForSystemReclaim(fanIndex i: Int, timeout: Double = 15) -> (reclaimed: Bool, seconds: Double, mode: UInt8) {
        let mdKey = modeKey(i)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let m = SMC.shared.readUInt8(mdKey) ?? 0
            if m == Self.modeSystem { return (true, Date().timeIntervalSince(start), m) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (false, Date().timeIntervalSince(start), SMC.shared.readUInt8(mdKey) ?? 0)
    }

    /// Applies one cycle's plan. `nil` means "hold nothing" and is the only path that needs no
    /// preconditions — releasing is always allowed, and always safe.
    ///
    /// Engaging is the expensive, conditional case: `Ftst` is only taken when a plan exists,
    /// and it is dropped the moment one does not.
    @discardableResult
    public func applyBoost(_ plan: [Int: Double]?, unlockTimeout: Double = 3) -> [String] {
        guard let plan, !plan.isEmpty else {
            restoreSystemControl()
            return []
        }

        // Never trust the belief that we still hold control; verify it against the hardware
        // every cycle.
        //
        // Measured across a sleep/wake on an M3 Max: `Ftst` stayed 1, but `F%dMd` was put back
        // to 3 and `F%dTg` cleared. Checking only the flag would pass, and every subsequent
        // target write would be accepted and silently ignored, because mode 3 means the fan is
        // parked. So the mode is checked per fan too, and any fan back in mode 3 is re-acquired.
        if forceTestEngaged, (forceTestValue() ?? 0) == 0 {
            forceTestEngaged = false
            forced.removeAll()
        }
        for index in forced where SMC.shared.readUInt8(modeKey(index)) == Self.modeSystem {
            forced.remove(index)
        }

        var problems: [String] = []
        for (index, rpm) in plan.sorted(by: { $0.key < $1.key }) {
            if !forced.contains(index) {
                let report = unlockManualControl(fanIndex: index,
                                                 timeout: unlockTimeout,
                                                 writeRetryWindow: 3)
                if !report.succeeded {
                    problems.append("fan\(index): \(report.detail)")
                    continue
                }
            }
            if case .failure(let e) = setManualTarget(index, rpm: rpm) {
                problems.append("fan\(index): \(e)")
            }
        }

        // If nothing could be driven, do not sit on the flag with macOS locked out.
        if problems.count == plan.count { restoreSystemControl() }
        return problems
    }

    // MARK: - Capability probe


    public struct ProbeResult: Codable, Sendable {
        public var fanIndex: Int
        public var originalMode: Int
        public var originalTarget: Double
        public var baselineRPM: Double
        public var tgOnlyRPM: Double
        public var tgPlusModeRPM: Double
        public var requestedRPM: Double
        public var writeError: String?
        /// True when `F%dMd` had to be set to 1 before `F%dTg` took effect.
        public var needsModeKey: Bool
        public var worked: Bool
    }

    /// Spins one fan up briefly to learn which write actually takes effect, then restores
    /// the firmware state. Requires root.
    public func probeControlMode(fanIndex i: Int, requestRPM: Double, settleSeconds: Double = 6) -> ProbeResult {
        let origMode = modeByte(i)
        let origTarget = targetRPM(i)
        let baseline = actualRPM(i)
        let request = clamp(i, requestRPM)
        var r = ProbeResult(fanIndex: i, originalMode: Int(origMode), originalTarget: origTarget,
                            baselineRPM: baseline, tgOnlyRPM: -1, tgPlusModeRPM: -1,
                            requestedRPM: request, writeError: nil, needsModeKey: true, worked: false)

        // 1) target only
        do { try SMC.shared.writeFloat("F\(i)Tg", Float(request)) }
        catch { r.writeError = "\(error)"; return r }
        Thread.sleep(forTimeInterval: settleSeconds)
        r.tgOnlyRPM = actualRPM(i)

        if r.tgOnlyRPM > baseline + 200 || r.tgOnlyRPM > request * 0.8 {
            r.needsModeKey = false
            r.worked = true
        } else {
            // 2) forced mode + target
            do { try SMC.shared.writeUInt8("F\(i)Md", 1) }
            catch { r.writeError = "\(error)" }
            do { try SMC.shared.writeFloat("F\(i)Tg", Float(request)) }
            catch { r.writeError = "\(error)" }
            Thread.sleep(forTimeInterval: settleSeconds)
            r.tgPlusModeRPM = actualRPM(i)
            r.needsModeKey = true
            r.worked = r.tgPlusModeRPM > baseline + 200 || r.tgPlusModeRPM > request * 0.8
        }

        // Only undo the mode key if this probe was the thing that changed it.
        if r.tgPlusModeRPM >= 0 { try? SMC.shared.writeUInt8("F\(i)Md", origMode) }
        try? SMC.shared.writeFloat("F\(i)Tg", 0)
        return r
    }
}
