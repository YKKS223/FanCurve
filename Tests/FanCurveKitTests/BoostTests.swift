import XCTest
@testable import FanCurveKit

final class BoostPlanTests: XCTestCase {

    private let hardware = [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898),
                            FanHardware(index: 1, minRPM: 2502, maxRPM: 7450)]
    private let floor = BoostPlan.defaultFloorRPM

    func testNoPermitsMeansHandTheFansBack() {
        // The whole fail-safe rests on this: an empty cycle releases, it does not hold.
        XCTAssertNil(BoostPlan.make(permits: [], hardware: hardware, floorRPM: floor))
    }

    func testNoHardwareMeansHandTheFansBack() {
        XCTAssertNil(BoostPlan.make(permits: [BoostPermit(fanIndex: 0, rpm: 4000)],
                                    hardware: [], floorRPM: floor))
    }

    func testEveryFanIsCoveredEvenIfOnlyOneWasPermitted() {
        // Ftst is machine-wide; a fan left out would be unmanaged with macOS locked out.
        let plan = BoostPlan.make(permits: [BoostPermit(fanIndex: 0, rpm: 4000)],
                                  hardware: hardware, floorRPM: floor)
        XCTAssertEqual(plan?.count, 2)
        XCTAssertEqual(plan?[0], 4000)
        XCTAssertEqual(plan?[1], 2502, "the uncovered fan gets its own minimum, not zero")
    }

    func testRequestsBelowTheFloorAreRaised() {
        for requested in [0.0, 500, 1500, 2499] {
            let plan = BoostPlan.make(permits: [BoostPermit(fanIndex: 0, rpm: requested)],
                                      hardware: hardware, floorRPM: floor)
            XCTAssertEqual(plan?[0], 2500, "requested \(requested) must be raised to the floor")
        }
    }

    func testZeroIsNeverWrittenWhileHoldingControl() {
        // Ftst held with a target of 0 is the exact state that ran this machine to 81 °C with
        // the fans stopped and macOS unable to intervene. It must be unreachable.
        let plan = BoostPlan.make(permits: hardware.map { BoostPermit(fanIndex: $0.index, rpm: 0) },
                                  hardware: hardware, floorRPM: floor)
        for hw in hardware {
            XCTAssertGreaterThanOrEqual(plan?[hw.index] ?? 0, hw.minRPM)
            XCTAssertGreaterThan(plan?[hw.index] ?? 0, 0)
        }
    }

    func testTargetsNeverExceedTheFanMaximum() {
        let plan = BoostPlan.make(permits: [BoostPermit(fanIndex: 0, rpm: 99_000),
                                            BoostPermit(fanIndex: 1, rpm: 99_000)],
                                  hardware: hardware, floorRPM: floor)
        XCTAssertEqual(plan?[0], 6898)
        XCTAssertEqual(plan?[1], 7450)
    }

    func testFloorNeverDropsBelowAFansOwnMinimum() {
        // fan1 idles at 2,502 rpm, above the 2,500 floor; the fan's own minimum must win.
        let plan = BoostPlan.make(permits: [BoostPermit(fanIndex: 1, rpm: 100)],
                                  hardware: hardware, floorRPM: 2500)
        XCTAssertEqual(plan?[1], 2502)
    }

    func testDefaultFloorClearsApplesOwnPinnedSpeed() {
        // Measured: Apple holds 2,317 rpm from 80 °C all the way to 106 °C. A stuck boost at
        // the floor must not be slower than that.
        XCTAssertGreaterThan(BoostPlan.defaultFloorRPM, 2317)
    }
}

final class BoostGateTests: XCTestCase {

    private let floor = BoostPlan.defaultFloorRPM

    func testARequestBelowTheFloorIsNotWorthTakingControlFor() {
        // Found by running it: a curve asking ~1,000 rpm at 53 °C was rounded up to the floor,
        // so the machine ran at 2,500 rpm where macOS would have left the fans stopped.
        for requested in [0.0, 500, 1000, 2000, 2499] {
            XCTAssertFalse(BoostPlan.worthHolding(requestedRPM: requested, alreadyHolding: false),
                           "\(requested) rpm should be left to macOS")
        }
    }

    func testAtOrAboveTheFloorIsWorthHolding() {
        XCTAssertTrue(BoostPlan.worthHolding(requestedRPM: floor, alreadyHolding: false))
        XCTAssertTrue(BoostPlan.worthHolding(requestedRPM: 4000, alreadyHolding: false))
    }

    func testHysteresisStopsTheFansFlappingAtTheThreshold() {
        let justUnder = floor - 100
        XCTAssertFalse(BoostPlan.worthHolding(requestedRPM: justUnder, alreadyHolding: false),
                       "does not engage just under the floor")
        XCTAssertTrue(BoostPlan.worthHolding(requestedRPM: justUnder, alreadyHolding: true),
                      "but does not immediately let go either")
    }

    func testLetsGoOnceTheRequestFallsWellBelowTheFloor() {
        XCTAssertFalse(BoostPlan.worthHolding(requestedRPM: floor * 0.8, alreadyHolding: true))
    }
}

final class RequestedSpeedTests: XCTestCase {

    private let fan1 = FanHardware(index: 1, minRPM: 2502, maxRPM: 7450)

    /// Regression: the request was being raised to the fan's own minimum *before* the gate saw
    /// it. fan1 idles at 2,502 rpm, just over the 2,500 rpm floor, so every request — even
    /// 717 rpm at 53 °C — passed the gate and the fans never let go.
    func testARequestIsNotRaisedToTheFanMinimumBeforeTheGateSeesIt() {
        let requested = BoostPlan.requestedSpeed(rampedRPM: 717, maxRPM: fan1.maxRPM)
        XCTAssertEqual(requested, 717)
        XCTAssertFalse(BoostPlan.worthHolding(requestedRPM: requested, alreadyHolding: false))
        XCTAssertFalse(BoostPlan.worthHolding(requestedRPM: requested, alreadyHolding: true))
    }

    func testTheFanMinimumIsStillAppliedOnceControlIsTaken() {
        // The raise itself is not wrong, it just belongs after the decision.
        let plan = BoostPlan.make(permits: [BoostPermit(fanIndex: 1, rpm: 3000)],
                                  hardware: [fan1], floorRPM: BoostPlan.defaultFloorRPM)
        XCTAssertEqual(plan?[1], 3000)
        let lowPlan = BoostPlan.make(permits: [BoostPermit(fanIndex: 1, rpm: 2510)],
                                     hardware: [fan1], floorRPM: BoostPlan.defaultFloorRPM)
        XCTAssertEqual(lowPlan?[1], 2510, "already above the fan minimum")
    }

    func testUpperLimitIsStillEnforced() {
        XCTAssertEqual(BoostPlan.requestedSpeed(rampedRPM: 99_000, maxRPM: fan1.maxRPM), 7450)
    }

    func testNegativeRampNeverProducesANegativeRequest() {
        XCTAssertEqual(BoostPlan.requestedSpeed(rampedRPM: -500, maxRPM: fan1.maxRPM), 0)
    }

    /// The whole point: a cool machine must end up with macOS holding the fans.
    func testACoolMachineIsHandedBackToMacOS() {
        let requested = BoostPlan.requestedSpeed(rampedRPM: 717, maxRPM: fan1.maxRPM)
        let permits = BoostPlan.worthHolding(requestedRPM: requested, alreadyHolding: true)
            ? [BoostPermit(fanIndex: 1, rpm: requested)] : []
        XCTAssertNil(BoostPlan.make(permits: permits, hardware: [fan1],
                                    floorRPM: BoostPlan.defaultFloorRPM))
    }
}

final class CapTests: XCTestCase {

    private let maxRPM = 7450.0

    func testTheCapLimitsAnOtherwiseHigherRequest() {
        XCTAssertEqual(BoostPlan.applyCap(7000, cap: 5500, safetyFloorRPM: 0, maxRPM: maxRPM), 5500)
    }

    func testZeroCapMeansTheFansOwnMaximum() {
        XCTAssertEqual(BoostPlan.applyCap(9999, cap: 0, safetyFloorRPM: 0, maxRPM: maxRPM), maxRPM)
    }

    func testTheCapIsRespectedAtEverydayTemperatures() {
        // 95 °C is ordinary under load — stock sits at its minimum there — so the user's ceiling
        // must hold. Nothing about that temperature justifies overriding it.
        let floor = SafetyFloor.minimumRPM(tempC: 95, maxRPM: maxRPM)
        XCTAssertEqual(floor, 0, accuracy: 0.001)
        XCTAssertEqual(BoostPlan.applyCap(7000, cap: 5960, safetyFloorRPM: floor, maxRPM: maxRPM), 5960)
    }

    func testSafetyBeatsTheCapOnceStockItselfWouldRamp() {
        // Above 106 °C the firmware stops idling the fans. Past that point a low ceiling would
        // mean cooling worse than stock while stock cannot intervene, so the floor wins.
        let floor = SafetyFloor.minimumRPM(tempC: 112, maxRPM: maxRPM)
        XCTAssertGreaterThan(floor, 3000)
        XCTAssertEqual(BoostPlan.applyCap(4000, cap: 3000, safetyFloorRPM: floor, maxRPM: maxRPM), floor)
    }

    func testCapNeverExceedsTheFanMaximum() {
        XCTAssertEqual(BoostPlan.applyCap(9999, cap: 99_999, safetyFloorRPM: 0, maxRPM: maxRPM), maxRPM)
    }

    func testDefaultCapLeavesHeadroomTheStockControllerAlsoLeaves() {
        // Stock peaked at 5,006 of 6,898 rpm (73 %) at 117.6 °C; 80 % is above that and still
        // short of the rated maximum.
        let curve = FanCurve(index: 0, name: "t", maxRPM: 6898)
        XCTAssertEqual(curve.maxRPMCap, 5518)
        XCTAssertGreaterThan(curve.maxRPMCap, 5006)
        XCTAssertLessThan(curve.maxRPMCap, 6898)
    }
}

final class PresetShapeTests: XCTestCase {

    func testNoPresetExceptCoolingReachesTheRatedMaximum() {
        // Stock never used the top of the range even at 117.6 °C; neither should everyday presets.
        for preset in [CurvePreset.quiet, .balanced] {
            let peak = preset.points(maxRPM: 6898).map(\.rpm).max() ?? 0
            XCTAssertLessThan(peak, 6898, "\(preset) pins the fan at its rated maximum")
        }
    }

    func testEveryPresetStartsCoolerThanStockDoes() {
        // Stock does not move a fan until 80 °C. The whole point is to start before that.
        for preset in [CurvePreset.quiet, .balanced, .cooling] {
            let firstMoving = preset.points(maxRPM: 6898).sorted().first { $0.rpm > 0 }
            XCTAssertNotNil(firstMoving)
            XCTAssertLessThan(firstMoving!.tempC, 90, "\(preset) starts too late to help")
        }
    }
}

final class PreconditionTests: XCTestCase {

    private func reason(charging: Bool = true, onAC: Bool = true,
                        app: Bool = true, since: Double = 0) -> String? {
        BoostPreconditions.blockReason(requiresCharging: charging, onACPower: onAC,
                                       requiresApp: app, secondsSinceAppHeartbeat: since,
                                       heartbeatTimeout: 5)
    }

    func testAllowedWhenPluggedInAndTheAppIsAlive() {
        XCTAssertNil(reason())
    }

    func testBlockedOnBattery() {
        XCTAssertNotNil(reason(onAC: false))
    }

    func testBatteryIsIgnoredWhenTheOptionIsOff() {
        XCTAssertNil(reason(charging: false, onAC: false))
    }

    func testBlockedOnceTheAppStopsCheckingIn() {
        // The deadman: no heartbeat, no boost. Nothing has to run to "turn it off".
        XCTAssertNil(reason(since: 4))
        XCTAssertNotNil(reason(since: 6))
        XCTAssertNotNil(reason(since: .greatestFiniteMagnitude))
    }

    func testAppLivenessIsIgnoredWhenTheOptionIsOff() {
        XCTAssertNil(reason(app: false, since: .greatestFiniteMagnitude))
    }

    func testAFreshlyStartedDaemonWithNoAppIsBlocked() {
        // Distant-past heartbeat is the resting state, so a daemon that boots alone holds nothing.
        let since = Date().timeIntervalSince(.distantPast)
        XCTAssertNotNil(reason(since: since))
    }

    func testBatteryIsReportedBeforeAppLiveness() {
        // Both failing: the more actionable message wins.
        XCTAssertEqual(reason(onAC: false, since: 999), "バッテリー駆動中")
    }
}
