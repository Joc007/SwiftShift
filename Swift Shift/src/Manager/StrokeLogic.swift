import AppKit

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

enum ScrollPhase { case none, mayBegin, began, changed, ended, cancelled }

enum MomentumPhase { case none, began, changed, ended }

struct ScrollSample {
    var isContinuous: Bool
    var phase: ScrollPhase
    var momentum: MomentumPhase
    var delta: FingerDelta
}

/// Where a gesture started: a window (title bar, or anywhere with the Move modifier held),
/// an app's Dock icon, or nowhere strokes apply.
enum StrokeZone: Equatable {
    case none
    case window(id: CGWindowID, pid: pid_t, frame: CGRect)
    case dockIcon(appURL: URL)
}

/// Follows one trackpad scroll gesture at a time. The zone is looked up once, when the
/// fingers start moving; every event of an in-zone gesture, including the momentum after
/// the fingers lift, is swallowed so the content underneath does not scroll as well.
/// Anything outside a zone, and any non-continuous (mouse wheel) event, passes through.
struct StrokeGestureTracker {
    private(set) var isInGesture = false
    private var zone: StrokeZone = .none
    private var recognizer = StrokeRecognizer()

    mutating func handle(_ s: ScrollSample, zoneAtBegin: () -> StrokeZone) -> (swallow: Bool, fired: (zone: StrokeZone, direction: StrokeDirection)?) {
        guard s.isContinuous else { return (false, nil) }
        switch s.phase {
        case .began:
            zone = zoneAtBegin()
            recognizer = StrokeRecognizer()
            isInGesture = true
            return (zone != .none, nil)
        case .changed:
            guard isInGesture, zone != .none else { return (false, nil) }
            let fired = recognizer.add(s.delta).map { (zone: zone, direction: $0) }
            return (true, fired)
        case .ended, .cancelled:
            // Only the end of a gesture we are following belongs to it; a stray cancel from a
            // later finger rest must reach the app.
            let wasInGesture = isInGesture
            isInGesture = false
            return (wasInGesture && zone != .none, nil)
        case .mayBegin:
            // Fingers touching down outside a gesture end any leftover momentum zone.
            if !isInGesture { zone = .none }
        case .none:
            break
        }
        guard s.momentum != .none else { return (false, nil) }
        let swallow = zone != .none
        if s.momentum == .ended { zone = .none }
        return (swallow, nil)
    }
}

/// One entry of the WindowServer window list (front to back).
struct WindowInfo: Equatable {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    var alpha: Double
    var bounds: CGRect
}

enum HitTarget: Equatable {
    case none
    case dock(WindowInfo)
    case window(WindowInfo)
}

enum StrokeLogic {
    /// The first visible window under the pointer decides: an ordinary app window is a
    /// candidate, the Dock is asked about icons (`skipDock` looks behind it on a miss), and
    /// anything else on top (banners, menus, popovers, launchers, our own UI) blocks strokes,
    /// so scrolling it behaves as usual.
    static func hitTarget(at point: CGPoint, windows: [WindowInfo], ownPID: pid_t, dockPID: pid_t?, skipDock: Bool = false) -> HitTarget {
        for window in windows where window.alpha > 0 && window.bounds.contains(point) {
            if window.pid == dockPID {
                if skipDock { continue }
                return .dock(window)
            }
            if window.pid == ownPID || window.layer != 0 { return .none }
            return .window(window)
        }
        return .none
    }

    /// Walks up from `start` (itself included) for at most `maxSteps` elements and returns the
    /// first match. `isExpired` is checked before every step, so a slow chain of lookups gives
    /// up instead of holding the caller.
    static func firstAncestor<T>(from start: T, maxSteps: Int, isExpired: () -> Bool, parent: (T) -> T?, matches: (T) -> Bool) -> T? {
        var current: T? = start
        var steps = 0
        while let element = current, steps < maxSteps {
            if isExpired() { return nil }
            if matches(element) { return element }
            current = parent(element)
            steps += 1
        }
        return nil
    }

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

    /// The Move shortcut's modifiers widen the stroke zone to the whole window, but only
    /// when Move is a keyboard-enabled, modifier-only shortcut (fn, fn+shift, ...).
    static func anywhereModifier(for move: UserShortcut?) -> NSEvent.ModifierFlags? {
        guard let move, move.keyboardEnabled, let shortcut = move.keyboardShortcut,
              shortcut.isModifierOnly, !shortcut.modifierFlags.isEmpty else { return nil }
        return shortcut.modifierFlags
    }
}
