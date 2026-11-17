import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

struct OverlayLaunchOptions {
    let disabled: Bool
    let lockScreenDisabled: Bool

    init(arguments: [String], environment: [String: String]) {
        disabled = arguments.contains("--disable-overlays") || environment["LILT_DISABLE_OVERLAYS"] == "1"
        lockScreenDisabled = disabled || arguments.contains("--disable-lock-screen-effects")
            || environment["LILT_DISABLE_LOCK_SCREEN_EFFECTS"] == "1"
    }

    static var current: OverlayLaunchOptions {
        OverlayLaunchOptions(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }
}

/// Where an effect is shown. Persisted as its raw value.
enum DisplayLocation: String, CaseIterable, Identifiable, Sendable {
    case off, desktop, lockScreen, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .desktop: return "Desktop"
        case .lockScreen: return "Lock Screen"
        case .both: return "Both"
        }
    }
    var onDesktop: Bool { self == .desktop || self == .both }
    var onLockScreen: Bool { self == .lockScreen || self == .both }
}

enum DisplayLocationKeys {
    static let lyrics = "display.lyricsLocation"
    static let lighting = "display.lightingLocation"
    static let defaultLocation = DisplayLocation.lockScreen
}

struct DisplayLocations: Equatable, Sendable {
    var lyrics = DisplayLocationKeys.defaultLocation
    var lighting = DisplayLocationKeys.defaultLocation

    static func load(from d: UserDefaults = .standard) -> DisplayLocations {
        func read(_ key: String) -> DisplayLocation {
            d.string(forKey: key).flatMap(DisplayLocation.init(rawValue:)) ?? DisplayLocationKeys.defaultLocation
        }
        return DisplayLocations(lyrics: read(DisplayLocationKeys.lyrics), lighting: read(DisplayLocationKeys.lighting))
    }
}

/// What the overlay shows right now. `glow` and `lyrics` are decided independently.
struct OverlayDecision: Equatable, CustomStringConvertible {
    var glow = false
    var lyrics = false
    var visible: Bool { glow || lyrics }
    var description: String { "glow=\(glow) lyrics=\(lyrics)" }
}

/// The ONE place that decides visibility. Inputs come from the session, the display, the two
/// Display Location settings, playback and the lighting switch; nothing else may override it.
enum OverlayPresentationPolicy {
    struct Inputs {
        var disabled = false
        var started = true
        var locked = false
        var screensAsleep = false
        var sessionInactive = false
        /// Lock-screen layer usable: private symbols present, not disabled at launch, and the
        /// window server did not reject this lock's window.
        var lockSupported = true
        var locations = DisplayLocations()
        /// Lighting switch on and an animation mode selected.
        var ambientEnabled = true
        /// Lyrics loaded for the current song AND music playing (the upstream condition).
        var lyricsAvailable = false
        /// The manual "Preview Constellation + lighting" button (desktop only).
        var previewRequested = false
    }

    static func decide(_ i: Inputs) -> OverlayDecision {
        // A sleeping display or a switched-away session never renders anything.
        guard !i.disabled, i.started, !i.screensAsleep, !i.sessionInactive else { return OverlayDecision() }
        if i.locked {
            guard i.lockSupported else { return OverlayDecision() }
            return OverlayDecision(glow: i.locations.lighting.onLockScreen && i.ambientEnabled,
                                   lyrics: i.locations.lyrics.onLockScreen && i.lyricsAvailable)
        }
        return OverlayDecision(glow: (i.locations.lighting.onDesktop || i.previewRequested) && i.ambientEnabled,
                               lyrics: (i.locations.lyrics.onDesktop && i.lyricsAvailable) || i.previewRequested)
    }

    /// Keep Music Sync capture running on the unlocked desktop when lighting is lock-screen-only
    /// and music plays, so the stream is already live at lock time (starting ScreenCaptureKit
    /// while locked is not something we can rely on). Real audio only; nothing is drawn.
    static func prewarmAudio(_ i: Inputs, musicSync: Bool, musicPlaying: Bool) -> Bool {
        musicSync && musicPlaying && !i.disabled && i.started && !i.locked && !i.sessionInactive
            && i.lockSupported && i.ambientEnabled && i.locations.lighting.onLockScreen
    }

    static func holdDisplayAwake(disabled: Bool, previewRequested: Bool, windowVisible: Bool,
                                 optedIn: Bool, locked: Bool) -> Bool {
        !disabled && previewRequested && windowVisible && optedIn && !locked
    }

    /// Only an idle-sleep assertion: lid close, explicit sleep and the power button still win.
    static func holdDisplayAwakeOnLockScreen(locked: Bool, presented: Bool, playing: Bool) -> Bool {
        locked && presented && playing
    }
}

@MainActor
final class LockScreenEffectsStatus: ObservableObject {
    static let shared = LockScreenEffectsStatus()
    @Published var message = "Waiting for the next lock"
}

/// One full-screen content tree: SwiftUI lyrics below the existing transparent Metal view.
/// The panel and both views reject input; keyboard events remain with the user's current app.
final class CombinedOverlayContentView: NSView {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Opaque black "lyrics screen" for the idle lock screen. On the lock screen the lyrics live
    /// INSIDE it, so lyrics and black appear and disappear together; the glow stays above it.
    private lazy var stage: NSView = {
        let v = NSView(frame: bounds)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.autoresizingMask = [.width, .height]
        v.alphaValue = 0
        v.isHidden = true
        return v
    }()
    private(set) var stageVisible = false
    private weak var lyrics: NSView?

    private func ensureStage(below metal: NSView?) {
        guard stage.superview !== self else { return }
        stage.frame = bounds
        if let metal, metal.superview === self { addSubview(stage, positioned: .below, relativeTo: metal) }
        else { addSubview(stage, positioned: .below, relativeTo: subviews.first) }
    }

    /// `onStage`: lock screen (lyrics only visible with the black lyrics screen).
    /// Otherwise (unlocked preview) the lyrics sit directly under the glow, as before.
    func installLyrics(_ newLyrics: NSView?, below metal: NSView, onStage: Bool = false) {
        let parent: NSView? = newLyrics == nil ? nil : (onStage ? stage : self)
        if let old = lyrics, old !== newLyrics || old.superview !== parent { old.removeFromSuperview() }
        subviews.filter { $0 !== metal && $0 !== stage && $0 !== newLyrics }.forEach { $0.removeFromSuperview() }
        lyrics = newLyrics
        guard let newLyrics, let parent else { return }
        if onStage { ensureStage(below: metal) }
        newLyrics.frame = parent.bounds
        newLyrics.autoresizingMask = [.width, .height]
        guard newLyrics.superview !== parent else { return }
        if onStage { stage.addSubview(newLyrics) } else { addSubview(newLyrics, positioned: .below, relativeTo: metal) }
    }

    /// True when lyrics are installed and actually on screen (not hidden with the stage).
    func lyricsShowing(_ host: NSView?) -> Bool {
        guard let host, host.isDescendant(of: self) else { return false }
        return host.superview !== stage || stageVisible
    }

    /// Fades the black lyrics screen in (idle lock screen) or out (reveal wallpaper + login UI).
    func setStageVisible(_ visible: Bool, animated: Bool) {
        guard visible != stageVisible else { return }
        stageVisible = visible
        ensureStage(below: subviews.first(where: { $0 is GlowBorderView }))
        stage.isHidden = false
        let target: CGFloat = visible ? 1 : 0
        guard animated else {
            stage.alphaValue = target
            stage.isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = visible ? 1.2 : 0.35
            stage.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stageVisible else { return }
                self.stage.isHidden = true
            }
        })
    }
}

/// System-wide time since the last keyboard / mouse / trackpad input. Read-only polling of the
/// HID idle counter: needs no permission, installs no event tap, and never consumes input.
enum UserActivity {
    private static let anyInput = CGEventType(rawValue: ~0) ?? .keyDown
    static func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}

/// Public power-management APIs only.
enum DisplayWaker {
    /// Declares local user activity, which turns a sleeping display back on (no system wake).
    static func wake() -> Bool {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity("Lilt lock-screen lyrics" as CFString, kIOPMUserActiveLocal, &id)
        if result == kIOReturnSuccess { IOPMAssertionRelease(id) }
        return result == kIOReturnSuccess
    }

    /// True when the laptop lid is closed (never light the screen up then).
    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }
}

/// Which display shows the lyrics and lighting. Saved as a stable identifier (vendor/model/serial),
/// because CGDirectDisplayIDs can change when a monitor is reconnected.
enum TargetScreen {
    static let key = "display.screen"
    static let builtIn = "builtin"

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = displayID(screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    static func identifier(_ screen: NSScreen) -> String {
        if isBuiltIn(screen) { return builtIn }
        guard let id = displayID(screen) else { return "name:\(screen.localizedName)" }
        return "display:\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// Built-in display first, then monitors, as (identifier, name) for the picker.
    static func options(_ screens: [NSScreen] = NSScreen.screens) -> [(id: String, name: String)] {
        var list = [(id: builtIn, name: "Built-in Display")]
        for s in screens where !isBuiltIn(s) { list.append((identifier(s), s.localizedName)) }
        return list
    }

    /// The chosen screen if connected; otherwise the built-in display; otherwise the main screen.
    static func resolve(_ choice: String, among screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first(where: { identifier($0) == choice })
            ?? screens.first(where: isBuiltIn)
            ?? screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? screens.first
    }

    static var currentChoice: String { UserDefaults.standard.string(forKey: key) ?? builtIn }
}
