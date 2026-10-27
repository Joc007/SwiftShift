import Cocoa
import Accessibility
import os.log

/// Swipe strokes: a two-finger swipe on a window's title bar (or anywhere on it with the
/// Move modifier held) maximises it, snaps it to a half, restores or minimises it; swiping
/// down on a Dock icon minimises that app's frontmost window.
///
/// Threads: scroll events arrive on the StrokeTap thread, which only does arithmetic plus
/// one hit test per gesture (AX calls capped by a short timeout). Window actions run on
/// `actionQueue`. Settings are read on main and handed over through `snapshot`.
final class StrokeManager {
    static let shared = StrokeManager()
    let actionQueue = DispatchQueue(label: "com.swiftshift.strokes", qos: .userInitiated)

    private struct Snapshot {
        var anywhereModifier: NSEvent.ModifierFlags?
        var ignoredBundleIDs: Set<String> = []
        var screens: [CGRect] = []
        var isInGesture = false
    }

    private static let dockBundleID = "com.apple.dock"
    private static let titleBarHeight: CGFloat = 28
    /// Below the title bar, only this deep into the window is worth asking AX for a toolbar.
    private static let toolbarSearchDepth: CGFloat = 120
    /// Cap for AX calls made from the tap thread, so a hung app cannot stall input.
    private static let hitTestTimeout: Float = 0.1
    /// Cap for AX calls on `actionQueue`: slow-but-alive apps (Electron) still get their writes.
    private static let actionTimeout: Float = 0.25

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var tracker = StrokeGestureTracker() // tap thread only
    private var records: [CGWindowID: SnapRecord] = [:] // actionQueue only
    private var tap: StrokeTap? // main thread only
    private var isEnabled = false
    private var observers: [(center: NotificationCenter, token: Any)] = []
    private var healthCheckTimer: Timer?
    private let ownPID = NSRunningApplication.current.processIdentifier

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(.default, UserDefaults.didChangeNotification) { $0.updateEnabled() }
        observe(.default, .shortcutsDidChange) { $0.refreshSnapshot() }
        observe(.default, .ignoredAppsDidChange) { $0.refreshSnapshot() }
        // Same events that silently kill the shared tap (see FIXES.md).
        observe(workspace, NSWorkspace.didWakeNotification) { $0.rebuildTap() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.rebuildTap() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) {
            $0.refreshSnapshot()
            $0.rebuildTap()
        }
        updateEnabled()
    }

    func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        disable()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (StrokeManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            action(self)
        }
        observers.append((center, token))
    }

    // MARK: - Enable / rebuild (main thread)

    private func updateEnabled() {
        let wanted = PreferencesManager.loadBool(for: .swipeGestures)
        guard wanted != isEnabled else { return }
        if wanted { enable() } else { disable() }
    }

    private func enable() {
        isEnabled = true
        refreshSnapshot()
        startTap()
        // Secure Input (password prompts, sudo) can kill the tap with no notification.
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.withSnapshot({ $0.isInGesture }) else { return }
            self.rebuildTap()
            self.actionQueue.async { self.pruneRecords() }
        }
    }

    private func disable() {
        isEnabled = false
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        tap?.stop()
        tap = nil
    }

    private func rebuildTap() {
        guard isEnabled else { return }
        tap?.stop()
        startTap()
    }

    private func startTap() {
        let tap = StrokeTap { [weak self] event in self?.handle(event) ?? false }
        tap.start()
        self.tap = tap
    }

    private func refreshSnapshot() {
        let anywhere = StrokeLogic.anywhereModifier(for: ShortcutsManager.shared.load(for: .move))
        let ignored = Set(PreferencesManager.getIgnoredApps())
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { StrokeLogic.axRect(fromAppKit: $0.visibleFrame, primaryScreenHeight: primaryHeight) }
        withSnapshot {
            $0.anywhereModifier = anywhere
            $0.ignoredBundleIDs = ignored
            $0.screens = screens
        }
    }

    @discardableResult
    private func withSnapshot<T>(_ body: (inout Snapshot) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&snapshot)
    }

    // MARK: - Scroll events (tap thread)

    private func handle(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        let sample = ScrollSample(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            phase: Self.scrollPhase(nsEvent.phase),
            momentum: Self.momentumPhase(nsEvent.momentumPhase),
            delta: StrokeLogic.fingerDelta(
                scrollingDeltaX: nsEvent.scrollingDeltaX,
                scrollingDeltaY: nsEvent.scrollingDeltaY,
                invertedFromDevice: nsEvent.isDirectionInvertedFromDevice
            )
        )
        let result = tracker.handle(sample) { hitTest(at: event.location, flags: event.flags) }
        let inGesture = tracker.isInGesture
        withSnapshot { $0.isInGesture = inGesture }
        if let fired = result.fired {
            actionQueue.async { [weak self] in self?.perform(zone: fired.zone, direction: fired.direction) }
        }
        return result.swallow
    }

    private static func scrollPhase(_ phase: NSEvent.Phase) -> ScrollPhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.mayBegin) { return .mayBegin }
        return .none
    }

    private static func momentumPhase(_ phase: NSEvent.Phase) -> MomentumPhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .none
    }

    /// Topmost window under the pointer, from the WindowServer list (no IPC into the target
    /// app). AX is only asked about Dock items and, just below a title bar, for a toolbar.
    private func hitTest(at point: CGPoint, flags: CGEventFlags) -> StrokeZone {
        let snap = withSnapshot { $0 }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if bundleID == Self.dockBundleID {
                // The Dock owns more than the icon strip; only an app icon counts.
                if let url = dockItemURL(dockPID: pid, at: point) { return .dockIcon(appURL: url) }
                continue
            }
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let bundleID, !snap.ignoredBundleIDs.contains(bundleID) else { return .none }

            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            let zone = StrokeZone.window(id: windowID, pid: pid, frame: bounds)
            let held = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).swiftShiftShortcutFlags
            if let anywhere = snap.anywhereModifier, held == anywhere { return zone }
            let depth = point.y - bounds.minY
            if depth <= Self.titleBarHeight { return zone }
            if depth <= Self.toolbarSearchDepth, let bottom = toolbarBottom(pid: pid, windowFrame: bounds), point.y <= bottom {
                return zone
            }
            return .none
        }
        return .none
    }

    private func dockItemURL(dockPID: pid_t, at point: CGPoint) -> URL? {
        let dock = Self.capped(AXUIElementCreateApplication(dockPID))
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        let item = Self.capped(hit)
        guard Self.string(item, kAXRoleAttribute) == "AXDockItem",
              Self.string(item, kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (value as! CFURL) as URL
    }

    /// Bottom edge (AX coordinates) of the window's toolbar, if it has one.
    private func toolbarBottom(pid: pid_t, windowFrame: CGRect) -> CGFloat? {
        guard let window = Self.axWindow(pid: pid, matching: windowFrame, timeout: Self.hitTestTimeout) else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return nil }
        for child in children.map({ Self.capped($0) }) where Self.string(child, kAXRoleAttribute) == kAXToolbarRole {
            if let frame = Self.frame(of: child) { return frame.maxY }
        }
        return nil
    }

    // MARK: - Actions (actionQueue)

    func perform(zone: StrokeZone, direction: StrokeDirection) {
        os_log("StrokeManager: %{public}@ on %{public}@", log: .default, type: .info, "\(direction)", "\(zone)")
        switch zone {
        case .none:
            return
        case .dockIcon(let appURL):
            guard direction == .down, minimiseFrontmostWindow(appURL: appURL) else { return }
            afterAction()
        case .window(let id, let pid, let frame):
            performOnWindow(id: id, pid: pid, frame: frame, direction: direction)
        }
    }

    private func performOnWindow(id: CGWindowID, pid: pid_t, frame: CGRect, direction: StrokeDirection) {
        guard let window = Self.axWindow(pid: pid, matching: frame, timeout: Self.actionTimeout),
              let current = Self.frame(of: window) else { return }
        let screens = withSnapshot { $0.screens }
        let center = CGPoint(x: current.midX, y: current.midY)
        guard let visible = screens.first(where: { $0.contains(center) }) ?? screens.first else { return }

        let (action, record) = StrokeLogic.windowAction(direction: direction, current: current, visible: visible, record: records[id])
        switch action {
        case .none:
            records[id] = record
            afterAction() // a captured swipe ends Move even when there is nothing to snap
            return
        case .snap(let target):
            Self.setFrame(target, of: window)
            // Store what the app actually accepted (minimum sizes), so the next swipe down
            // still recognises the window as snapped.
            records[id] = record.map { SnapRecord(preSnap: $0.preSnap, snapped: Self.frame(of: window) ?? target) }
        case .restore(let preSnap):
            Self.setFrame(preSnap, of: window)
            records[id] = nil
        case .minimise:
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            records[id] = nil
        }
        afterAction()
    }

    /// Dock swipe down: one window per swipe, most recently used first.
    private func minimiseFrontmostWindow(appURL: URL) -> Bool {
        let path = appURL.resolvingSymlinksInPath().path
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == path }) else { return false }
        let appElement = Self.capped(AXUIElementCreateApplication(app.processIdentifier), timeout: Self.actionTimeout)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement] else { return false }
        for window in windows.map({ Self.capped($0, timeout: Self.actionTimeout) }) {
            guard Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
            var minimised: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimised)
            if (minimised as? Bool) == true { continue }
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        }
        return false
    }

    /// Holding the Move modifier for a stroke also starts Move. A stroke ends Move for the rest
    /// of that key hold, so a pointer nudge after the swipe does not drag the snapped window;
    /// releasing and pressing the modifier again starts a new Move.
    private func afterAction() {
        DispatchQueue.main.async {
            MouseTracker.shared.stopTracking(for: .move)
        }
    }

    /// Drop records of windows that no longer exist.
    private func pruneRecords() {
        guard !records.isEmpty else { return }
        let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        let ids = Set(windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        records = records.filter { ids.contains($0.key) }
    }

    // MARK: - AX helpers

    /// The AX window of `pid` whose frame matches the WindowServer bounds.
    private static func axWindow(pid: pid_t, matching frame: CGRect, timeout: Float) -> AXUIElement? {
        let app = capped(AXUIElementCreateApplication(pid), timeout: timeout)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement] else { return nil }
        return windows.map({ capped($0, timeout: timeout) }).first { window in
            guard let f = Self.frame(of: window) else { return false }
            return StrokeLogic.framesMatch(f, frame)
        }
    }

    private static func capped(_ element: AXUIElement, timeout: Float = hitTestTimeout) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// Position, size, then position again: some apps clamp the first move while the window
    /// still has its old size (e.g. restoring from maximised to a frame near a screen edge).
    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        WindowManager.resize(window: window, to: frame.size, from: frame.origin)
        WindowManager.move(window: window, to: frame.origin)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = WindowManager.getPosition(window: element), let size = WindowManager.getSize(window: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
