import XCTest
@testable import Swift_Shift_Dev

final class StrokeLogicTests: XCTestCase {

    // AX (top-left) coordinates: a 1440x900 screen with a 25 pt menu bar and a 25 pt Dock.
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let free = CGRect(x: 100, y: 100, width: 600, height: 400)

    // MARK: - Finger direction

    func testFingerDelta_naturalScrolling() {
        XCTAssertEqual(StrokeLogic.fingerDelta(scrollingDeltaX: 0, scrollingDeltaY: 10, invertedFromDevice: true), FingerDelta(right: 0, down: 10))
    }

    func testFingerDelta_classicScrolling() {
        XCTAssertEqual(StrokeLogic.fingerDelta(scrollingDeltaX: -10, scrollingDeltaY: -10, invertedFromDevice: false), FingerDelta(right: 10, down: 10))
    }

    // MARK: - Recogniser

    func testRecognizer_firesOnceAtThreshold() {
        var r = StrokeRecognizer()
        XCTAssertNil(r.add(FingerDelta(right: 0, down: 15)))
        XCTAssertNil(r.add(FingerDelta(right: 0, down: 15)))
        XCTAssertEqual(r.add(FingerDelta(right: 0, down: 15)), .down)
        XCTAssertNil(r.add(FingerDelta(right: 0, down: 50)))
    }

    func testRecognizer_diagonalDoesNotFire() {
        var r = StrokeRecognizer()
        XCTAssertNil(r.add(FingerDelta(right: 30, down: 30)))
        XCTAssertNil(r.add(FingerDelta(right: 30, down: 30)))
    }

    func testRecognizer_left() {
        var r = StrokeRecognizer()
        XCTAssertEqual(r.add(FingerDelta(right: -41, down: 5)), .left)
    }

    // MARK: - Geometry

    func testAxRect_flipsAgainstPrimaryScreen() {
        XCTAssertEqual(StrokeLogic.axRect(fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875), primaryScreenHeight: 900), CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    func testFrames_halvesAndMaximise() {
        XCTAssertEqual(StrokeLogic.frame(for: .maximise, in: visible), visible)
        XCTAssertEqual(StrokeLogic.frame(for: .leftHalf, in: visible), CGRect(x: 0, y: 25, width: 720, height: 850))
        XCTAssertEqual(StrokeLogic.frame(for: .rightHalf, in: visible), CGRect(x: 720, y: 25, width: 720, height: 850))
    }

    func testFramesMatch_tolerance() {
        XCTAssertTrue(StrokeLogic.framesMatch(free, free.insetBy(dx: 1, dy: 1)))
        XCTAssertFalse(StrokeLogic.framesMatch(free, free.offsetBy(dx: 10, dy: 0)))
    }

    // MARK: - Decision

    func testDecision_snapRecordsPreSnapFrame() {
        let (a, rec) = StrokeLogic.windowAction(direction: .up, current: free, visible: visible, record: nil)
        XCTAssertEqual(a, .snap(visible))
        XCTAssertEqual(rec, SnapRecord(preSnap: free, snapped: visible))
    }

    func testDecision_chainedSnapKeepsOriginalPreSnap() {
        let left = StrokeLogic.frame(for: .leftHalf, in: visible)
        let (a, rec) = StrokeLogic.windowAction(direction: .up, current: left, visible: visible, record: SnapRecord(preSnap: free, snapped: left))
        XCTAssertEqual(a, .snap(visible))
        XCTAssertEqual(rec?.preSnap, free)
    }

    func testDecision_downOnSnappedRestores() {
        let (a, rec) = StrokeLogic.windowAction(direction: .down, current: visible, visible: visible, record: SnapRecord(preSnap: free, snapped: visible))
        XCTAssertEqual(a, .restore(free))
        XCTAssertNil(rec)
    }

    func testDecision_downOnUnsnappedMinimises() {
        XCTAssertEqual(StrokeLogic.windowAction(direction: .down, current: free, visible: visible, record: nil).action, .minimise)
    }

    func testDecision_movedByHandCountsAsUnsnapped() {
        let moved = visible.offsetBy(dx: 50, dy: 0)
        let (a, rec) = StrokeLogic.windowAction(direction: .down, current: moved, visible: visible, record: SnapRecord(preSnap: free, snapped: visible))
        XCTAssertEqual(a, .minimise)
        XCTAssertNil(rec)
    }

    func testDecision_restoreUsesRecordedSnappedFrame() {
        let wideLeft = CGRect(x: 0, y: 25, width: 800, height: 850) // app enforced a minimum width
        let a = StrokeLogic.windowAction(direction: .down, current: wideLeft, visible: visible, record: SnapRecord(preSnap: free, snapped: wideLeft)).action
        XCTAssertEqual(a, .restore(free))
    }

    func testDecision_upOnMaximisedIsNoop() {
        XCTAssertEqual(StrokeLogic.windowAction(direction: .up, current: visible, visible: visible, record: nil).action, StrokeAction.none)
    }

    func testDecision_leftOnLeftHalfIsNoop() {
        let left = StrokeLogic.frame(for: .leftHalf, in: visible)
        XCTAssertEqual(StrokeLogic.windowAction(direction: .left, current: left, visible: visible, record: nil).action, StrokeAction.none)
    }
}
