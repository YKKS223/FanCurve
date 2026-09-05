import XCTest
@testable import FanCurveKit

final class EmergencyDetectorTests: XCTestCase {

    private func detector() -> EmergencyDetector {
        var d = EmergencyDetector(thresholdC: 105)
        d.minimumHoldSeconds = 15
        return d
    }

    func testDoesNotFireOnASingleHotSample() {
        // Probes swing 15 °C in half a second; one sample over the line means nothing.
        var d = detector()
        XCTAssertFalse(d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8))
        XCTAssertFalse(d.update(smoothedMaxC: 100, sensorsAtOrAboveThreshold: 0))
        XCTAssertFalse(d.isEngaged)
    }

    func testFiresOnceTheTemperatureIsSustained() {
        var d = detector()
        for _ in 0..<2 { XCTAssertFalse(d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8)) }
        XCTAssertTrue(d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8))
    }

    func testOneGlitchedProbeCannotTriggerIt() {
        var d = detector()
        for _ in 0..<10 {
            XCTAssertFalse(d.update(smoothedMaxC: 120, sensorsAtOrAboveThreshold: 1))
        }
    }

    func testDoesNotReleaseTheInstantTheTemperatureDips() {
        // Regression: exit had no debounce, so it flapped every second or two.
        var d = detector()
        let start = Date()
        for i in 0..<3 { d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8,
                                  now: start.addingTimeInterval(Double(i))) }
        XCTAssertTrue(d.isEngaged)
        // One sample just under the threshold must not release it.
        d.update(smoothedMaxC: 104, sensorsAtOrAboveThreshold: 0, now: start.addingTimeInterval(4))
        XCTAssertTrue(d.isEngaged)
    }

    func testHoldsForAMinimumTimeEvenWhenCold() {
        var d = detector()
        let start = Date()
        for i in 0..<3 { d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8,
                                  now: start.addingTimeInterval(Double(i))) }
        XCTAssertTrue(d.isEngaged)
        for i in 3..<12 {
            d.update(smoothedMaxC: 70, sensorsAtOrAboveThreshold: 0, now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertTrue(d.isEngaged, "released before the minimum hold elapsed")
        d.update(smoothedMaxC: 70, sensorsAtOrAboveThreshold: 0, now: start.addingTimeInterval(20))
        XCTAssertFalse(d.isEngaged)
    }

    func testReleasesOnlyAfterFallingBelowTheMargin() {
        var d = detector()
        let start = Date()
        for i in 0..<3 { d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8,
                                  now: start.addingTimeInterval(Double(i))) }
        // 102 °C is under the threshold but inside the 5 °C release margin.
        for i in 3..<30 {
            d.update(smoothedMaxC: 102, sensorsAtOrAboveThreshold: 0, now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertTrue(d.isEngaged, "released while still within the margin")
        for i in 30..<34 {
            d.update(smoothedMaxC: 99, sensorsAtOrAboveThreshold: 0, now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(d.isEngaged)
    }

    func testResetDropsItImmediately() {
        var d = detector()
        let start = Date()
        for i in 0..<3 { d.update(smoothedMaxC: 110, sensorsAtOrAboveThreshold: 8,
                                  now: start.addingTimeInterval(Double(i))) }
        XCTAssertTrue(d.isEngaged)
        d.reset()
        XCTAssertFalse(d.isEngaged, "handing the fans to macOS must clear it at once")
    }

    func testASessionOfRealisticSpikesEngagesOnceRatherThan35Times() {
        // The session that prompted this: temperature hovering around the threshold.
        var d = detector()
        var transitions = 0
        var previous = false
        let start = Date()
        for i in 0..<300 {
            let temp = 106.0 + (i % 7 == 0 ? -4.0 : 1.0)   // wobbling around the line
            d.update(smoothedMaxC: temp, sensorsAtOrAboveThreshold: 6,
                     now: start.addingTimeInterval(Double(i)))
            if d.isEngaged != previous { transitions += 1; previous = d.isEngaged }
        }
        XCTAssertLessThanOrEqual(transitions, 2, "still flapping (\(transitions) 回)")
    }
}
