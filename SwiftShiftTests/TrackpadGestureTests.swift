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
}
