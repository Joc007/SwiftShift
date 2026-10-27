import Cocoa
import os.log

/// A scroll-only CGEventTap running on its own thread and run loop.
/// Swipe strokes need to see (and sometimes swallow) every scroll event system-wide. The
/// shared CGEventSupervisor tap runs on the main thread, which blocks on AX calls during
/// Move/Resize, and is rebuilt whenever another subscriber changes its mask; a scroll tap
/// there would stall scrolling everywhere and drop strokes mid-gesture.
final class StrokeTap {
    fileprivate let handler: (CGEvent) -> Bool
    fileprivate var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let ready = DispatchSemaphore(value: 0)

    /// `handler` runs on the tap thread for every scroll event; return true to swallow it.
    /// It must not block: WindowServer waits for it before delivering input.
    init(handler: @escaping (CGEvent) -> Bool) {
        self.handler = handler
    }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func start() {
        guard thread == nil else { return }
        // The thread retains self until its run loop exits, so a callback still in flight
        // during stop() never sees a deallocated tap.
        let thread = Thread { self.runTapThread() }
        thread.name = "com.swiftshift.stroketap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
    }

    func stop() {
        guard thread != nil else { return }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop, let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let runLoop { CFRunLoopStop(runLoop) }
        port = nil
        source = nil
        runLoop = nil
        thread = nil
    }

    private func runTapThread() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: strokeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            os_log("StrokeTap: could not create the scroll event tap", log: .default, type: .error)
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        self.runLoop = runLoop
        ready.signal()
        CFRunLoopRun()
    }
}

private func strokeTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<StrokeTap>.fromOpaque(userInfo).takeUnretainedValue()

    // macOS disables a tap that is too slow or interrupted by user input; re-enable it
    // instead of letting strokes die silently (see FIXES.md).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    return tap.handler(event) ? nil : Unmanaged.passUnretained(event)
}
