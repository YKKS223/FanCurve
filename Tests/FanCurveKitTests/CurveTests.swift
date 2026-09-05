import XCTest
@testable import FanCurveKit

final class CurveTests: XCTestCase {

    private func curve(_ points: [(Double, Double)], zeroIsSystem: Bool = true) -> FanCurve {
        var c = FanCurve(index: 0, name: "test", maxRPM: 6898)
        c.points = points.map { CurvePoint(tempC: $0.0, rpm: $0.1) }
        c.zeroMeansSystem = zeroIsSystem
        return c
    }

    func testInterpolatesBetweenPoints() {
        let c = curve([(50, 0), (70, 2000), (90, 6000)])
        XCTAssertEqual(c.rpm(at: 60)!, 1000, accuracy: 0.001)
        XCTAssertEqual(c.rpm(at: 80)!, 4000, accuracy: 0.001)
        XCTAssertEqual(c.rpm(at: 70)!, 2000, accuracy: 0.001)
    }

    func testClampsOutsideTheDefinedRange() {
        let c = curve([(50, 1000), (90, 6000)])
        XCTAssertEqual(c.rpm(at: 10)!, 1000, accuracy: 0.001, "below the first point holds the first value")
        XCTAssertEqual(c.rpm(at: 120)!, 6000, accuracy: 0.001, "above the last point holds the last value")
    }

    func testZeroHandsControlBackToTheSystem() {
        let c = curve([(50, 0), (70, 3000)])
        XCTAssertNil(c.rpm(at: 40), "0 rpm means 'let the Mac decide', not 'stop the fan'")
        XCTAssertNotNil(c.rpm(at: 60))
    }

    func testZeroStopsTheFanWhenTheFlagIsOff() {
        let c = curve([(50, 0), (70, 3000)], zeroIsSystem: false)
        XCTAssertEqual(c.rpm(at: 40)!, 0, accuracy: 0.001)
    }

    func testUnsortedPointsAreStillEvaluatedInOrder() {
        let c = curve([(90, 6000), (50, 1000), (70, 2000)])
        XCTAssertEqual(c.rpm(at: 60)!, 1500, accuracy: 0.001)
    }

    func testPresetsStayWithinTheFanRange() {
        for preset in CurvePreset.allCases {
            let pts = preset.points(maxRPM: 6898)
            XCTAssertFalse(pts.isEmpty)
            XCTAssertTrue(pts.allSatisfy { $0.rpm >= 0 && $0.rpm <= 6898 }, "\(preset) exceeds the fan maximum")
            XCTAssertEqual(pts, pts.sorted(), "\(preset) must be ordered by temperature")
        }
    }

    func testQuietPresetIsNeverLouderThanCooling() {
        let quiet = curve(CurvePreset.quiet.points(maxRPM: 6898).map { ($0.tempC, $0.rpm) }, zeroIsSystem: false)
        let cooling = curve(CurvePreset.cooling.points(maxRPM: 6898).map { ($0.tempC, $0.rpm) }, zeroIsSystem: false)
        for t in stride(from: 30.0, through: 95.0, by: 5) {
            XCTAssertLessThanOrEqual(quiet.rpm(at: t)!, cooling.rpm(at: t)! + 0.001, "at \(t) °C")
        }
    }
}

final class ConfigTests: XCTestCase {

    func testRoundTripsThroughJSON() throws {
        var cfg = AppConfig.makeDefault(hardware: [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898),
                                                  FanHardware(index: 1, minRPM: 2502, maxRPM: 7450)])
        cfg.mode = .curve
        cfg.fans[0].source = .group(.gpu)
        cfg.fans[1].source = .key("Tp0T")
        let data = try cfg.encoded()
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(cfg, back)
    }

    func testReconcileAddsMissingFansAndClampsToHardware() {
        var cfg = AppConfig.makeDefault(hardware: [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898)])
        cfg.fans[0].points = [CurvePoint(tempC: 50, rpm: 0), CurvePoint(tempC: 90, rpm: 99_000)]

        cfg.reconcile(hardware: [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898),
                                 FanHardware(index: 1, minRPM: 2502, maxRPM: 7450)])

        XCTAssertEqual(cfg.fans.count, 2, "a fan the stored config never saw gets a default curve")
        XCTAssertEqual(cfg.fans[0].points.last!.rpm, 6898, "points above the fan maximum are clamped")
    }

    /// Regression: the first build wrote `F%dMd` on nothing but an optimistic default.
    /// On an M3 Max that write sticks and cannot be undone, so an unconfirmed `true` in a
    /// stored config must never re-enable it.
    func testStoredModeKeyFlagIsIgnoredUntilAProbeConfirmsIt() throws {
        let legacy = """
        { "mode": "curve", "fans": [], "updateIntervalMs": 1000,
          "emergencyTempC": 95, "requiresModeKey": true }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: legacy)
        XCTAssertFalse(cfg.modeKeyConfirmed)
        XCTAssertFalse(cfg.requiresModeKey, "an unconfirmed mode-key flag must not survive a load")
    }

    func testConfirmedModeKeyFlagIsHonoured() throws {
        let confirmed = """
        { "mode": "curve", "fans": [], "updateIntervalMs": 1000, "emergencyTempC": 95,
          "requiresModeKey": true, "modeKeyConfirmed": true }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: confirmed)
        XCTAssertTrue(cfg.requiresModeKey)
    }

    func testDefaultConfigNeverWritesTheModeKey() {
        let cfg = AppConfig.makeDefault(hardware: [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898)])
        XCTAssertFalse(cfg.requiresModeKey)
        XCTAssertFalse(cfg.modeKeyConfirmed)
    }

    func testReconcileDropsFansThatNoLongerExist() {
        var cfg = AppConfig.makeDefault(hardware: [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898),
                                                  FanHardware(index: 1, minRPM: 2502, maxRPM: 7450)])
        cfg.reconcile(hardware: [FanHardware(index: 0, minRPM: 2317, maxRPM: 6898)])
        XCTAssertEqual(cfg.fans.map(\.index), [0])
    }
}

final class SensorSourceTests: XCTestCase {

    private let readings = [
        SensorReading(key: "Tp0T", name: "CPU", group: .cpu, value: 70),
        SensorReading(key: "Tp1T", name: "CPU", group: .cpu, value: 82),
        SensorReading(key: "Tg01", name: "GPU", group: .gpu, value: 65),
        SensorReading(key: "TB0T", name: "電池", group: .battery, value: 95),
        SensorReading(key: "Ts0P", name: "筐体", group: .ambient, value: 91),
    ]

    func testGroupMaxPicksTheHottestProbeInThatGroup() {
        XCTAssertEqual(SensorSource.group(.cpu).value(in: readings), 82)
        XCTAssertEqual(SensorSource.group(.gpu).value(in: readings), 65)
    }

    func testSystemMaxIgnoresBatteryAndEnclosure() {
        // A hot battery or a warm palm rest must not drive the fans; only silicon does.
        XCTAssertEqual(SensorSource.systemMax.value(in: readings), 82)
    }

    func testSingleKeyLookup() {
        XCTAssertEqual(SensorSource.key("Tg01").value(in: readings), 65)
        XCTAssertNil(SensorSource.key("nope").value(in: readings))
    }

    func testAppleSiliconKeysAreClassified() {
        XCTAssertEqual(SensorCatalog.group(for: "Tp0T"), .cpu)
        XCTAssertEqual(SensorCatalog.group(for: "Te05"), .cpu)
        XCTAssertEqual(SensorCatalog.group(for: "Tg01"), .gpu)
        XCTAssertEqual(SensorCatalog.group(for: "TB0T"), .battery)
        XCTAssertEqual(SensorCatalog.group(for: "Th06"), .ssd)
        XCTAssertEqual(SensorCatalog.group(for: "Ts0P"), .ambient)
    }

    func testSourceCodableRoundTrip() throws {
        for source in [SensorSource.systemMax, .group(.ssd), .key("TCMz")] {
            let data = try JSONEncoder().encode(source)
            XCTAssertEqual(try JSONDecoder().decode(SensorSource.self, from: data), source)
        }
    }
}


final class SafetyFloorTests: XCTestCase {

    private let maxRPM = 7450.0
    /// Measured stock behaviour on this machine, used as the bar the floor must not fall under.
    private let stockPinnedRPM = 2502.0      // 80–106 °C
    private let stockPeakFraction = 0.73     // at 117.6 °C

    func testNoFloorAcrossTheBandWhereStockSitsAtItsMinimum() {
        // Up to 100 °C the flat 2,500 rpm boost floor already exceeds the 2,317–2,502 rpm the
        // firmware pins, so this floor must not add anything and must not override the user's cap.
        for t in stride(from: 20.0, through: 100.0, by: 2) {
            XCTAssertEqual(SafetyFloor.minimumRPM(tempC: t, maxRPM: maxRPM), 0, accuracy: 0.001,
                           "the floor must stay out of the way at \(t) °C")
        }
    }

    func testTheUsersCeilingSurvivesEverydayTemperatures() {
        // Regression: the floor used to demand 6,854 rpm at 95 °C, overriding a 5,960 rpm cap.
        let cap = 5960.0
        for t in [90.0, 95.0, 97.0, 100.0] {
            let floor = SafetyFloor.minimumRPM(tempC: t, maxRPM: maxRPM)
            XCTAssertLessThanOrEqual(floor, cap, "at \(t) °C the floor overrode the user's cap")
        }
    }

    func testNeverFallsBelowWhatStockWouldDoOnceStockStartsRamping() {
        // Above 106 °C stock ramps; the floor has to keep pace or holding control is a downgrade.
        XCTAssertGreaterThanOrEqual(SafetyFloor.minimumRPM(tempC: 106, maxRPM: maxRPM), stockPinnedRPM)
        XCTAssertGreaterThanOrEqual(SafetyFloor.minimumRPM(tempC: 117, maxRPM: maxRPM),
                                    maxRPM * stockPeakFraction)
    }

    func testFloorRisesMonotonicallyWithTemperature() {
        var previous = -1.0
        for t in stride(from: 90.0, through: 125.0, by: 0.5) {
            let v = SafetyFloor.minimumRPM(tempC: t, maxRPM: maxRPM)
            XCTAssertGreaterThanOrEqual(v, previous, "floor dipped at \(t) °C")
            previous = v
        }
    }

    func testFloorReachesFullSpeedBeyondAnythingObserved() {
        XCTAssertEqual(SafetyFloor.minimumRPM(tempC: 120, maxRPM: maxRPM), maxRPM, accuracy: 0.001)
        XCTAssertEqual(SafetyFloor.minimumRPM(tempC: 130, maxRPM: maxRPM), maxRPM, accuracy: 0.001)
    }

    func testASilentCurveStillCannotUnderCoolAHotMachine() {
        var quietest = FanCurve(index: 0, name: "t", maxRPM: maxRPM)
        quietest.points = [CurvePoint(tempC: 20, rpm: 2502), CurvePoint(tempC: 125, rpm: 2502)]
        quietest.zeroMeansSystem = false
        for temp in [110.0, 117.0] {
            let drawn = quietest.rpm(at: temp)!
            let enforced = max(drawn, SafetyFloor.minimumRPM(tempC: temp, maxRPM: maxRPM))
            XCTAssertGreaterThan(enforced, drawn, "at \(temp) °C the floor must override the curve")
        }
    }

    func testFloorIsProportionalToTheFansOwnMaximum() {
        XCTAssertEqual(SafetyFloor.minimumRPM(tempC: 112, maxRPM: 6898), 6898 * 0.55, accuracy: 0.001)
        XCTAssertEqual(SafetyFloor.minimumRPM(tempC: 112, maxRPM: 7450), 7450 * 0.55, accuracy: 0.001)
    }

    func testHandlesNonsenseInput() {
        XCTAssertEqual(SafetyFloor.minimumRPM(tempC: .nan, maxRPM: maxRPM), 0)
        XCTAssertEqual(SafetyFloor.minimumRPM(tempC: 90, maxRPM: 0), 0)
    }
}

final class ConfigMigrationTests: XCTestCase {

    /// A curve saved before `maxRPMCap` existed must still load, keeping the user's points.
    func testOlderCurveJSONStillLoads() throws {
        let legacy = """
        { "index": 0, "name": "ファン 左", "enabled": true,
          "source": {"kind":"systemMax"},
          "points": [{"tempC":60,"rpm":0},{"tempC":90,"rpm":5000}],
          "hysteresisC": 2, "smoothingSeconds": 4,
          "rampUpRPMPerSec": 600, "rampDownRPMPerSec": 250,
          "zeroMeansSystem": true, "manualRPM": 0 }
        """.data(using: .utf8)!
        let curve = try JSONDecoder().decode(FanCurve.self, from: legacy)
        XCTAssertEqual(curve.points.count, 2)
        XCTAssertEqual(curve.maxRPMCap, 0, "no cap recorded means the fan's own maximum")
        XCTAssertEqual(curve.rpm(at: 90)!, 5000, accuracy: 0.001)
    }
}

final class StockBaselineTests: XCTestCase {

    private let fan0max = 6898.0

    func testFansAreStoppedBelowEighty() {
        for t in [20.0, 50, 70, 79] {
            XCTAssertEqual(StockBaseline.rpm(tempC: t, maxRPM: fan0max), 0, accuracy: 0.001)
        }
    }

    func testPinnedAtTheMinimumAcrossTheWholeMiddleBand() {
        // The measured fact the whole project exists because of: 80 °C to 106 °C, no change.
        let at80 = StockBaseline.rpm(tempC: 80, maxRPM: fan0max)
        let at106 = StockBaseline.rpm(tempC: 106, maxRPM: fan0max)
        XCTAssertEqual(at80, at106, accuracy: 1.0)
        XCTAssertEqual(at80, 2317, accuracy: 15, "should match the fan's own minimum")
    }

    func testPeaksWellShortOfTheRatedMaximum() {
        let peak = StockBaseline.rpm(tempC: 117.6, maxRPM: fan0max)
        XCTAssertEqual(peak, 5035, accuracy: 40)
        XCTAssertLessThan(peak, fan0max * 0.75)
    }

    func testEveryPresetBeatsStockWhereItMatters() {
        // If a preset were not above stock at 95 °C, running it would be pointless.
        for preset in [CurvePreset.quiet, .balanced, .cooling] {
            var curve = FanCurve(index: 0, name: "t", maxRPM: fan0max)
            curve.points = preset.points(maxRPM: fan0max)
            curve.zeroMeansSystem = false
            let ours = curve.rpm(at: 95)!
            XCTAssertGreaterThan(ours, StockBaseline.rpm(tempC: 95, maxRPM: fan0max),
                                 "\(preset) is no better than stock at 95 °C")
        }
    }
}
