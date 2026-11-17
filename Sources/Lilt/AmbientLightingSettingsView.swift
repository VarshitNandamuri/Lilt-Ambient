import SwiftUI
import AppKit

/// Compact "Ambient Lighting" section for Lilt's menu-bar window.
/// Every control writes straight to UserDefaults; GlowWindow picks the change up live.
///
/// Embed it in the existing menu-bar content, e.g.
///     Divider()
///     AmbientLightingSettingsView()
///
/// It needs a window-style menu-bar UI (MenuBarExtra with `.menuBarExtraStyle(.window)`,
/// an NSPopover, or a settings window). Plain NSMenu / `.menu` style cannot host sliders
/// or colour pickers.
struct AmbientLightingSettingsView: View {
    @AppStorage(AmbientLightingKeys.enabled) private var enabled = GlowSettings().enabled
    @AppStorage(AmbientLightingKeys.mode) private var mode = GlowSettings().mode.rawValue
    @AppStorage(AmbientLightingKeys.thickness) private var thickness = Double(GlowSettings().thickness)
    @AppStorage(AmbientLightingKeys.glow) private var glow = GlowSettings().glow
    @AppStorage(AmbientLightingKeys.speed) private var speed = GlowSettings().speed
    @AppStorage(AmbientLightingKeys.followNotch) private var followNotch = GlowSettings().followNotch
    @AppStorage(AmbientLightingKeys.colorMode) private var colorMode = GlowSettings().colorMode.rawValue
    @AppStorage(AmbientLightingKeys.brightness) private var brightness = GlowSettings().brightness
    @AppStorage(AmbientLightingKeys.beatSensitivity) private var beatSensitivity = GlowSettings().beatSensitivity
    @AppStorage(AmbientLightingKeys.colorA) private var colorA = GlowColorCoding.hex(GlowSettings().defaultA)
    @AppStorage(AmbientLightingKeys.colorB) private var colorB = GlowColorCoding.hex(GlowSettings().defaultB)

    @ObservedObject private var status = AmbientLightingStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Ambient Lighting", isOn: $enabled)
                .toggleStyle(.switch)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Animation", selection: $mode) {
                    Text("Music Sync").tag(GlowSettings.Mode.musicSync.rawValue)
                    Text("Idle").tag(GlowSettings.Mode.idle.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(status.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Colors", selection: $colorMode) {
                    Text("Reference Match").tag(GlowSettings.ColorMode.reference.rawValue)
                    Text("Album Colors").tag(GlowSettings.ColorMode.album.rawValue)
                    Text("Manual Colors").tag(GlowSettings.ColorMode.manual.rawValue)
                }
                slider("Brightness", value: $brightness, in: 0...1)
                slider("Border Thickness", value: $thickness, in: 1...8)
                slider("Glow Strength", value: $glow, in: 0...1)
                slider("Flow Speed", value: $speed, in: 0.25...2)
                slider("Beat Sensitivity", value: $beatSensitivity, in: 0...2)

                Toggle("Follow Notch", isOn: $followNotch)

                HStack(spacing: 10) {
                    Text("Manual colors")
                    Spacer()
                    ColorPicker("Color A", selection: colorBinding($colorA), supportsOpacity: false)
                        .labelsHidden()
                    ColorPicker("Color B", selection: colorBinding($colorB), supportsOpacity: false)
                        .labelsHidden()
                }
                .disabled(colorMode != GlowSettings.ColorMode.manual.rawValue)
                .opacity(colorMode == GlowSettings.ColorMode.manual.rawValue ? 1 : 0.5)

                Button("Reset lighting appearance") {
                    let defaults = GlowSettings()
                    colorMode = defaults.colorMode.rawValue
                    thickness = Double(defaults.thickness)
                    brightness = defaults.brightness
                    glow = defaults.glow
                    speed = defaults.speed
                    beatSensitivity = defaults.beatSensitivity
                    followNotch = defaults.followNotch
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
        }
        .controlSize(.small)
        .padding(.vertical, 4)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit()
            }
            .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: {
                let c = GlowColorCoding.rgb(hex.wrappedValue) ?? SIMD3(1, 1, 1)
                return Color(red: c.x, green: c.y, blue: c.z)
            },
            set: { newValue in
                guard let ns = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                hex.wrappedValue = GlowColorCoding.hex(SIMD3(Double(ns.redComponent),
                                                             Double(ns.greenComponent),
                                                             Double(ns.blueComponent)))
            }
        )
    }
}

/// "Display Location": where Constellation lyrics and ambient lighting appear, independently.
struct DisplayLocationSettingsView: View {
    @AppStorage(DisplayLocationKeys.lyrics) private var lyrics = DisplayLocationKeys.defaultLocation.rawValue
    @AppStorage(DisplayLocationKeys.lighting) private var lighting = DisplayLocationKeys.defaultLocation.rawValue
    @AppStorage(TargetScreen.key) private var screenChoice = TargetScreen.builtIn
    @State private var screens = TargetScreen.options()
    @ObservedObject private var lockStatus = LockScreenEffectsStatus.shared

    private var lockAvailable: Bool {
        GlowWindow.lockLayerAvailable && !OverlayLaunchOptions.current.lockScreenDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Display Location").font(.headline)
            Picker("Screen", selection: $screenChoice) {
                ForEach(screens, id: \.id) { option in Text(option.name).tag(option.id) }
                if !screens.contains(where: { $0.id == screenChoice }) {
                    Text("Disconnected monitor (using Built-in)").tag(screenChoice)
                }
            }
            .pickerStyle(.menu)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = TargetScreen.options()
            }
            if screenChoice != TargetScreen.builtIn {
                Text("On a monitor, Desktop lyrics fill it as a black ambience screen while you keep using your Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            picker("Constellation Lyrics", selection: $lyrics)
            picker("Ambient Lighting", selection: $lighting)
            Text(lockStatus.message)
                .font(.caption2).foregroundStyle(lockAvailable ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Lock Screen uses the same private SkyLight layer as the original Lilt lock-screen lyrics. "
                 + "It never takes keyboard or mouse input. Log: ~/Library/Logs/Lilt/lockscreen.log")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func picker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(DisplayLocation.allCases) { location in
                let unavailable = location.onLockScreen && !lockAvailable
                Text(unavailable ? "\(location.title) (unavailable)" : location.title).tag(location.rawValue)
            }
        }
        .pickerStyle(.menu)
    }
}
