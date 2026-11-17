import AppKit
import Metal
import SwiftUI

func runOverlayPolicySelfTest() {
    precondition(OverlayLaunchOptions(arguments: ["Lilt", "--disable-overlays"], environment: [:]).disabled)
    precondition(OverlayLaunchOptions(arguments: [], environment: ["LILT_DISABLE_OVERLAYS": "1"]).disabled)
    precondition(!OverlayLaunchOptions(arguments: ["Lilt"], environment: [:]).disabled)
    let lockOnlyFallback = OverlayLaunchOptions(arguments: ["Lilt", "--disable-lock-screen-effects"], environment: [:])
    precondition(lockOnlyFallback.lockScreenDisabled && !lockOnlyFallback.disabled)
    typealias P = OverlayPresentationPolicy
    // Every Display Location combination, unlocked and locked, with lyrics available.
    for lyricsLoc in DisplayLocation.allCases {
        for lightingLoc in DisplayLocation.allCases {
            let locs = DisplayLocations(lyrics: lyricsLoc, lighting: lightingLoc)
            for locked in [false, true] {
                let d = P.decide(.init(locked: locked, locations: locs, lyricsAvailable: true))
                let lyricsHere = locked ? lyricsLoc.onLockScreen : lyricsLoc.onDesktop
                let lightHere = locked ? lightingLoc.onLockScreen : lightingLoc.onDesktop
                precondition(d.lyrics == lyricsHere && d.glow == lightHere,
                             "lyrics=\(lyricsLoc) lighting=\(lightingLoc) locked=\(locked) gave \(d)")
                // Paused music / no lyrics: lyrics never show, lighting is unaffected.
                let paused = P.decide(.init(locked: locked, locations: locs, lyricsAvailable: false))
                precondition(!paused.lyrics && paused.glow == lightHere)
                // Lighting switch off: no glow anywhere, lyrics unaffected.
                let dark = P.decide(.init(locked: locked, locations: locs, ambientEnabled: false, lyricsAvailable: true))
                precondition(!dark.glow && dark.lyrics == lyricsHere)
                // Display asleep, switched-away session, safe mode: nothing renders.
                for blocked in [P.Inputs(locked: locked, screensAsleep: true, locations: locs, lyricsAvailable: true),
                                P.Inputs(locked: locked, sessionInactive: true, locations: locs, lyricsAvailable: true),
                                P.Inputs(disabled: true, locked: locked, locations: locs, lyricsAvailable: true)] {
                    precondition(!P.decide(blocked).visible)
                }
                // Lock layer unavailable / rejected: nothing on the lock screen, desktop unaffected.
                let unsupported = P.decide(.init(locked: locked, lockSupported: false, locations: locs, lyricsAvailable: true))
                precondition(locked ? !unsupported.visible : unsupported == d)
            }
        }
    }
    // The user's preferred setup: nothing on the desktop; both on the lock screen.
    let preferred = DisplayLocations(lyrics: .lockScreen, lighting: .lockScreen)
    precondition(!P.decide(.init(locked: false, locations: preferred, lyricsAvailable: true)).visible)
    precondition(P.decide(.init(locked: true, locations: preferred, lyricsAvailable: true)) == OverlayDecision(glow: true, lyrics: true))
    precondition(DisplayLocations() == preferred, "Both settings default to Lock Screen")
    // Music Sync is pre-warmed on the desktop only for lock-screen lighting while music plays.
    precondition(P.prewarmAudio(.init(locations: preferred), musicSync: true, musicPlaying: true))
    precondition(!P.prewarmAudio(.init(locations: preferred), musicSync: true, musicPlaying: false))
    precondition(!P.prewarmAudio(.init(locations: .init(lyrics: .lockScreen, lighting: .desktop)), musicSync: true, musicPlaying: true))
    precondition(!P.prewarmAudio(.init(lockSupported: false, locations: preferred), musicSync: true, musicPlaying: true))
    // Preview button: desktop only, never while locked.
    precondition(P.decide(.init(locations: .init(lyrics: .off, lighting: .off), previewRequested: true)) == OverlayDecision(glow: true, lyrics: true))
    precondition(!P.decide(.init(locked: true, locations: .init(lyrics: .off, lighting: .off), previewRequested: true)).visible)
    // Screen choice: an unplugged monitor falls back to a connected screen; the built-in is listed first.
    precondition(TargetScreen.options().first?.id == TargetScreen.builtIn)
    if !NSScreen.screens.isEmpty {
        precondition(TargetScreen.resolve("display:0-0-unplugged") != nil, "Missing monitor must fall back")
        for screen in NSScreen.screens {
            precondition(TargetScreen.resolve(TargetScreen.identifier(screen)) === screen, "Each screen resolves to itself")
        }
    }
    // Persistence round trip.
    let defaults = UserDefaults(suiteName: "lilt.selftest.locations")!
    defaults.removePersistentDomain(forName: "lilt.selftest.locations")
    precondition(DisplayLocations.load(from: defaults) == preferred)
    defaults.set(DisplayLocation.both.rawValue, forKey: DisplayLocationKeys.lyrics)
    defaults.set(DisplayLocation.off.rawValue, forKey: DisplayLocationKeys.lighting)
    precondition(DisplayLocations.load(from: defaults) == DisplayLocations(lyrics: .both, lighting: .off))
    defaults.removePersistentDomain(forName: "lilt.selftest.locations")
    precondition(!P.holdDisplayAwake(disabled: false, previewRequested: false,
        windowVisible: true, optedIn: true, locked: false), "Normal glow must not hold an idle-sleep assertion")
    precondition(OverlayPresentationPolicy.holdDisplayAwakeOnLockScreen(locked: true, presented: true, playing: true))
    precondition(!OverlayPresentationPolicy.holdDisplayAwakeOnLockScreen(locked: true, presented: true, playing: false),
                 "Paused music must let the locked display sleep")
    precondition(!OverlayPresentationPolicy.holdDisplayAwakeOnLockScreen(locked: false, presented: true, playing: true))
    precondition(!OverlayPresentationPolicy.holdDisplayAwakeOnLockScreen(locked: true, presented: false, playing: true))
}

@MainActor
private func sampleConstellation(size: CGSize) -> some View {
    let painter = ConstellationPainter(lines: ConstellationPreviewSample.lines, songTime: 3.5, clock: 0,
        textColor: colorFromHex(Theme.defaultText), highlight: colorFromHex(Theme.defaultHighlight),
        secondary: colorFromHex(Theme.defaultSecondary), font: .sfPro, layouts: LayoutCache())
    return Canvas { context, bounds in painter.draw(context, size: bounds) }
        .frame(width: size.width, height: size.height)
}

/// Presents a real, click-through desktop window briefly, without audio, artwork polling,
/// idle-sleep assertions, live player polling, or private SkyLight calls.
@MainActor
func runCombinedOverlayWindowTest() throws {
    LifecycleLog.writesFile = false
    runOverlayPolicySelfTest()
    print("Required private SkyLight symbols available: \(ExperimentalLockScreenBridge.symbolsAvailable()) (visibility unverified; no Space delegation tested)")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var settings = GlowSettings()
    settings.mode = .idle
    let controller = GlowWindow(locations: DisplayLocations(lyrics: .lockScreen, lighting: .desktop))
    controller.startMonitoring(settings: settings)
    defer { controller.stopMonitoring() }
    let initial = controller.presentationSnapshot
    guard let panel = initial.window, let metal = initial.metal, let renderer = metal.renderer else {
        throw NSError(domain: "Lilt.CombinedPreview", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No display or Metal view available"])
    }
    let windowNumber = panel.windowNumber
    controller.setPreviewContent(AnyView(sampleConstellation(size: panel.frame.size)))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let combined = controller.presentationSnapshot
    precondition(combined.window === panel && combined.metal === metal && metal.renderer === renderer,
                 "Preview must reuse the window, Metal view and renderer")
    precondition(combined.window?.windowNumber == windowNumber && combined.hasLyrics)
    precondition(panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain)
    precondition(!panel.isKeyWindow && !panel.isMainWindow && panel.ignoresMouseEvents)
    precondition(panel.contentView?.hitTest(NSPoint(x: 100, y: 100)) == nil)
    precondition(panel.level == .statusBar && !panel.canBecomeVisibleWithoutLogin)
    precondition(!combined.audioRunning, "The Idle preview must not start a capture stream")
    precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                 "Showing the preview must not activate the application")
    controller.setPreviewContent(nil)
    let restored = controller.presentationSnapshot
    precondition(!restored.hasLyrics && restored.window === panel && restored.metal === metal)
    precondition(panel.contentView?.subviews.count == 1, "Stopping the preview must restore the glow-only tree")
    controller.stopMonitoring()
    precondition(!panel.isVisible)

    let safe = GlowWindow(disabled: true)
    safe.startMonitoring(settings: settings)
    safe.setPreviewContent(AnyView(Text("Must never appear")))
    safe.show()
    precondition(safe.presentationSnapshot.window == nil && !safe.presentationSnapshot.audioRunning,
                 "The fallback must prevent all overlay windows and capture")
    safe.stopMonitoring()
    var unsafeDelegations = 0
    let lockSafe = GlowWindow(lockScreenDisabled: true, locations: DisplayLocations(lyrics: .both, lighting: .both),
                             lockDelegate: { _ in unsafeDelegations += 1 })
    lockSafe.startMonitoring(settings: settings)
    lockSafe.setSessionLocked(true)
    precondition(lockSafe.presentationSnapshot.window?.isVisible == false && unsafeDelegations == 0)
    lockSafe.setSessionLocked(false)
    precondition(lockSafe.presentationSnapshot.window?.isVisible == true)
    lockSafe.stopMonitoring()
    try testExperimentalHostTransfers(settings: settings)
    try renderCombinedOverlaySample()
    print("combined preview window test ok: one window; same Metal view; no focus or mouse input; safe fallback passed")
}

/// Simulated lock notifications on an UNLOCKED desktop. The injected delegate is a
/// recording stub; this test never calls SkyLight or changes authentication/session state.
@MainActor
private func testExperimentalHostTransfers(settings: GlowSettings) throws {
    var delegated: [NSWindow] = []
    let controller = GlowWindow(lockScreenDisabled: false, locations: DisplayLocations(lyrics: .lockScreen, lighting: .both),
        lockDelegate: { delegated.append($0) })
    controller.startMonitoring(settings: settings)
    defer { controller.stopMonitoring() }
    let original = controller.presentationSnapshot
    guard let desktop = original.window, let metal = original.metal, let renderer = metal.renderer else {
        throw NSError(domain: "Lilt.CombinedPreview", code: 5)
    }
    let sample = { AnyView(sampleConstellation(size: desktop.frame.size)) }
    controller.setMusicPlaying(true)
    controller.setLyricsContent(lock: sample(), desktop: sample())
    precondition(!controller.lockStageVisible, "The black stage must never appear on the desktop")
    precondition(!controller.presentationSnapshot.hasLyrics, "Lyrics = Lock Screen must not show on the desktop")
    controller.setSessionLocked(true)
    precondition(controller.lockStageVisible && controller.lockLyricsShowing,
                 "Locked with music playing must start on the black lyrics screen")
    // Music pauses: AppModel withdraws the lyrics; the lyrics screen goes, the border stays.
    controller.setMusicPlaying(false)
    controller.setLyricsContent(lock: nil, desktop: nil)
    precondition(!controller.lockStageVisible && !controller.lockLyricsShowing)
    precondition(controller.presentationSnapshot.metal?.isHidden == false, "The border stays without lyrics")
    controller.setMusicPlaying(true)
    controller.setLyricsContent(lock: sample(), desktop: sample())
    precondition(controller.lockLyricsShowing)
    let locked = controller.presentationSnapshot
    precondition(delegated.count == 1 && locked.window === delegated[0] && locked.window !== desktop)
    precondition(!desktop.isVisible && locked.window?.isVisible == true && locked.hasLyrics)
    precondition(locked.metal === metal && metal.renderer === renderer)
    precondition(locked.window?.canBecomeKey == false && locked.window?.canBecomeMain == false
        && locked.window?.ignoresMouseEvents == true && locked.window?.isKeyWindow == false)
    precondition(controller.isLockScreenPresented)
    // No lease: still presented well after the old 45-second cut-off would have mattered.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    precondition(controller.presentationSnapshot.window?.isVisible == true && controller.isLockScreenPresented)
    controller.setScreensAsleep(true)
    precondition(controller.presentationSnapshot.window?.isVisible == false && !controller.isLockScreenPresented)
    controller.setScreensAsleep(false)
    // Display woke while still locked: the host must be delegated AGAIN after being ordered in.
    precondition(controller.presentationSnapshot.window?.isVisible == true && delegated.count == 2
        && delegated[1] === delegated[0], "Wake while locked must re-delegate the same host")
    precondition(controller.presentationSnapshot.hasLyrics && controller.presentationSnapshot.metal === metal)
    controller.setSessionInactive(true)
    precondition(controller.presentationSnapshot.window?.isVisible == false)
    controller.setSessionInactive(false)
    controller.setSessionLocked(false)
    let restored = controller.presentationSnapshot
    precondition(!controller.lockStageVisible, "Unlock must remove the black stage")
    precondition(restored.window === desktop && restored.metal === metal && !restored.hasLyrics && desktop.isVisible)
    precondition(delegated[0].isVisible == false
        && desktop.contentView?.subviews.filter({ !$0.isHidden }).count == 1)
    precondition(!controller.isLockScreenPresented)
    // A second lock gets a fresh host, delegated once more.
    let beforeRelock = delegated.count
    controller.setSessionLocked(true)
    precondition(delegated.count == beforeRelock + 1 && delegated.last !== delegated[0] && controller.isLockScreenPresented,
                 "Each lock must get a fresh, delegated host")
    controller.setSessionLocked(false)
    controller.setSessionLocked(true)
    controller.setLocations(DisplayLocations(lyrics: .desktop, lighting: .desktop))
    precondition(controller.presentationSnapshot.window?.isVisible == false, "Desktop-only must leave the lock screen")
    controller.setSessionLocked(false)
    precondition(controller.presentationSnapshot.window === desktop && desktop.isVisible)
    precondition(controller.presentationSnapshot.hasLyrics && controller.decision == OverlayDecision(glow: true, lyrics: true),
                 "Lyrics = Desktop shows them on the desktop")

    // Lyrics = Lock Screen, Lighting = Desktop: desktop glow only; lock screen lyrics only.
    controller.setLocations(DisplayLocations(lyrics: .lockScreen, lighting: .desktop))
    precondition(desktop.isVisible && !controller.presentationSnapshot.hasLyrics && metal.isHidden == false)
    controller.setSessionLocked(true)
    precondition(controller.isLockScreenPresented && controller.lockLyricsShowing && metal.isHidden && metal.isPaused,
                 "Lock screen shows lyrics only; the hidden glow must not render")
    controller.setSessionLocked(false)

    // Lyrics = Desktop, Lighting = Lock Screen: desktop lyrics only; lock screen glow only.
    controller.setLocations(DisplayLocations(lyrics: .desktop, lighting: .lockScreen))
    precondition(desktop.isVisible && controller.presentationSnapshot.hasLyrics && metal.isHidden)
    controller.setSessionLocked(true)
    precondition(controller.isLockScreenPresented && !controller.lockLyricsShowing && !controller.lockStageVisible
        && metal.isHidden == false && metal.isPaused == false)
    controller.setSessionLocked(false)

    // Preferred: Lock Screen + Lock Screen. Nothing on the desktop; both while locked.
    controller.setLocations(DisplayLocations(lyrics: .lockScreen, lighting: .lockScreen))
    precondition(!desktop.isVisible && !controller.decision.visible, "Nothing may show on the desktop")
    controller.setSessionLocked(true)
    precondition(controller.isLockScreenPresented && controller.lockLyricsShowing && metal.isHidden == false
        && controller.presentationSnapshot.metal === metal && metal.renderer === renderer)
    controller.setSessionLocked(false)
    precondition(!desktop.isVisible && !controller.isLockScreenPresented && !controller.lockStageVisible,
                 "Unlock must remove both effects from every layer")

    // External monitor as an ambience screen (unlocked): black lyrics screen + border, and it must
    // stay up while the user types on the laptop.
    controller.ambienceOverride = true
    controller.setLocations(DisplayLocations(lyrics: .both, lighting: .both))
    precondition(desktop.isVisible && controller.lockStageVisible && controller.lockLyricsShowing
        && metal.isHidden == false, "Monitor ambience shows black lyrics screen + border while unlocked")
    precondition(desktop.canBecomeKey == false && desktop.ignoresMouseEvents, "Ambience never takes input")
    controller.setLocations(DisplayLocations(lyrics: .lockScreen, lighting: .both))
    precondition(!controller.lockStageVisible && desktop.isVisible, "No lyrics on the desktop -> no black screen")
    controller.ambienceOverride = false
    controller.setLocations(DisplayLocations(lyrics: .both, lighting: .both))
    precondition(!controller.lockStageVisible && controller.presentationSnapshot.hasLyrics,
                 "Built-in display keeps the transparent overlay")
    controller.ambienceOverride = nil

    // Off + Off: nothing anywhere.
    controller.setLocations(DisplayLocations(lyrics: .off, lighting: .off))
    controller.setSessionLocked(true)
    precondition(!controller.isLockScreenPresented && !desktop.isVisible)
    controller.setSessionLocked(false)
    precondition(!desktop.isVisible)

    let failed = GlowWindow(lockScreenDisabled: false, locations: DisplayLocations(lyrics: .lockScreen, lighting: .both),
        lockDelegate: { _ in throw NSError(domain: "TestFailedDelegate", code: 1) })
    failed.startMonitoring(settings: settings)
    defer { failed.stopMonitoring() }
    let failureDesktop = failed.presentationSnapshot.window
    failed.setSessionLocked(true)
    precondition(failed.presentationSnapshot.window?.isVisible == false)
    failed.setSessionLocked(false)
    precondition(failed.presentationSnapshot.window === failureDesktop && failureDesktop?.isVisible == true)
    print("simulated lock host transfers passed (SkyLight delegation stubbed; no physical lock test)")
}

/// Render each existing engine into the same composition order as the unlocked window.
/// This is generated sample content, not a screenshot or a lock-screen test.
@MainActor
private func renderCombinedOverlaySample() throws {
    let size = CGSize(width: 1470, height: 956)
    let imageRenderer = ImageRenderer(content: sampleConstellation(size: size))
    guard let lyrics = imageRenderer.cgImage, let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "Lilt.CombinedPreview", code: 2)
    }
    let model = GlowModel()
    model.settings.mode = .idle
    model.useDefaultColors()
    for tick in 0...360 { model.step(now: 1 + Double(tick) / 120) }
    let renderer = try GlowRenderer(model: model, device: device)
    renderer.setField(GlowField.build(size: size, notch: NotchMetrics(left: 646, right: 824, height: 32)))
    let data = try renderer.renderFrame(width: 1470, height: 956, bounds: size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
    guard let provider = CGDataProvider(data: data as CFData),
          let glow = CGImage(width: 1470, height: 956, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: 1470 * 4, space: space, bitmapInfo: info, provider: provider,
              decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let context = CGContext(data: nil, width: 1470, height: 956, bitsPerComponent: 8,
              bytesPerRow: 1470 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "Lilt.CombinedPreview", code: 3)
    }
    let rect = CGRect(origin: .zero, size: size)
    context.setFillColor(CGColor(gray: 0.025, alpha: 1))
    context.fill(rect)
    context.draw(lyrics, in: rect)
    context.draw(glow, in: rect)
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Lilt.CombinedPreview", code: 4)
    }
    let directory = URL(fileURLWithPath: "build/combined-preview", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png.write(to: directory.appendingPathComponent("combined.png"))
}
