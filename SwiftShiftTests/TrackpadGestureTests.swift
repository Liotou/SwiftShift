import XCTest
import AppKit
@testable import Swift_Shift_Dev

final class TrackpadGestureTests: XCTestCase {

    /// Fingers 0, 1, 2… at the given normalized trackpad positions.
    private func fingers(_ points: [(x: CGFloat, y: CGFloat)]) -> [TrackpadTouch] {
        points.enumerated().map { index, point in
            TrackpadTouch(id: NSNumber(value: index), position: CGPoint(x: point.x, y: point.y))
        }
    }

    private func threeFingers(y: CGFloat, dx: CGFloat = 0) -> [TrackpadTouch] {
        fingers([(0.3 + dx, y), (0.5 + dx, y), (0.7 + dx, y)])
    }

    private func twoFingers(dx: CGFloat = 0, dy: CGFloat = 0) -> [TrackpadTouch] {
        fingers([(0.4 + dx, 0.5 + dy), (0.6 + dx, 0.5 + dy)])
    }

    private func assertMoved(_ event: TwoFingerHoldRecognizer.Event?, dx: CGFloat, dy: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .moved(let actualDX, let actualDY)? = event else {
            return XCTFail("expected a .moved event, got \(String(describing: event))", file: file, line: line)
        }
        XCTAssertEqual(actualDX, dx, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualDY, dy, accuracy: 0.0001, file: file, line: line)
    }

    // MARK: - Three-finger swipe down

    func testSwipe_firstEventOnlyEstablishesTheBaseline() {
        let swipe = ThreeFingerSwipeRecognizer()
        let update = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)

        XCTAssertEqual(update, .init(fingers: 3, progress: 0, triggered: false))
    }

    func testSwipe_triggersOnceTheFingersHaveTravelledFarEnough() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)

        let update = swipe.update(touches: threeFingers(y: 0.4), now: 0.1, threshold: 0.12)

        XCTAssertTrue(update.triggered)
        XCTAssertEqual(update.progress, 1)
    }

    func testSwipe_reportsProgressTowardsTheThreshold() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)

        let update = swipe.update(touches: threeFingers(y: 0.54), now: 0.1, threshold: 0.12)

        XCTAssertFalse(update.triggered)
        XCTAssertEqual(update.progress, 0.5, accuracy: 0.001)
    }

    func testSwipe_doesNotTriggerAgainWhileTheFingersStayDown() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)
        XCTAssertTrue(swipe.update(touches: threeFingers(y: 0.4), now: 0.1, threshold: 0.12).triggered)

        XCTAssertFalse(swipe.update(touches: threeFingers(y: 0.2), now: 1.0, threshold: 0.12).triggered)
    }

    func testSwipe_mostlyHorizontalMovementDoesNotTrigger() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)

        // 0.15 down but 0.3 across: a sideways swipe, not a downward one.
        let update = swipe.update(touches: threeFingers(y: 0.45, dx: 0.3), now: 0.1, threshold: 0.12)

        XCTAssertFalse(update.triggered)
    }

    func testSwipe_upwardMovementNeverTriggers() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.4), now: 0, threshold: 0.12)

        let update = swipe.update(touches: threeFingers(y: 0.8), now: 0.1, threshold: 0.12)

        XCTAssertFalse(update.triggered)
        XCTAssertEqual(update.progress, 0)
    }

    func testSwipe_liftingAFingerRearmsIt() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)
        XCTAssertTrue(swipe.update(touches: threeFingers(y: 0.4), now: 0.1, threshold: 0.12).triggered)

        _ = swipe.update(touches: twoFingers(), now: 1.0, threshold: 0.12)
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 1.1, threshold: 0.12)
        let update = swipe.update(touches: threeFingers(y: 0.4), now: 1.2, threshold: 0.12)

        XCTAssertTrue(update.triggered)
    }

    func testSwipe_repeatsWithinTheDebounceWindowAreIgnored() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0.12)
        XCTAssertTrue(swipe.update(touches: threeFingers(y: 0.4), now: 0.1, threshold: 0.12).triggered)

        _ = swipe.update(touches: [], now: 0.15, threshold: 0.12)
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0.2, threshold: 0.12)
        let update = swipe.update(touches: threeFingers(y: 0.4), now: 0.3, threshold: 0.12)

        XCTAssertFalse(update.triggered)
    }

    func testSwipe_thresholdHasAFloor() {
        let swipe = ThreeFingerSwipeRecognizer()
        _ = swipe.update(touches: threeFingers(y: 0.6), now: 0, threshold: 0)

        // A zero threshold would fire on tremor; it is floored at 0.02.
        XCTAssertFalse(swipe.update(touches: threeFingers(y: 0.595), now: 0.1, threshold: 0).triggered)
        XCTAssertTrue(swipe.update(touches: threeFingers(y: 0.575), now: 0.2, threshold: 0).triggered)
    }

    // MARK: - Two-finger hold, then drag

    func testHold_beginsAfterAStillHold() {
        let hold = TwoFingerHoldRecognizer()

        XCTAssertEqual(hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45), [])
        XCTAssertEqual(hold.phase, .resting)
        XCTAssertEqual(hold.tick(now: 0.3, holdDuration: 0.45), [], "too early")
        XCTAssertEqual(hold.tick(now: 0.46, holdDuration: 0.45), [.began])
        XCTAssertEqual(hold.phase, .grabbing)
    }

    func testHold_smallTremorDuringTheHoldStillCounts() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)

        _ = hold.update(touches: twoFingers(dx: 0.01, dy: -0.01), now: 0.2, holdDuration: 0.45)

        XCTAssertEqual(hold.phase, .resting)
        XCTAssertEqual(hold.tick(now: 0.5, holdDuration: 0.45), [.began])
    }

    func testHold_movementIsReportedRelativeToWhereTheGrabBegan() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)
        _ = hold.tick(now: 0.5, holdDuration: 0.45)

        let events = hold.update(touches: twoFingers(dx: 0.1, dy: -0.05), now: 0.6, holdDuration: 0.45)

        XCTAssertEqual(events.count, 1)
        assertMoved(events.first, dx: 0.1, dy: -0.05)
    }

    func testHold_firstMovementAfterAStillHoldGrabsFromWhereTheFingersRested() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)

        // No tick ran (a late timer): the first event after the hold is already a movement.
        let events = hold.update(touches: twoFingers(dx: 0.1), now: 0.6, holdDuration: 0.45)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .began)
        assertMoved(events.last, dx: 0.1, dy: 0)
    }

    func testHold_movingBeforeTheHoldElapsedIsAScrollAndNeverGrabs() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)

        XCTAssertEqual(hold.update(touches: twoFingers(dy: 0.1), now: 0.1, holdDuration: 0.45), [])
        XCTAssertEqual(hold.phase, .rejected)

        // Lingering afterwards must not turn the scroll into a grab.
        XCTAssertEqual(hold.update(touches: twoFingers(dy: 0.1), now: 2.0, holdDuration: 0.45), [])
        XCTAssertEqual(hold.tick(now: 2.1, holdDuration: 0.45), [])
        XCTAssertEqual(hold.phase, .rejected)
    }

    func testHold_liftingTheFingersEndsTheGrabAndRearms() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)
        _ = hold.tick(now: 0.5, holdDuration: 0.45)

        XCTAssertEqual(hold.update(touches: fingers([(0.5, 0.5)]), now: 0.7, holdDuration: 0.45), [.ended])
        XCTAssertEqual(hold.phase, .idle)

        _ = hold.update(touches: twoFingers(), now: 1.0, holdDuration: 0.45)
        XCTAssertEqual(hold.phase, .resting)
    }

    func testHold_aThirdFingerEndsTheGrab() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)
        _ = hold.tick(now: 0.5, holdDuration: 0.45)

        let events = hold.update(touches: fingers([(0.3, 0.5), (0.5, 0.5), (0.7, 0.5)]), now: 0.6, holdDuration: 0.45)

        XCTAssertEqual(events, [.ended])
    }

    func testHold_swappingAFingerRestartsTheHold() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)

        let swapped = [
            TrackpadTouch(id: NSNumber(value: 0), position: CGPoint(x: 0.4, y: 0.5)),
            TrackpadTouch(id: NSNumber(value: 9), position: CGPoint(x: 0.6, y: 0.5))
        ]
        _ = hold.update(touches: swapped, now: 0.4, holdDuration: 0.45)

        XCTAssertEqual(hold.restStart, 0.4)
        XCTAssertEqual(hold.tick(now: 0.5, holdDuration: 0.45), [], "the hold restarted at 0.4")
        XCTAssertEqual(hold.tick(now: 0.86, holdDuration: 0.45), [.began])
    }

    func testHold_aRejectedGrabIsIgnoredUntilTheFingersLift() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)
        _ = hold.tick(now: 0.5, holdDuration: 0.45)

        hold.reject()

        XCTAssertEqual(hold.update(touches: twoFingers(dx: 0.2), now: 0.6, holdDuration: 0.45), [])
        XCTAssertEqual(hold.phase, .rejected)
        XCTAssertEqual(hold.update(touches: [], now: 0.7, holdDuration: 0.45), [])
        XCTAssertEqual(hold.phase, .idle)
    }

    func testHold_resetEndsAGrabInProgress() {
        let hold = TwoFingerHoldRecognizer()
        _ = hold.update(touches: twoFingers(), now: 0, holdDuration: 0.45)
        _ = hold.tick(now: 0.5, holdDuration: 0.45)

        XCTAssertEqual(hold.reset(), [.ended])
        XCTAssertEqual(hold.reset(), [])
    }
}
