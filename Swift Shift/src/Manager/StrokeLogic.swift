import CoreGraphics

// Pure logic for swipe strokes: no AX, no event tap, so it is unit-testable.
// All rects are in AX (top-left origin, primary screen) coordinates unless named otherwise.

enum StrokeDirection: Equatable { case up, down, left, right }

/// Scroll movement expressed as finger movement: positive `right` = fingers moved right,
/// positive `down` = fingers moved down, whatever the natural-scrolling setting.
struct FingerDelta: Equatable {
    var right: CGFloat
    var down: CGFloat
}

/// Accumulates one gesture's finger movement and fires once, when it passes `threshold`
/// on one axis and that axis is at least `dominance` times the other (diagonals never fire).
struct StrokeRecognizer {
    private let threshold: CGFloat
    private let dominance: CGFloat
    private var total = FingerDelta(right: 0, down: 0)
    private var hasFired = false

    init(threshold: CGFloat = 40, dominance: CGFloat = 2) {
        self.threshold = threshold
        self.dominance = dominance
    }

    mutating func add(_ d: FingerDelta) -> StrokeDirection? {
        guard !hasFired else { return nil }
        total.right += d.right
        total.down += d.down
        let h = abs(total.right), v = abs(total.down)
        guard max(h, v) >= threshold else { return nil }
        let direction: StrokeDirection
        if h >= v * dominance {
            direction = total.right > 0 ? .right : .left
        } else if v >= h * dominance {
            direction = total.down > 0 ? .down : .up
        } else {
            return nil
        }
        hasFired = true
        return direction
    }
}

enum SnapTarget { case maximise, leftHalf, rightHalf }

struct SnapRecord: Equatable {
    var preSnap: CGRect
    var snapped: CGRect
}

enum StrokeAction: Equatable {
    case none
    case snap(CGRect)
    case restore(CGRect)
    case minimise
}

enum StrokeLogic {
    /// With natural scrolling the content follows the fingers, so the deltas already point
    /// the way the fingers moved; with classic scrolling they point the opposite way.
    static func fingerDelta(scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat, invertedFromDevice: Bool) -> FingerDelta {
        let sign: CGFloat = invertedFromDevice ? 1 : -1
        return FingerDelta(right: sign * scrollingDeltaX, down: sign * scrollingDeltaY)
    }

    static func axRect(fromAppKit r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    static func frame(for target: SnapTarget, in visible: CGRect) -> CGRect {
        let half = visible.width / 2
        switch target {
        case .maximise: return visible
        case .leftHalf: return CGRect(x: visible.minX, y: visible.minY, width: half, height: visible.height)
        case .rightHalf: return CGRect(x: visible.minX + half, y: visible.minY, width: half, height: visible.height)
        }
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// A record counts only while the window still sits at its snapped frame; moved or
    /// resized by hand means unsnapped. Down restores a snapped window and minimises any
    /// other; chained snaps keep the frame from before the first snap.
    static func windowAction(direction: StrokeDirection, current: CGRect, visible: CGRect, record: SnapRecord?) -> (action: StrokeAction, record: SnapRecord?) {
        let live = record.flatMap { framesMatch(current, $0.snapped) ? $0 : nil }
        let target: SnapTarget
        switch direction {
        case .down:
            if let live { return (.restore(live.preSnap), nil) }
            return (.minimise, nil)
        case .up: target = .maximise
        case .left: target = .leftHalf
        case .right: target = .rightHalf
        }
        let targetFrame = frame(for: target, in: visible)
        if framesMatch(current, targetFrame) { return (.none, live) }
        return (.snap(targetFrame), SnapRecord(preSnap: live?.preSnap ?? current, snapped: targetFrame))
    }
}
