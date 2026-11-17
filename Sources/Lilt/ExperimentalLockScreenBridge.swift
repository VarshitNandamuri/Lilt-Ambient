import AppKit
import SkyLightWindow

/// Unsupported private SkyLight integration — the same mechanism the original Constellation
/// lock-screen overlay used (SkyLightWindow package): a private Space at absolute level 400
/// (`NotificationCenterAtScreenLock`), which the window server composites above the lock screen.
///
/// Unlike `SkyLightOperator.delegateWindow`, which discards the CGError, this checks the result
/// and then asks the window server which Spaces the window is in, so the log shows whether the
/// move actually happened. Neither proves the pixels reach the panel: only a physical lock can.
enum ExperimentalLockScreenBridge {
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)
    private static let required = ["SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel", "SLSShowSpaces",
                                   "SLSSpaceAddWindowsAndRemoveFromSpaces"]

    static func symbolsAvailable() -> Bool {
        guard let handle else { return false }
        return required.allSatisfy { dlsym(handle, $0) != nil }
    }

    /// Space ids the window currently belongs to, or nil when the query is unavailable.
    @MainActor
    static func spaces(of window: NSWindow) -> [Int]? {
        guard let handle, window.windowNumber > 0, let sym = dlsym(handle, "SLSCopySpacesForWindows"),
              let mainSym = dlsym(handle, "SLSMainConnectionID") else { return nil }
        let main = unsafeBitCast(mainSym, to: (@convention(c) () -> Int32).self)
        let copy = unsafeBitCast(sym, to: CopySpaces.self)
        guard let list = copy(main(), 0x7, [NSNumber(value: window.windowNumber)] as CFArray)?.takeRetainedValue()
        else { return [] }
        return (list as? [NSNumber])?.map(\.intValue) ?? []
    }

    /// Moves an on-screen window into the lock-screen-level Space. Throws when it demonstrably failed.
    @MainActor
    static func delegate(_ window: NSWindow) throws {
        guard symbolsAvailable(), let handle, let sym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            throw failure(1, "Required private SkyLight symbols are unavailable")
        }
        guard window.windowNumber > 0 else { throw failure(2, "Window has no window-server number yet") }
        let op = SkyLightOperator.shared   // creates + shows the level-400 Space once per process
        guard op.space != 0 else { throw failure(3, "SLSSpaceCreate returned 0 (connection \(op.connection))") }
        let add = unsafeBitCast(sym, to: AddWindows.self)
        // The return value is NOT a reliable CGError on macOS 26 (garbage was observed), so it is
        // only logged. Space membership reported by the window server is the real check.
        let raw = add(op.connection, op.space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        let spaces = spaces(of: window)
        LifecycleLog.note("skylight: delegate win#\(window.windowNumber) -> space \(op.space) (conn \(op.connection)) "
            + "rawReturn=\(raw) windowSpaces=\(spaces.map { "\($0)" } ?? "unknown")")
        if let spaces, !spaces.isEmpty, !spaces.contains(Int(op.space)) {
            throw failure(5, "Window server did not place window in lock Space (in \(spaces))")
        }
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Lilt.LockScreen", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import MetalKit
import SwiftUI

/// Counts MTKView draw callbacks and SwiftUI TimelineView ticks for the probe.
private final class ProbeCounter: NSObject, MTKViewDelegate {
    nonisolated(unsafe) static var timelineTicks = 0
    var draws = 0
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        draws += 1
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = view.device?.makeCommandQueue()?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

private struct ProbeTimeline: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { _, _ in ProbeCounter.timelineTicks += 1 }
                .id(timeline.date)
        }
    }
}

extension ExperimentalLockScreenBridge {
    /// `Lilt --skylight-probe`: on the UNLOCKED desktop, delegates a 200×200 fully transparent,
    /// click-through window holding an MTKView and a SwiftUI TimelineView, and measures whether
    /// both keep rendering once the window lives in the private Space. Exits immediately, which
    /// destroys the Space. Proves the API path and render loops; NOT lock-screen visibility.
    @MainActor
    static func probe() -> Bool {
        LifecycleLog.writesFile = false
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let mid = NSScreen.main.map { NSPoint(x: $0.frame.midX - 100, y: $0.frame.midY - 100) } ?? .zero
        let frame = NSRect(origin: mid, size: NSSize(width: 200, height: 200))
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.canBecomeVisibleWithoutLogin = true
        window.level = .screenSaver
        let counter = ProbeCounter()
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let metal = MTKView(frame: container.bounds, device: MTLCreateSystemDefaultDevice())
        metal.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metal.layer?.isOpaque = false
        metal.delegate = counter
        metal.preferredFramesPerSecond = 60
        let timeline = NSHostingView(rootView: ProbeTimeline())
        timeline.frame = container.bounds
        container.addSubview(timeline)
        container.addSubview(metal)
        window.contentView = container

        func measure() -> (Int, Int) {
            let d0 = counter.draws, t0 = ProbeCounter.timelineTicks
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            return (counter.draws - d0, ProbeCounter.timelineTicks - t0)
        }
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // let the window server commit it
        let before = spaces(of: window) ?? []
        let (metalBefore, swiftUIBefore) = measure()
        do {
            try delegate(window)
        } catch {
            print("skylight probe FAILED: \(error.localizedDescription) (spaces before=\(before))")
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let (metalAfter, swiftUIAfter) = measure()
        print("skylight probe: spaces before=\(before) after=\(spaces(of: window) ?? []) lockSpace=\(SkyLightOperator.shared.space)")
        print("  window: \(WindowDiagnostics.describe(window))")
        print("  MTKView draws/s   before=\(metalBefore) after=\(metalAfter)")
        print("  TimelineView ticks/s before=\(swiftUIBefore) after=\(swiftUIAfter)")
        let moved = !(spaces(of: window) ?? []).contains(where: before.contains)
        print(moved ? "  result: moved out of the desktop Space" : "  result: NOT moved")
        return moved
    }
}
