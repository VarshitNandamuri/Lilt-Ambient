
import Combine
import CoreAudio
import IOKit.pwr_mgt
import SwiftUI

@main
struct LiltApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--combined-preview-selftest") {
            do { try MainActor.assumeIsolated { try runCombinedOverlayWindowTest() } }
            catch { fputs("Combined preview test failed: \(error)\n", stderr); exit(1) }
            exit(0)
        }
        if CommandLine.arguments.contains("--skylight-probe") {
            exit(MainActor.assumeIsolated { ExperimentalLockScreenBridge.probe() } ? 0 : 1)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--glow-render") {
            do { try MainActor.assumeIsolated { try renderGlowSequence(arguments: Array(CommandLine.arguments.dropFirst(flag + 1))) } }
            catch { fputs("Glow render failed: \(error)\n", stderr); exit(1) }
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
            exit(0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--preview"), flag + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            let time = flag + 2 < args.count ? Double(args[flag + 2]) ?? 5.5 : 5.5
            let width = flag + 3 < args.count ? Double(args[flag + 3]) ?? 1512 : 1512
            let height = flag + 4 < args.count ? Double(args[flag + 4]) ?? 982 : 982
            let style = flag + 5 < args.count ? LyricStyle(rawValue: args[flag + 5]) ?? .constellation : .constellation
            MainActor.assumeIsolated { renderPreview(to: args[flag + 1], at: time, width: width, height: height, style: style) }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Lilt", systemImage: "sparkles") {
            MenuView(model: model, player: model.player)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let player: PlayerMonitor
    private let store: LyricsStore
    private let lyricsWindow = LyricsWindow()
    private let glowWindow = GlowWindow(disabled: OverlayLaunchOptions.current.disabled)
    private let awake = DisplayAwake()
    private var subscriptions = Set<AnyCancellable>()

    @Published var lyrics: Lyrics?
    @Published var palette: AlbumPalette?
    @Published var status = "Waiting for music"
    @Published var isLocked = false
    @Published private(set) var combinedPreviewActive = false
    @Published var keepPreviewAwake = false { didSet { updateDisplayAwake() } }
    let overlaysDisabled = OverlayLaunchOptions.current.disabled
    private var previewVisible = false
    private var previewTask: Task<Void, Never>?

    /// Extra delay for the current audio output; Bluetooth headphones play ~0.2 s late.
    @Published var outputDelay = 0.0

    init() {
        let cider = CiderClient()
        player = PlayerMonitor(cider: cider)
        store = LyricsStore(cider: cider)

        // receive(on:) waits until the new value is stored before we read it.
        player.$track.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] track in self?.trackChanged(track) }
            .store(in: &subscriptions)

        player.$isPlaying.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        let center = DistributedNotificationCenter.default()

        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        }

        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        }

        glowWindow.onPresentationChanged = { [weak self] visible in
            self?.previewVisible = visible
            self?.updateDisplayAwake()
        }
        glowWindow.startMonitoring()
        player.start()
        if CommandLine.arguments.contains("--combined-preview") {
            Task { @MainActor [weak self] in self?.startCombinedPreview() }
        }
    }

    private func setLocked(_ locked: Bool) {
        LifecycleLog.note("app: setLocked(\(locked)) lyricsLoaded=\(lyrics != nil) playing=\(player.isPlaying) "
            + "trackKnown=\(player.track != nil)")
        isLocked = locked
        if locked { stopCombinedPreview() }
        refresh()
    }

    private func trackChanged(_ track: Track?) {
        lyrics = nil
        palette = nil
        outputDelay = outputIsBluetooth() ? 0.2 : 0
        refresh()

        guard let track else {
            status = "Waiting for music"
            return
        }

        status = "Looking up lyrics…"

        Task {
            // Retry while Cider cannot reach Apple Music.
            for _ in 0..<40 {
                let colors = await store.artworkColors(for: track)
                let found = await store.lyrics(for: track)

                guard player.track == track else { return }

                if palette == nil {
                    palette = AlbumPalette(hexes: colors)
                }

                if let found {
                    WordIcons.shared.warm(found.lines)
                    lyrics = found
                    status = found.wordTimed
                        ? "Word-timed lyrics"
                        : "Line-timed lyrics, word times estimated"
                    refresh()
                    return
                }

                let ciderOnline = await store.appleMusicReachable()

                if track.source != .cider || ciderOnline {
                    status = "No lyrics for this song"
                    return
                }

                guard player.track == track else { return }

                status = "Cider can't reach Apple Music. Retrying… (restart Cider or check the token)"

                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func openLyricsWindow() {
        lyricsWindow.open(
            AnyView(LyricsView(model: self, player: player))
        )
    }

    func startCombinedPreview() {
        guard !overlaysDisabled, !isLocked else { return }
        combinedPreviewActive = true
        glowWindow.setPreviewContent(AnyView(ConstellationView(model: self, player: player, isOverlayPreview: true)))
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.stopCombinedPreview()
        }
        updateDisplayAwake()
    }

    func stopCombinedPreview() {
        previewTask?.cancel()
        previewTask = nil
        combinedPreviewActive = false
        glowWindow.setPreviewContent(nil)
        updateDisplayAwake()
    }

    /// Same condition as the original lock-screen overlay: lyrics exist and music is playing.
    private func refresh() {
        let showLyrics = lyrics != nil && player.isPlaying
        glowWindow.setMusicPlaying(player.isPlaying)
        // Lock screen: exactly upstream's overlay content (LyricsView, full screen, own black stage).
        // Desktop: the same Constellation on a transparent, click-through stage over your apps.
        // Which of them actually appears is decided by the Display Location settings.
        glowWindow.setLyricsContent(
            lock: showLyrics ? AnyView(LyricsView(model: self, player: player)) : nil,
            desktop: showLyrics ? AnyView(ConstellationView(model: self, player: player, transparentBackground: true)) : nil)
        updateDisplayAwake()
    }

    private func updateDisplayAwake() {
        let preview = OverlayPresentationPolicy.holdDisplayAwake(
            disabled: overlaysDisabled, previewRequested: combinedPreviewActive,
            windowVisible: previewVisible, optedIn: keepPreviewAwake, locked: isLocked)
        // Like the original Constellation overlay: keep the lock screen lit while it shows music.
        let lock = OverlayPresentationPolicy.holdDisplayAwakeOnLockScreen(
            locked: isLocked, presented: glowWindow.isLockScreenPresented, playing: player.isPlaying)
        let hold = preview || lock
        if hold != awake.held { LifecycleLog.note("power: display-awake assertion \(hold ? "held" : "released") (lock=\(lock) preview=\(preview))") }
        awake.set(hold)
    }
}

/// A normal resizable window for lyrics while the Mac is unlocked.
@MainActor
final class LyricsWindow {
    private var window: NSWindow?

    func open(_ content: AnyView) {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable,
                    .fullSizeContentView
                ],
                backing: .buffered,
                defer: false
            )

            newWindow.title = "Lilt"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.backgroundColor = .black
            newWindow.isReleasedWhenClosed = false
            newWindow.contentMinSize = NSSize(width: 480, height: 300)
            newWindow.contentView = NSHostingView(rootView: content)
            newWindow.center()
            newWindow.setFrameAutosaveName("LiltLyricsWindow")

            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// True when the default output device is Bluetooth.
func outputIsBluetooth() -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &device
    ) == noErr else {
        return false
    }

    address.mSelector = kAudioDevicePropertyTransportType

    var transport = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)

    guard AudioObjectGetPropertyData(
        device,
        &address,
        0,
        nil,
        &size,
        &transport
    ) == noErr else {
        return false
    }

    return transport == kAudioDeviceTransportTypeBluetooth
        || transport == kAudioDeviceTransportTypeBluetoothLE
}

/// Optional user-idle display-sleep assertion only. Cannot override lid closure or explicit sleep.
final class DisplayAwake {
    private var assertion: IOPMAssertionID = 0
    private(set) var held = false

    deinit { if held { IOPMAssertionRelease(assertion) } }

    func set(_ on: Bool) {
        if on && !held {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Lilt is showing lyrics and lighting" as CFString,
                &assertion
            )

            held = result == kIOReturnSuccess

        } else if !on && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor

    // Cider token stored in UserDefaults.
    @AppStorage("ciderToken") private var token = ""
    @AppStorage("textColor") private var textHex = Theme.defaultText
    @AppStorage("highlightColor") private var highlightHex = Theme.defaultHighlight
    @AppStorage("secondaryColor") private var secondaryHex = Theme.defaultSecondary
    @AppStorage("autoSyncColors") private var autoSync = true
    @AppStorage("lyricFont") private var fontChoice = LyricFont.sfPro.rawValue
    @AppStorage("lyricsDelay") private var delay = 0.0
    @AppStorage("lyricStyle") private var styleChoice = LyricStyle.constellation.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let track = player.track {
                    Text(track.title)
                        .font(.headline)

                    Text("\(track.artist) · \(track.source.rawValue)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Nothing playing")
                        .font(.headline)
                }

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Picker("Style", selection: $styleChoice) {
                    ForEach(LyricStyle.allCases) { style in
                        Text(style.rawValue)
                            .tag(style.rawValue)
                    }
                }

                Divider()

                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto Sync from album", isOn: $autoSync)

                ColorPicker(
                    "Lyric text",
                    selection: hexBinding($textHex)
                )
                .disabled(autoSync)

                ColorPicker(
                    "Highlight",
                    selection: hexBinding($highlightHex)
                )
                .disabled(autoSync)

                ColorPicker(
                    "Secondary text",
                    selection: hexBinding($secondaryHex)
                )
                .disabled(autoSync)

                Button("Reset colors") {
                    textHex = Theme.defaultText
                    highlightHex = Theme.defaultHighlight
                    secondaryHex = Theme.defaultSecondary
                }

                Picker("Font", selection: $fontChoice) {
                    ForEach(LyricFont.allCases) { choice in
                        Text(choice.rawValue)
                            .tag(choice.rawValue)
                    }
                }

                Divider()

                Button("Open lyrics window") {
                    model.openLyricsWindow()
                }

                Button(model.combinedPreviewActive ? "Stop combined preview" : "Preview Constellation + lighting") {
                    if model.combinedPreviewActive { model.stopCombinedPreview() }
                    else { model.startCombinedPreview() }
                }
                .disabled(model.overlaysDisabled)

                if model.combinedPreviewActive {
                    Text("Unlocked preview · stops after 60 seconds. Uses sample lyrics when playback or timed lyrics are unavailable.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Keep display awake during preview", isOn: $model.keepPreviewAwake)
                    .disabled(model.overlaysDisabled)
                if model.overlaysDisabled {
                    Text("Safe mode: all overlays disabled.").font(.caption)
                }

                DisplayLocationSettingsView()

                Divider()

                AmbientLightingSettingsView()

                HStack {
                    Text("Lyrics delay")

                    Slider(
                        value: $delay,
                        in: -0.5...1.0,
                        step: 0.05
                    )

                    Text(String(format: "%+.2f s", delay))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }

                if model.outputDelay > 0 {
                    Text("Bluetooth output: +0.20 s added automatically")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                SecureField("Cider app token", text: $token)

                Text("Optional. For Apple's word-timed lyrics: Cider → Settings → Connectivity")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                Button("Quit Lilt") {
                    NSApp.terminate(nil)
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: min(780, (NSScreen.main?.visibleFrame.height ?? 860) - 80))
    }
}
