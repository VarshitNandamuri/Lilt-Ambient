import AppKit
import SwiftUI
import Metal
import MetalKit
import QuartzCore
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import Accelerate
import simd

// Ambient lighting overlay for Lilt.
//
// Architecture (all of it lives in this file and in AmbientLightingSettingsView.swift;
// nothing here touches the lyrics engine):
//
//   NotchMetrics / NotchOutlineGeometry / Outline  – exact screen + notch outline, sampled by arc length
//   GlowField                                      – one-time (per geometry) distance field: for every
//                                                    2pt cell, distance to the outline + position along it
//   GlowModel                                      – per-frame animation state (audio smoothing, colour flow)
//   GlowRenderer / GlowBorderView                  – one full-screen Metal quad per frame; the fragment shader
//                                                    turns (distance, perimeter position) into light
//   SystemAudioAnalyzer                            – ScreenCaptureKit audio from Spotify / Apple Music,
//                                                    FFT bands, onset detection, adaptive normalisation
//   GlowAlbumPalette                               – two dominant colours from the current artwork
//   GlowWindow                                     – the click-through, desktop-only NSPanel and lifecycle
//
// Per frame the CPU only fills 512 small structs; the panel, view, pipeline and distance field
// are created once and rebuilt only when the screen geometry or the notch setting changes.

// MARK: - Settings

struct GlowSettings: Equatable, Sendable {
    enum Mode: String, Sendable { case musicSync, idle, none }
    enum ColorMode: String, Sendable { case reference, album, manual }

    var enabled = true
    var mode: Mode = .musicSync
    var thickness: CGFloat = 2        // luminous edge width in points (1...8)
    var brightness = 0.9
    var beatSensitivity = 1.0
    var glow: Double = 0.7            // 0...1, reach and strength of the soft glow
    var speed: Double = 1.0           // 0.25...2, animation speed multiplier
    var followNotch = true            // route the light around the notch
    var colorMode: ColorMode = .reference
    var useAlbumColors: Bool {
        get { colorMode == .album }
        set { colorMode = newValue ? .album : .manual }
    }
    // Manual colours remain independent of the palette measured from the recording.
    var defaultA = SIMD3<Double>(1.0, 0.22, 0.32)
    var defaultB = SIMD3<Double>(0.25, 0.95, 0.45)
}

/// UserDefaults keys shared by GlowWindow and AmbientLightingSettingsView (@AppStorage).
enum AmbientLightingKeys {
    static let enabled = "ambient.enabled"
    static let mode = "ambient.mode"
    static let thickness = "ambient.thickness"
    static let glow = "ambient.glow"
    static let speed = "ambient.speed"
    static let followNotch = "ambient.followNotch"
    static let albumColors = "ambient.albumColors"
    static let colorA = "ambient.colorA"
    static let colorB = "ambient.colorB"
    static let colorMode = "ambient.colorMode"
    static let brightness = "ambient.brightness"
    static let beatSensitivity = "ambient.beatSensitivity"
}

enum GlowColorCoding {
    static func hex(_ c: SIMD3<Double>) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.x), byte(c.y), byte(c.z))
    }

    static func rgb(_ hex: String) -> SIMD3<Double>? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return SIMD3(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

extension GlowSettings {
    static func load(from d: UserDefaults = .standard) -> GlowSettings {
        var s = GlowSettings()
        if d.object(forKey: AmbientLightingKeys.enabled) != nil { s.enabled = d.bool(forKey: AmbientLightingKeys.enabled) }
        if let m = d.string(forKey: AmbientLightingKeys.mode), let mode = Mode(rawValue: m) { s.mode = mode }
        if let c = d.string(forKey: AmbientLightingKeys.colorMode), let mode = ColorMode(rawValue: c) { s.colorMode = mode }
        if d.object(forKey: AmbientLightingKeys.brightness) != nil { s.brightness = min(1, max(0, d.double(forKey: AmbientLightingKeys.brightness))) }
        if d.object(forKey: AmbientLightingKeys.beatSensitivity) != nil { s.beatSensitivity = min(2, max(0, d.double(forKey: AmbientLightingKeys.beatSensitivity))) }
        if d.object(forKey: AmbientLightingKeys.thickness) != nil {
            s.thickness = CGFloat(min(8, max(1, d.double(forKey: AmbientLightingKeys.thickness))))
        }
        if d.object(forKey: AmbientLightingKeys.glow) != nil { s.glow = min(1, max(0, d.double(forKey: AmbientLightingKeys.glow))) }
        if d.object(forKey: AmbientLightingKeys.speed) != nil { s.speed = min(2, max(0.25, d.double(forKey: AmbientLightingKeys.speed))) }
        if d.object(forKey: AmbientLightingKeys.followNotch) != nil { s.followNotch = d.bool(forKey: AmbientLightingKeys.followNotch) }
        if let h = d.string(forKey: AmbientLightingKeys.colorA), let c = GlowColorCoding.rgb(h) { s.defaultA = c }
        if let h = d.string(forKey: AmbientLightingKeys.colorB), let c = GlowColorCoding.rgb(h) { s.defaultB = c }
        return s
    }

    func save(to d: UserDefaults = .standard) {
        d.set(enabled, forKey: AmbientLightingKeys.enabled)
        d.set(mode.rawValue, forKey: AmbientLightingKeys.mode)
        d.set(colorMode.rawValue, forKey: AmbientLightingKeys.colorMode)
        d.set(brightness, forKey: AmbientLightingKeys.brightness)
        d.set(beatSensitivity, forKey: AmbientLightingKeys.beatSensitivity)
        d.set(Double(thickness), forKey: AmbientLightingKeys.thickness)
        d.set(glow, forKey: AmbientLightingKeys.glow)
        d.set(speed, forKey: AmbientLightingKeys.speed)
        d.set(followNotch, forKey: AmbientLightingKeys.followNotch)
        d.set(useAlbumColors, forKey: AmbientLightingKeys.albumColors)
        d.set(GlowColorCoding.hex(defaultA), forKey: AmbientLightingKeys.colorA)
        d.set(GlowColorCoding.hex(defaultB), forKey: AmbientLightingKeys.colorB)
    }
}

/// Human-readable state shown in the settings section (e.g. "Screen Recording permission needed").
@MainActor
final class AmbientLightingStatus: ObservableObject {
    static let shared = AmbientLightingStatus()
    @Published var message = "Off"
}

// MARK: - Notch geometry

/// Position of the notch in the screen's own coordinate space (origin top-left, points).
struct NotchMetrics: Equatable, Sendable {
    let left: CGFloat
    let right: CGFloat
    let height: CGFloat

    static func forScreen(_ screen: NSScreen) -> NotchMetrics? {
        let top = screen.safeAreaInsets.top
        guard top > 0,
              let l = screen.auxiliaryTopLeftArea,
              let r = screen.auxiliaryTopRightArea else { return nil }
        // The auxiliary areas are the menu-bar strips either side of the notch, in global
        // coordinates; the notch is the gap between them.
        let left = l.maxX - screen.frame.minX
        let right = r.minX - screen.frame.minX
        guard right > left + 20 else { return nil }
        return NotchMetrics(left: left, right: right, height: top)
    }
}

/// Builds the closed outline of the visible display: rounded screen corners, and (when a
/// notch is given) a detour down the notch's left side, along its rounded bottom and back up
/// its right side, with small fillets where the notch meets the top edge. Clockwise in a
/// y-down space, starting at the top-left. Plain CGPath so it can be built off the main actor.
enum NotchOutlineGeometry {
    /// MacBook Pro / Air (notched) display corner radius, in points.
    static let screenCornerRadius: CGFloat = 10
    /// Radius of the notch's two bottom corners.
    static let notchBottomRadius: CGFloat = 8
    /// Fillet where the notch sides meet the top edge of the screen.
    static let notchTopFillet: CGFloat = 4

    static func path(in rect: CGRect, notch: NotchMetrics?, inset: CGFloat = 0,
                     cornerRadius: CGFloat = screenCornerRadius) -> CGPath {
        let p = CGMutablePath()
        let r = rect.insetBy(dx: inset, dy: inset)
        let cr = min(cornerRadius, r.width / 4, r.height / 4)

        p.move(to: CGPoint(x: r.minX + cr, y: r.minY))

        if let n = notch {
            let l = n.left - inset
            let rr = n.right + inset
            let bottom = n.height + inset
            let ear = min(notchTopFillet, (bottom - r.minY) / 3)
            let bot = min(notchBottomRadius, (rr - l) / 4, (bottom - r.minY) / 2)

            p.addLine(to: CGPoint(x: l - ear, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: l, y: r.minY), tangent2End: CGPoint(x: l, y: bottom), radius: ear)
            p.addArc(tangent1End: CGPoint(x: l, y: bottom), tangent2End: CGPoint(x: rr, y: bottom), radius: bot)
            p.addArc(tangent1End: CGPoint(x: rr, y: bottom), tangent2End: CGPoint(x: rr, y: r.minY), radius: bot)
            p.addArc(tangent1End: CGPoint(x: rr, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: ear)
        }

        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: cr)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: cr)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: cr)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + cr, y: r.minY), radius: cr)
        p.closeSubpath()
        return p
    }
}

/// SwiftUI wrapper kept for existing call sites; geometry comes from NotchOutlineGeometry.
struct NotchBorderShape: Shape {
    var notch: NotchMetrics?
    var inset: CGFloat = 0
    var cornerRadius: CGFloat = NotchOutlineGeometry.screenCornerRadius

    func path(in rect: CGRect) -> Path {
        Path(NotchOutlineGeometry.path(in: rect, notch: notch, inset: inset, cornerRadius: cornerRadius))
    }
}

// MARK: - Outline sampling (evenly spaced by arc length)

struct Outline: Sendable {
    let points: [CGPoint]
    let inward: [CGVector]
    let s: [Double]            // 0..<1 normalised distance along the perimeter
    let length: CGFloat

    /// `count` <= 0 picks one sample every ~2pt.
    static func make(size: CGSize, notch: NotchMetrics?, count: Int = 0) -> Outline {
        let path = NotchOutlineGeometry.path(in: CGRect(origin: .zero, size: size), notch: notch)

        // 1. Flatten into a dense polyline (arcs come through as cubic curves).
        var poly: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        path.applyWithBlock { elPtr in
            let el = elPtr.pointee
            switch el.type {
            case .moveToPoint:
                current = el.points[0]; start = current; poly.append(current)
            case .addLineToPoint:
                let p = el.points[0]
                let steps = max(1, Int(hypot(p.x - current.x, p.y - current.y) / 4))
                for k in 1...steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    poly.append(CGPoint(x: current.x + (p.x - current.x) * t, y: current.y + (p.y - current.y) * t))
                }
                current = p
            case .addQuadCurveToPoint:
                let c = el.points[0], p = el.points[1]
                for k in 1...16 {
                    let t = CGFloat(k) / 16, mt = 1 - t
                    poly.append(CGPoint(x: mt * mt * current.x + 2 * mt * t * c.x + t * t * p.x,
                                        y: mt * mt * current.y + 2 * mt * t * c.y + t * t * p.y))
                }
                current = p
            case .addCurveToPoint:
                let c1 = el.points[0], c2 = el.points[1], p = el.points[2]
                for k in 1...16 {
                    let t = CGFloat(k) / 16, mt = 1 - t
                    let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
                    poly.append(CGPoint(x: a * current.x + b * c1.x + c * c2.x + d * p.x,
                                        y: a * current.y + b * c1.y + c * c2.y + d * p.y))
                }
                current = p
            case .closeSubpath:
                current = start
            @unknown default:
                break
            }
        }
        if let first = poly.first { poly.append(first) }
        guard poly.count > 2 else { return Outline(points: [], inward: [], s: [], length: 0) }

        // 2. Cumulative length.
        var cum: [CGFloat] = [0]
        cum.reserveCapacity(poly.count)
        for i in 1..<poly.count {
            cum.append(cum[i - 1] + hypot(poly[i].x - poly[i - 1].x, poly[i].y - poly[i - 1].y))
        }
        let total = max(cum.last ?? 1, 1)
        let n = count > 0 ? count : max(256, Int(total / 2))

        // 3. Resample uniformly.
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        var seg = 1
        for k in 0..<n {
            let target = total * CGFloat(k) / CGFloat(n)
            while seg < cum.count - 1 && cum[seg] < target { seg += 1 }
            let a = poly[seg - 1], b = poly[seg]
            let span = max(cum[seg] - cum[seg - 1], 0.0001)
            let f = (target - cum[seg - 1]) / span
            pts.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        }

        // 4. Inward normals (path is clockwise in a y-down space).
        var normals: [CGVector] = []
        var ss: [Double] = []
        normals.reserveCapacity(n); ss.reserveCapacity(n)
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n], next = pts[(i + 1) % n]
            var tx = next.x - prev.x, ty = next.y - prev.y
            let len = max(hypot(tx, ty), 0.0001)
            tx /= len; ty /= len
            normals.append(CGVector(dx: -ty, dy: tx))
            ss.append(Double(i) / Double(n))
        }
        return Outline(points: pts, inward: normals, s: ss, length: total)
    }
}

// MARK: - Distance field

/// For every `cell`-sized grid cell of the screen: signed distance (pt) to the outline
/// (negative inside the notch), and the perimeter position of the nearest outline point
/// encoded as (cos 2πs, sin 2πs) so it interpolates without a seam at s = 0/1.
struct GlowField: Sendable {
    let perimeterLength: CGFloat
    let width: Int
    let height: Int
    let cell: CGFloat
    let data: [Float]     // RGBA32F, row-major, row 0 = top of screen

    static func build(size: CGSize, notch: NotchMetrics?, cell: CGFloat = 2) -> GlowField {
        let outline = Outline.make(size: size, notch: notch)
        let pts = outline.points
        let n = pts.count
        let w = Int((size.width / cell).rounded(.up)) + 1
        let h = Int((size.height / cell).rounded(.up)) + 1
        var data = [Float](repeating: 0, count: w * h * 4)
        guard n > 0 else { return GlowField(perimeterLength: 1, width: w, height: h, cell: cell, data: data) }

        let shape = NotchOutlineGeometry.path(in: CGRect(origin: .zero, size: size), notch: notch)
        let notchZone: CGRect? = notch.map {
            CGRect(x: $0.left - 8, y: -1, width: $0.right - $0.left + 16, height: $0.height + 8)
        }
        let stride = max(1, n / 400)
        let twoPi = 2 * Double.pi

        data.withUnsafeMutableBufferPointer { out in
            pts.withUnsafeBufferPointer { pp in
                for gy in 0..<h {
                    for gx in 0..<w {
                        let px = CGFloat(gx) * cell, py = CGFloat(gy) * cell
                        // Coarse pass, then refine around the best coarse candidate.
                        var best = 0
                        var bestD = CGFloat.greatestFiniteMagnitude
                        var i = 0
                        while i < n {
                            let dx = pp[i].x - px, dy = pp[i].y - py
                            let d = dx * dx + dy * dy
                            if d < bestD { bestD = d; best = i }
                            i += stride
                        }
                        let center = best
                        for k in -stride...stride {
                            let j = (center + k + n) % n
                            let dx = pp[j].x - px, dy = pp[j].y - py
                            let d = dx * dx + dy * dy
                            if d < bestD { bestD = d; best = j }
                        }
                        var dist = Double(bestD.squareRoot())
                        let point = CGPoint(x: px, y: py)
                        if (dist < 14 || notchZone?.contains(point) == true), !shape.contains(point) {
                            dist = -dist          // outside rounded corners / under the notch: never lit
                        }
                        let s = outline.s[best]
                        let o = (gy * w + gx) * 4
                        out[o] = Float(dist)
                        out[o + 1] = Float(cos(twoPi * s))
                        out[o + 2] = Float(sin(twoPi * s))
                        out[o + 3] = 0
                    }
                }
            }
        }
        return GlowField(perimeterLength: outline.length, width: w, height: h, cell: cell, data: data)
    }
}

// MARK: - Animation model

/// One entry of the per-frame perimeter table read by the fragment shader.
struct GlowSample {
    var color: SIMD4<Float>   // rgb (sRGB-encoded), a = brightness
    var shape: SIMD4<Float>   // halo reach, wave thickness, thin edge width, crest brightness
}

@MainActor
final class GlowModel {
    var settings = GlowSettings()
    /// Polled once per frame in Music Sync mode.
    var audioSource: (() -> AudioSnapshot)?
    var perimeterLength: Double = 4800

    private struct LightRegion {
        var position: Double
        let velocity: Double       // points per second; negative travels counterclockwise
        let width: Double          // fraction of perimeter (Gaussian sigma)
        let peak: Double
        let colorMix: Double
    }
    private var regions = [
        LightRegion(position: 0.03, velocity: -1240, width: 0.052, peak: 1.0, colorMix: 0.10),
        LightRegion(position: 0.47, velocity: -1110, width: 0.065, peak: 0.92, colorMix: 0.75),
        LightRegion(position: 0.77, velocity: -1330, width: 0.030, peak: 0.55, colorMix: 0.35)
    ]

    // Smoothed audio levels (0...1)
    private(set) var bass = 0.0
    private(set) var mid = 0.0
    private(set) var treble = 0.0
    private var loudness = 0.0
    private(set) var beat = 0.0
    private var beatTarget = 0.0
    private var presence = 0.0          // fades in with music, out when it stops
    private var lastBeatCount = 0

    // Motion
    private var lastTime: CFTimeInterval = 0
    private(set) var amplitude = 0.0

    // The two colours (eased when the song changes)
    private var a = SIMD3<Double>(0, 0.30, 1)
    private var b = SIMD3<Double>(0, 0.58, 1)
    private var targetA = SIMD3<Double>(0, 0.30, 1)
    private var targetB = SIMD3<Double>(0, 0.58, 1)

    var energy: Double { min(1, 0.55 * bass + 0.35 * mid + 0.10 * treble) }

    /// True while anything visible is still changing (used to throttle the frame rate).
    var isActive: Bool {
        amplitude > 0.003 || simd_length(targetA - a) + simd_length(targetB - b) > 0.01
    }

    func setTargetColors(_ x: SIMD3<Double>, _ y: SIMD3<Double>) { targetA = x; targetB = y }
    func useDefaultColors() {
        if settings.colorMode == .manual {
            targetA = settings.defaultA; targetB = settings.defaultB
        } else {
            // Recording: saturated blue edge with cyan variations. No warm light was
            // visible in this clip; these are palette estimates, not native RGB samples.
            targetA = SIMD3(0, 0.30, 1); targetB = SIMD3(0, 0.58, 1)
        }
    }

    func step(now: CFTimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : max(0, now - lastTime)
        lastTime = now

        func approach(_ cur: inout Double, _ target: Double, attack: Double, release: Double) {
            let tau = target > cur ? attack : release
            cur += (target - cur) * (1 - exp(-dt / tau))
        }

        let kc = 1 - exp(-dt / 1.2)          // ~1.2 s colour cross-fade
        a += (targetA - a) * kc
        b += (targetB - b) * kc

        let spd = settings.speed
        switch settings.mode {
        case .musicSync:
            let snap = audioSource?() ?? AudioSnapshot()
            let fresh = snap.audible && now - snap.timestamp < 0.35
            approach(&bass, fresh ? snap.bass : 0, attack: 0.035, release: 0.24)
            approach(&mid, fresh ? snap.mid : 0, attack: 0.06, release: 0.30)
            approach(&treble, fresh ? snap.treble : 0, attack: 0.03, release: 0.15)
            approach(&loudness, fresh ? snap.level : 0, attack: 0.05, release: 0.35)
            approach(&presence, fresh ? 1 : 0, attack: 0.25, release: 1.1)
            if snap.beatCount != lastBeatCount {
                lastBeatCount = snap.beatCount
                if fresh { beatTarget = min(1.5, settings.beatSensitivity) }
            }
        case .idle:
            approach(&bass, 0, attack: 0.1, release: 0.4)
            approach(&mid, 0, attack: 0.1, release: 0.4)
            approach(&treble, 0, attack: 0.1, release: 0.4)
            approach(&loudness, 0, attack: 0.1, release: 0.4)
            approach(&presence, 1, attack: 0.6, release: 0.6)
        case .none:
            approach(&presence, 0, attack: 0.3, release: 0.3)
        }
        approach(&beat, beatTarget, attack: 0.025, release: 0.025)
        beatTarget *= exp(-dt / 0.14)

        let e = energy
        switch settings.mode {
        case .musicSync:
            amplitude = presence * min(1, 0.30 + 0.40 * loudness + 0.25 * e + 0.15 * beat)
        case .idle, .none:
            amplitude = presence * (0.88 + 0.04 * sin(now * 0.7))
        }
        for i in regions.indices {
            let modulation = 1 + 0.08 * mid + 0.025 * treble
            regions[i].position += dt * spd * regions[i].velocity * modulation / max(1, perimeterLength)
            regions[i].position -= floor(regions[i].position)
        }
    }

    /// Fills the perimeter table (index i ↔ normalised arc length i / count).
    func fill(_ out: UnsafeMutablePointer<GlowSample>, count: Int) {
        let la = Self.linear(a), lb = Self.linear(b)
        let glowReach = 10 + 18 * settings.glow
        for i in 0..<count {
            let s = Double(i) / Double(count)
            var illumination = 0.0
            var weightedColor = SIMD3<Double>.zero
            for region in regions {
                let distance = abs(s - region.position)
                let wrapped = min(distance, 1 - distance)
                let width = region.width * (1 + 0.12 * bass + 0.08 * beat)
                let weight = region.peak * exp(-0.5 * pow(wrapped / width, 2))
                illumination += weight
                weightedColor += (la + (lb - la) * region.colorMix) * weight
            }
            let crest = min(1, illumination)
            let color = Self.encode(illumination > 1e-8 ? weightedColor / illumination : la)
            let swell = (settings.mode == .musicSync ? 16 + 5 * bass + 3 * beat : 16) * crest
            let width = Double(settings.thickness) * 0.55 + swell
            let localAmp = min(1, amplitude * settings.brightness * (0.012 + 1.3 * illumination))
            out[i] = GlowSample(
                color: SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(localAmp)),
                shape: SIMD4(Float(glowReach * (0.55 + 0.65 * crest)), Float(width),
                             Float(settings.thickness), Float(crest)))
        }
    }

    private static func linear(_ c: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return SIMD3(f(c.x), f(c.y), f(c.z))
    }
    private static func encode(_ c: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ v: Double) -> Double {
            let x = min(1, max(0, v))
            return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return SIMD3(f(c.x), f(c.y), f(c.z))
    }
}

// MARK: - Metal renderer

private struct GlowUniforms {
    var viewSize: SIMD2<Float>     // points
    var fieldSize: SIMD2<Float>    // texels
    var scale: Float               // pixels per point
    var cell: Float                // points per texel
    var count: UInt32              // perimeter samples
    var coreGain: Float
    var haloGain: Float
    var fadeEnd: Float             // distance (pt) at which the glow is fully gone
}

private enum GlowShaderSource {
    static let code = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlowUniforms {
        float2 viewSize;
        float2 fieldSize;
        float  scale;
        float  cell;
        uint   count;
        float  coreGain;
        float  haloGain;
        float  fadeEnd;
    };

    struct GlowSample {
        float4 color;
        float4 shape;
    };

    struct VOut {
        float4 position [[position]];
    };

    constant float2 kQuad[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };

    vertex VOut glow_vertex(uint vid [[vertex_id]]) {
        VOut o;
        o.position = float4(kQuad[vid], 0.0, 1.0);
        return o;
    }

    static float4 field_at(texture2d<float, access::read> f, float2 g, float2 size) {
        g = clamp(g, float2(0.0), size - 1.0);
        float2 i0 = floor(g);
        float2 t = g - i0;
        float2 i1 = min(i0 + 1.0, size - 1.0);
        float4 v00 = f.read(uint2(uint(i0.x), uint(i0.y)));
        float4 v10 = f.read(uint2(uint(i1.x), uint(i0.y)));
        float4 v01 = f.read(uint2(uint(i0.x), uint(i1.y)));
        float4 v11 = f.read(uint2(uint(i1.x), uint(i1.y)));
        return mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
    }

    static float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    fragment float4 glow_fragment(VOut in [[stage_in]],
                                  texture2d<float, access::read> field [[texture(0)]],
                                  constant GlowUniforms& u [[buffer(0)]],
                                  constant GlowSample* samples [[buffer(1)]]) {
        float2 pt = in.position.xy / u.scale;
        float4 f = field_at(field, pt / u.cell, u.fieldSize);
        float d = f.x;
        if (d < -1.0 || d > u.fadeEnd) {
            return float4(0.0);
        }

        float s = atan2(f.z, f.y) / (2.0 * M_PI_F);
        s = s - floor(s);
        float x = s * float(u.count);
        uint i0 = uint(x) % u.count;
        uint i1 = (i0 + 1) % u.count;
        float t = fract(x);
        GlowSample a = samples[i0];
        GlowSample b = samples[i1];
        float4 c = mix(a.color, b.color, t);
        float4 sh = mix(a.shape, b.shape, t);

        float dd = max(d, 0.0);
        // Every light component peaks at the physical border and fades inward.
        // The flat core fills the entire wave, so no dark gap can open at a crest.
        float q = dd / max(sh.y, 0.5);
        float core = exp(-(q * q) * (q * q));
        float edgeQ = dd / max(sh.z, 0.5);
        float edge = exp(-edgeQ * edgeQ);
        float halo = exp(-dd / max(sh.x, 0.5));
        float bloom = exp(-dd / max(4.0, sh.y * 1.2));
        float inside = smoothstep(-1.0, 0.5, d);
        float fade = 1.0 - smoothstep(u.fadeEnd * 0.7, u.fadeEnd, dd);
        float i = (u.coreGain * edge + 0.95 * core
                   + u.haloGain * (0.55 * halo + 0.55 * bloom)) * c.a * inside * fade;
        i += (hash12(in.position.xy) - 0.5) / 255.0 * c.a;
        i = clamp(i, 0.0, 0.84);
        return float4(c.rgb * i, i);                   // retain the saturated reference blue
    }
    """
}

@MainActor
final class GlowRenderer {
    static let sampleCount = 512

    let model: GlowModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var field: MTLTexture?
    private var fieldSize = SIMD2<Float>(1, 1)
    private var fieldCell: Float = 4
    private var wasActive = true

    init(model: GlowModel, device: MTLDevice) throws {
        self.model = model
        self.device = device
        guard let q = device.makeCommandQueue() else {
            throw NSError(domain: "Lilt.Glow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal command queue"])
        }
        queue = q
        let library = try device.makeLibrary(source: GlowShaderSource.code, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "glow_vertex")
        desc.fragmentFunction = library.makeFunction(name: "glow_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let length = MemoryLayout<GlowSample>.stride * Self.sampleCount
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw NSError(domain: "Lilt.Glow", code: 2, userInfo: [NSLocalizedDescriptionKey: "No Metal buffer"])
            }
            buffers.append(b)
        }
    }

    func setField(_ f: GlowField) {
        model.perimeterLength = Double(f.perimeterLength)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: f.width,
                                                         height: f.height, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return }
        f.data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: f.width * 4 * MemoryLayout<Float>.size)
        }
        field = tex
        fieldSize = SIMD2(Float(f.width), Float(f.height))
        fieldCell = Float(f.cell)
    }

    /// Diagnostic only: incremented once per MTKView draw callback (main thread).
    private(set) var framesDrawn = 0

    func draw(in view: MTKView) {
        framesDrawn &+= 1
        model.step(now: CACurrentMediaTime())

        // Throttle when nothing is visible (silence / paused): 10 fps keeps the fade-in responsive.
        let active = model.isActive
        if active != wasActive {
            wasActive = active
            view.preferredFramesPerSecond = active ? (view.window?.screen?.maximumFramesPerSecond ?? 60) : 10
        }

        guard let field,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        inFlight.wait()
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        model.fill(buffer.contents().bindMemory(to: GlowSample.self, capacity: Self.sampleCount),
                   count: Self.sampleCount)

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            inFlight.signal()
            return
        }
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }

        let bounds = view.bounds.size
        let scale = Float(view.drawableSize.width / max(bounds.width, 1))
        encode(enc, buffer: buffer, bounds: bounds, scale: scale, field: field)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func encode(_ enc: MTLRenderCommandEncoder, buffer: MTLBuffer, bounds: CGSize,
                        scale: Float, field: MTLTexture) {
        let glow = Float(model.settings.glow)
        var u = GlowUniforms(viewSize: SIMD2(Float(bounds.width), Float(bounds.height)),
                             fieldSize: fieldSize, scale: scale, cell: fieldCell,
                             count: UInt32(Self.sampleCount), coreGain: 0.65,
                             haloGain: 0.20 + 0.25 * glow, fadeEnd: 150)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<GlowUniforms>.stride, index: 0)
        enc.setFragmentBuffer(buffer, offset: 0, index: 1)
        enc.setFragmentTexture(field, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Uses the same GPU pipeline as the desktop, without opening a window or capturing content.
    func renderFrame(width: Int, height: Int, bounds: CGSize) throws -> Data {
        guard let field else { throw renderError("Missing distance field") }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc), let cmd = queue.makeCommandBuffer() else {
            throw renderError("Could not allocate offscreen target")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw renderError("No encoder") }
        let buffer = buffers[0]
        model.fill(buffer.contents().bindMemory(to: GlowSample.self, capacity: Self.sampleCount), count: Self.sampleCount)
        encode(enc, buffer: buffer, bounds: bounds, scale: Float(width) / Float(bounds.width), field: field)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw error }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return data
    }

    private func renderError(_ message: String) -> NSError {
        NSError(domain: "Lilt.Glow.Render", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Transparent Metal view that never takes mouse or keyboard input.
final class GlowBorderView: MTKView {
    weak var renderer: GlowRenderer?

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

// MARK: - Album colors (Spotify / Apple Music artwork -> 2 dominant colors)

@MainActor
final class GlowAlbumPalette {
    var onColors: ((SIMD3<Double>, SIMD3<Double>) -> Void)?
    private var timer: Timer?
    private var lastKey = ""

    // Compiled once. `with timeout` stops a busy player from stalling the main thread.
    private lazy var spotifyScript = Self.compile("""
        tell application "Spotify"
            with timeout of 1 second
                if player state is playing then return artwork url of current track
            end timeout
        end tell
        return ""
        """)
    private lazy var musicIDScript = Self.compile("""
        tell application "Music"
            with timeout of 1 second
                if player state is playing then return (persistent ID of current track) as text
            end timeout
        end tell
        return ""
        """)
    private lazy var musicArtScript = Self.compile("""
        tell application "Music"
            with timeout of 2 seconds
                return raw data of artwork 1 of current track
            end timeout
        end tell
        """)

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Forget the current track so the next poll re-sends its colours.
    func reset() { lastKey = "" }

    private static func compile(_ source: String) -> NSAppleScript? {
        let s = NSAppleScript(source: source)
        var err: NSDictionary?
        s?.compileAndReturnError(&err)
        return s
    }

    private static func isRunning(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func poll() {
        // Spotify (artwork URL). Needs NSAppleEventsUsageDescription in Info.plist.
        if Self.isRunning("com.spotify.client") {
            var err: NSDictionary?
            if let out = spotifyScript?.executeAndReturnError(&err).stringValue, !out.isEmpty {
                guard out != lastKey, let url = URL(string: out) else { return }
                lastKey = out
                Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                    self?.deliver(data)
                }
                return
            }
        }
        // Apple Music (raw artwork bytes).
        if Self.isRunning("com.apple.Music") {
            var err: NSDictionary?
            guard let id = musicIDScript?.executeAndReturnError(&err).stringValue, !id.isEmpty,
                  "music:" + id != lastKey else { return }
            lastKey = "music:" + id
            var err2: NSDictionary?
            if let data = musicArtScript?.executeAndReturnError(&err2).data, !data.isEmpty {
                deliver(data)
            }
        }
    }

    private func deliver(_ data: Data) {
        Task.detached(priority: .utility) { [weak self] in
            guard let img = NSImage(data: data), let pair = GlowAlbumPalette.dominantColors(img) else { return }
            await MainActor.run { [weak self] in self?.onColors?(pair.0, pair.1) }
        }
    }

    nonisolated static func dominantColors(_ image: NSImage) -> (SIMD3<Double>, SIMD3<Double>)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drew else { return nil }

        // Bucket pixels by hue, weighted by saturation * brightness (ignores greys).
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sum = [SIMD3<Double>](repeating: .zero, count: bins)
        for i in 0..<(size * size) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let bl = Double(pixels[i * 4 + 2]) / 255
            let c = NSColor(red: r, green: g, blue: bl, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: &al)
            let w = Double(s) * Double(v) + 0.001
            let bin = min(bins - 1, Int(Double(h) * Double(bins)))
            weight[bin] += w
            sum[bin] += SIMD3(r, g, bl) * w
        }

        guard let top = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[top] > 0 else { return nil }
        let first = sum[top] / weight[top]

        // Second colour: strongest bin at least 2 bins (60°) away from the first.
        var second: SIMD3<Double>?
        var best = -1
        for i in 0..<bins {
            let d = min(abs(i - top), bins - abs(i - top))
            if d >= 2, (best < 0 || weight[i] > weight[best]) { best = i }
        }
        if best >= 0, weight[best] > weight[top] * 0.12 {
            second = sum[best] / weight[best]
        }

        let a = vivid(first, hueShift: 0)
        let b = second.map { vivid($0, hueShift: 0) } ?? vivid(first, hueShift: 0.4)
        return (a, b)
    }

    /// Lifts dull artwork colours without pushing them to full neon saturation.
    nonisolated private static func vivid(_ rgb: SIMD3<Double>, hueShift: CGFloat) -> SIMD3<Double> {
        let c = NSColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        h = (h + hueShift).truncatingRemainder(dividingBy: 1)
        let out = NSColor(hue: h, saturation: min(0.85, max(s, 0.6)), brightness: max(v, 0.9), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
        out.getRed(&r, green: &g, blue: &bl, alpha: &a)
        return SIMD3(Double(r), Double(g), Double(bl))
    }
}

// MARK: - System audio analysis (ScreenCaptureKit)

struct AudioSnapshot: Sendable {
    var bass = 0.0
    var mid = 0.0
    var treble = 0.0
    var audible = false
    var beatCount = 0
    var timestamp: CFTimeInterval = 0
    var level = 0.0                 // absolute RMS envelope, independent of adaptive band peaks
}

/// Captures the audio of Spotify and Apple Music only (never other apps, never the screen
/// contents) and turns it into normalised bass / mid / treble levels plus beat onsets.
/// Needs Screen Recording permission (System Settings > Privacy & Security). Nothing is stored.
final class SystemAudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case stopped
        case needsPermission
        case waitingForPlayer
        case capturing(String)
        case failed(String)

        var message: String {
            switch self {
            case .stopped: return "Music Sync paused"
            case .needsPermission: return "Needs Screen Recording permission, then relaunch Lilt"
            case .waitingForPlayer: return "Waiting for Spotify or Apple Music"
            case .capturing(let apps): return "Listening to \(apps)"
            case .failed(let why): return "Audio capture unavailable: \(why)"
            }
        }
    }

    static let playerBundleIDs: Set<String> = ["com.spotify.client", "com.apple.Music"]

    var onStatus: (@Sendable (Status) -> Void)?

    private let queue = DispatchQueue(label: "lilt.ambient.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = AudioSnapshot()       // guarded by lock
    private var stream: SCStream?              // guarded by lock
    private var generation = 0                 // guarded by lock
    private var askedForPermission = false     // guarded by lock

    // DSP state – touched only on `queue`.
    private let fftSize = 2048
    private let hop = 512
    private let log2n: vDSP_Length = 11
    private let fftSetup: FFTSetup?
    private var window: [Float]
    private var ring: [Float]
    private var writeIndex = 0
    private var sinceHop = 0
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var prevLow: [Float]
    private var mono: [Float] = []
    private var fluxHistory = [Float](repeating: 0, count: 43)   // ~0.46 s of analysis hops
    private var fluxIndex = 0
    private var peakB: Float = 1e-4, peakM: Float = 1e-4, peakT: Float = 1e-4
    private var avgB: Float = 0
    private var lastBeat: CFTimeInterval = 0
    private var beatCount = 0
    private var sampleRate: Double = 48_000

    override init() {
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
        var hann = [Float](repeating: 0, count: 2048)
        vDSP_hann_window(&hann, vDSP_Length(2048), Int32(vDSP_HANN_NORM))
        window = hann
        ring = [Float](repeating: 0, count: 2048)
        frame = [Float](repeating: 0, count: 2048)
        real = [Float](repeating: 0, count: 1024)
        imag = [Float](repeating: 0, count: 1024)
        mags = [Float](repeating: 0, count: 1024)
        prevLow = [Float](repeating: 0, count: 24)
        super.init()
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func snapshot() -> AudioSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func setStatus(_ s: Status) { onStatus?(s) }

    private func bumpGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func takeStream() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        stream = nil
        return s
    }

    private func publishSilence() {
        lock.lock()
        latest.audible = false
        latest.bass = 0; latest.mid = 0; latest.treble = 0
        latest.level = 0
        latest.timestamp = CACurrentMediaTime()
        lock.unlock()
    }

    /// (Re)starts capture for whichever supported players are running.
    func restart() async {
        let gen = bumpGeneration()
        if let old = takeStream() { try? await old.stopCapture() }
        guard isCurrent(gen) else { return }
        publishSilence()

        if !CGPreflightScreenCaptureAccess() {
            let ask = lock.withLock {
                let ask = !askedForPermission
                askedForPermission = true
                return ask
            }
            if ask { _ = CGRequestScreenCaptureAccess() }   // shows the system prompt once
            guard isCurrent(gen) else { return }
            // Some macOS versions grant access immediately; others require a relaunch.
            guard CGPreflightScreenCaptureAccess() else {
                setStatus(.needsPermission)
                return
            }
        }

        do {
            guard isCurrent(gen) else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isCurrent(gen) else { return }
            let apps = content.applications.filter { Self.playerBundleIDs.contains($0.bundleIdentifier) }
            guard !apps.isEmpty else { setStatus(.waitingForPlayer); return }
            guard let display = content.displays.first else { setStatus(.failed("no display")); return }

            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Video is required by the API but never used: 2×2 px at 1 fps, discarded on arrival.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.showsCursor = false

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            let accepted = lock.withLock {
                guard gen == generation else { return false }
                stream = s
                return true
            }
            guard accepted else { try? await s.stopCapture(); return }
            let names = apps.map { $0.applicationName }.sorted().joined(separator: " + ")
            setStatus(.capturing(names))
        } catch {
            if isCurrent(gen) { setStatus(.failed(error.localizedDescription)) }
        }
    }

    func stop() async {
        let gen = bumpGeneration()
        if let old = takeStream() { try? await old.stopCapture() }
        guard isCurrent(gen) else { return }
        publishSilence()
        setStatus(.stopped)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        guard self.stream === stream else { lock.unlock(); return }
        self.stream = nil
        lock.unlock()
        publishSilence()
        setStatus(.failed(error.localizedDescription))
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }   // video frames are dropped here
        lock.lock()
        let current = self.stream === stream
        lock.unlock()
        guard current else { return }
        process(sampleBuffer)
    }

    // MARK: DSP (runs on `queue`)

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let first = abl.first, first.mData != nil else { return }
            let frames = interleaved
                ? Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                : Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }

            // Down-mix to mono.
            mono.withUnsafeMutableBufferPointer { m in
                let mp = m.baseAddress!
                vDSP_vclr(mp, 1, vDSP_Length(frames))
                if interleaved {
                    let src = first.mData!.assumingMemoryBound(to: Float.self)
                    for c in 0..<channels {
                        vDSP_vadd(src + c, vDSP_Stride(channels), mp, 1, mp, 1, vDSP_Length(frames))
                    }
                    var k = 1 / Float(channels)
                    vDSP_vsmul(mp, 1, &k, mp, 1, vDSP_Length(frames))
                } else {
                    var used = 0
                    for buf in abl {
                        guard let d = buf.mData else { continue }
                        let n = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                        vDSP_vadd(d.assumingMemoryBound(to: Float.self), 1, mp, 1, mp, 1, vDSP_Length(n))
                        used += 1
                    }
                    var k = 1 / Float(max(1, used))
                    vDSP_vsmul(mp, 1, &k, mp, 1, vDSP_Length(frames))
                }
            }

            consumeMono(frames: frames)
        }
    }

    private func consumeMono(frames: Int) {
        for i in 0..<frames {
            ring[writeIndex] = mono[i]
            writeIndex = (writeIndex + 1) & (fftSize - 1)
            sinceHop += 1
            if sinceHop >= hop {
                sinceHop = 0
                analyze()
            }
        }
    }

    /// Offline DSP fixture used only by --selftest; normal Music Sync uses SCStream samples.
    static func validateDSP() {
        for (frequency, band) in [(80.0, 0), (900.0, 1), (6000.0, 2)] {
            let analyzer = SystemAudioAnalyzer()
            analyzer.queue.sync {
                analyzer.mono = (0..<8192).map { Float(0.25 * sin(2 * Double.pi * frequency * Double($0) / 48000)) }
                analyzer.consumeMono(frames: analyzer.mono.count)
            }
            let signal = analyzer.snapshot()
            let bands = [signal.bass, signal.mid, signal.treble]
            fputs("DSP fixture \(frequency) Hz: audible=\(signal.audible), bands=\(bands)\n", stderr)
            // Adaptive peaks retain the initial window's broadband transient, so
            // steady tones need not normalize to 1. Their matching band must dominate.
            precondition(signal.audible && bands[band] > 0.25 && bands[band] == bands.max(),
                         "FFT must detect the \(frequency) Hz fixture in its matching band")
            analyzer.queue.sync {
                analyzer.mono = [Float](repeating: 0, count: 8192)
                analyzer.consumeMono(frames: analyzer.mono.count)
            }
            precondition(!analyzer.snapshot().audible, "Silence must clear the audio snapshot")
        }
    }

    private func analyze() {
        guard let fftSetup else { return }
        let n = fftSize, half = n / 2

        // Oldest-to-newest copy of the ring, RMS, Hann window.
        var rms: Float = 0
        ring.withUnsafeBufferPointer { r in
            frame.withUnsafeMutableBufferPointer { f in
                let head = n - writeIndex
                f.baseAddress!.update(from: r.baseAddress! + writeIndex, count: head)
                (f.baseAddress! + head).update(from: r.baseAddress!, count: writeIndex)
                vDSP_rmsqv(f.baseAddress!, 1, &rms, vDSP_Length(n))
                window.withUnsafeBufferPointer { w in
                    vDSP_vmul(f.baseAddress!, 1, w.baseAddress!, 1, f.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }

        let now = CACurrentMediaTime()
        // Noise floor: below ~-66 dBFS counts as silence (paused, between tracks).
        guard rms > 5e-4 else {
            avgB *= 0.98
            lock.lock()
            latest.audible = false
            latest.bass = 0; latest.mid = 0; latest.treble = 0
            latest.level = 0
            latest.timestamp = now
            lock.unlock()
            return
        }

        // FFT -> magnitude spectrum.
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0   // zrip packs Nyquist here
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        let binHz = sampleRate / Double(n)
        func bin(_ hz: Double) -> Int { min(half - 1, max(1, Int(hz / binHz))) }
        func bandMean(_ lo: Double, _ hi: Double) -> Float {
            let a = bin(lo), b = max(bin(hi), a + 1)
            var m: Float = 0
            mags.withUnsafeBufferPointer { p in vDSP_meanv(p.baseAddress! + a, 1, &m, vDSP_Length(b - a)) }
            return m
        }
        let rb = bandMean(30, 160)
        let rm = bandMean(160, 2_500)
        let rt = bandMean(2_500, 11_000)

        // Adaptive normalisation: running peaks that fall back over ~6 s.
        let decay: Float = 0.9988
        peakB = max(rb, peakB * decay, 1e-4)
        peakM = max(rm, peakM * decay, 1e-4)
        peakT = max(rt, peakT * decay, 1e-4)
        avgB += (rb - avgB) * 0.02
        // Bass relative to its own recent average, so kicks stand out from a steady bass line.
        let nb = pow(min(1, max(0, (rb - 0.5 * avgB) / max(peakB - 0.5 * avgB, 1e-5))), 1.4)
        let nm = pow(min(1, rm / peakM), 1.3)
        let nt = pow(min(1, rt / peakT), 1.3)

        // Onset: positive spectral flux below ~500 Hz against an adaptive threshold.
        let lowBins = min(prevLow.count, bin(500))
        var flux: Float = 0
        for k in 1..<lowBins {
            let d = mags[k] - prevLow[k]
            if d > 0 { flux += d }
            prevLow[k] = mags[k]
        }
        flux /= max(peakB, 1e-5)
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(fluxHistory, 1, nil, 1, &mean, &sd, vDSP_Length(fluxHistory.count))
        fluxHistory[fluxIndex] = flux
        fluxIndex = (fluxIndex + 1) % fluxHistory.count
        if flux > mean + 1.5 * sd + 0.15, nb > 0.25, now - lastBeat > 0.14 {
            lastBeat = now
            beatCount &+= 1
        }

        lock.lock()
        latest = AudioSnapshot(bass: Double(nb), mid: Double(nm), treble: Double(nt),
                               audible: true, beatCount: beatCount, timestamp: now,
                               level: min(1, sqrt(Double(rms) / 0.12)))
        lock.unlock()
    }
}

// MARK: - Window

private final class GlowOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Coordinated click-through lighting and lyrics overlay; desktop rendering is the default.
///
///   let glow = GlowWindow()
///   glow.startMonitoring()      // once at launch; preferences come from UserDefaults
///
/// Lock Screen Effects are off by default. When enabled and the Mac locks, the SAME content tree
/// (Metal glow view + Constellation lyrics host) moves into a separate click-through host window,
/// which is then delegated into the private SkyLight lock-screen Space — the mechanism the original
/// Constellation overlay used. It is re-delegated every time it is ordered in (display wake), and
/// the tree moves back to the desktop panel on unlock. Display sleep and a switched-away session
/// (fast user switching) always hide everything.
@MainActor
final class GlowWindow {
    private let disabled: Bool
    private let lockScreenDisabled: Bool
    private let locationsOverride: DisplayLocations?
    /// Private SkyLight symbols resolved on this macOS build (checked once).
    static let lockLayerAvailable = ExperimentalLockScreenBridge.symbolsAvailable()
    private let delegateLockWindow: @MainActor (NSWindow) throws -> Void
    var onPresentationChanged: ((Bool) -> Void)?

    init(disabled: Bool = false, lockScreenDisabled: Bool = OverlayLaunchOptions.current.lockScreenDisabled,
         locations: DisplayLocations? = nil,
         lockDelegate: (@MainActor (NSWindow) throws -> Void)? = nil) {
        self.disabled = disabled
        self.lockScreenDisabled = lockScreenDisabled
        self.locationsOverride = locations
        self.delegateLockWindow = lockDelegate ?? { try ExperimentalLockScreenBridge.delegate($0) }
    }

    var settings: GlowSettings {
        get { model.settings }
        set { newValue.save(); applySettings() }
    }

    private var panel: NSPanel?
    private var view: GlowBorderView?
    private var renderer: GlowRenderer?
    private var contentContainer: CombinedOverlayContentView?
    private var previewHost: NSHostingView<AnyView>?
    /// Upstream LyricsView (full screen, own black stage) for the lock screen.
    private var lockLyricsHost: NSHostingView<AnyView>?
    /// Transparent Constellation over the desktop, for Desktop / Both.
    private var desktopLyricsHost: NSHostingView<AnyView>?
    private var experimentalPanel: NSPanel?
    private(set) var locations = DisplayLocations()
    /// Set when delegation demonstrably failed during this lock; cleared on unlock (no retry loop).
    private var lockDelegationFailed = false
    private var telemetryTask: Task<Void, Never>?
    private var lastFrameCount = 0
    private var lastDesktopDecision: OverlayDecision?
    private var lastScreenName: String?
    /// Tests only: pretend a given screen choice / an external monitor.
    var screenChoiceOverride: String?
    var ambienceOverride: Bool?
    /// Black idle stage while locked and music is playing; input reveals the lock screen.
    private var musicPlaying = false
    private var stageTimer: Timer?
    /// Only input AFTER this moment (+ grace) counts as "show me the login screen". Set when the
    /// Mac locks and when Lilt itself wakes the display, never when the user wakes it.
    private var inputBaseline = Date.distantPast
    /// Lilt wakes the display at most once per lock (after an idle auto-lock turned it off).
    private var wokeDisplayThisLock = false
    private var systemSleeping = false
    private var wakeTask: Task<Void, Never>?
    /// Seconds without input before the revealed lock screen goes black again.
    static let revealSeconds = 10.0
    private var pendingAudioRecovery = false
    private let model = GlowModel()
    private let audio = SystemAudioAnalyzer()
    private let palette = GlowAlbumPalette()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false
    private var isLocked = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var isShown = false
    /// True while the lock-screen host is ordered in (for the optional display-awake assertion).
    private(set) var isLockScreenPresented = false
    private var audioRunning = false
    private var geometryKey: String?
    private var geometryTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var hasAlbumColors = false

    // MARK: Lifecycle

    func startMonitoring(settings initialSettings: GlowSettings? = nil) {
        guard !disabled, !started else { return }
        started = true
        model.settings = initialSettings ?? GlowSettings.load()
        model.audioSource = { [audio] in audio.snapshot() }
        model.useDefaultColors()

        audio.onStatus = { [weak self] status in
            Task { @MainActor in self?.handleAudioStatus(status) }
        }
        palette.onColors = { [weak self] a, b in
            guard let self, self.model.settings.useAlbumColors else { return }
            self.hasAlbumColors = true
            self.model.setTargetColors(a, b)
        }

        let dnc = DistributedNotificationCenter.default()
        observe(dnc, "com.apple.screenIsLocked") {
            LifecycleLog.note("event: com.apple.screenIsLocked (\(SessionState.current()))")
            $0.setSessionLocked(true)
        }
        observe(dnc, "com.apple.screenIsUnlocked") {
            LifecycleLog.note("event: com.apple.screenIsUnlocked (\(SessionState.current()))")
            $0.setSessionLocked(false)
        }

        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.screensDidSleepNotification.rawValue) {
            LifecycleLog.note("event: screensDidSleep")
            $0.setScreensAsleep(true)
        }
        observe(ws, NSWorkspace.screensDidWakeNotification.rawValue) {
            LifecycleLog.note("event: screensDidWake (\(SessionState.current()))")
            $0.setScreensAsleep(false); $0.restartAudioIfRunning()
        }
        observe(ws, NSWorkspace.willSleepNotification.rawValue) {
            LifecycleLog.note("event: system willSleep")
            $0.setSystemSleeping(true)
        }
        observe(ws, NSWorkspace.didWakeNotification.rawValue) {
            LifecycleLog.note("event: system didWake")
            $0.setSystemSleeping(false)
        }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification.rawValue) {
            // Only a real switch away (fast user switching) takes us off the console. If the window
            // server says we are still on the console and merely locked, keep the lock effects.
            let state = SessionState.current()
            let switchedAway = !(state.onConsole && state.screenLocked)
            LifecycleLog.note("event: sessionDidResignActive (\(state)) -> treatedAsSwitchedAway=\(switchedAway)")
            $0.setSessionInactive(switchedAway)
        }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) {
            LifecycleLog.note("event: sessionDidBecomeActive (\(SessionState.current()))")
            $0.setSessionInactive(false)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, SystemAudioAnalyzer.playerBundleIDs.contains(id) else { return }
                MainActor.assumeIsolated {
                    self?.palette.reset()
                    self?.restartAudioIfRunning()
                }
            }
            observers.append((ws, token))
        }

        let nc = NotificationCenter.default
        observe(nc, NSApplication.didBecomeActiveNotification.rawValue) { $0.restartAudioIfRunning() }
        observe(nc, NSApplication.didChangeScreenParametersNotification.rawValue) {
            LifecycleLog.note("event: screens changed -> \(NSScreen.screens.count) screen(s); target=\($0.targetScreen()?.localizedName ?? "none")")
            $0.updateGeometry(); $0.refresh()
        }
        if initialSettings == nil {
            observe(nc, UserDefaults.didChangeNotification.rawValue) {
                $0.readLocations(); $0.applySettings(); $0.refresh()
            }
        }

        readLocations()
        LifecycleLog.note("glow: monitoring started; lyrics=\(locations.lyrics.rawValue) lighting=\(locations.lighting.rawValue) "
            + "lockLayerAvailable=\(Self.lockLayerAvailable) lockDisabledAtLaunch=\(lockScreenDisabled) mode=\(model.settings.mode.rawValue) "
            + "enabled=\(model.settings.enabled) session(\(SessionState.current())) "
            + "skylightSymbols=\(ExperimentalLockScreenBridge.symbolsAvailable()) "
            + "bundle=\(Bundle.main.bundlePath)")
    }

    func stopMonitoring() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        started = false
        hide()
        restoreDesktopHost()
    }

    // MARK: Show / hide

    /// Lyrics are available (loaded + playing) when non-nil. Where they appear is decided by the
    /// policy from the Display Location setting, never by the caller.
    func setLyricsContent(lock: AnyView?, desktop: AnyView?) {
        guard !disabled else { return }
        if (lock != nil) != (lockLyricsHost != nil) {
            LifecycleLog.note("lyrics: content \(lock != nil ? "available" : "removed") (locked=\(isLocked))")
        }
        func update(_ host: inout NSHostingView<AnyView>?, _ content: AnyView?) {
            if let content {
                if let host { host.rootView = content } else { host = NSHostingView(rootView: content) }
            } else {
                host?.removeFromSuperview()
                host = nil
            }
        }
        update(&lockLyricsHost, lock)
        update(&desktopLyricsHost, desktop)
        refresh()
    }

    func setSessionLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked {
            inputBaseline = Date()
            wokeDisplayThisLock = false
        } else {
            wakeTask?.cancel()
        }
        LifecycleLog.note("state: locked=\(locked) lyrics=\(locations.lyrics.rawValue) lighting=\(locations.lighting.rawValue) asleep=\(screensAsleep) "
            + "inactive=\(sessionInactive) lyricsAvailable=\(lockLyricsHost != nil) audioRunning=\(audioRunning)")
        if !locked {
            restoreDesktopHost()
            lockDelegationFailed = false
            updateLockStatusMessage()
        }
        refresh()
        if locked { wakeForLyricsIfNeeded() }
        if !locked && pendingAudioRecovery {
            pendingAudioRecovery = false
            restartAudioIfRunning()
        }
    }

    func setScreensAsleep(_ asleep: Bool) {
        guard asleep != screensAsleep else { return }
        screensAsleep = asleep
        if !asleep { wakeTask?.cancel() }
        refresh()
        wakeForLyricsIfNeeded()
    }

    func setSystemSleeping(_ sleeping: Bool) {
        systemSleeping = sleeping
        if sleeping { wakeTask?.cancel() }
    }

    /// When the Mac locks itself after idle, macOS turns the display off first. While music plays
    /// and Lock Screen Effects is on, turn it back on ONCE so the lyrics screen is visible (the
    /// display-awake assertion then keeps it on while music plays). Never with the lid closed,
    /// never during system sleep, never more than once per lock — a second display sleep is the
    /// user's choice and is respected.
    private func wakeForLyricsIfNeeded() {
        let wantsLock = locations.lyrics.onLockScreen
            || (locations.lighting.onLockScreen && model.settings.enabled && model.settings.mode != .none)
        guard isLocked, screensAsleep, wantsLock, lockSupported, musicPlaying,
              !wokeDisplayThisLock, !systemSleeping else { return }
        wokeDisplayThisLock = true
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))   // let lock / system-sleep notifications land first
            guard !Task.isCancelled, let self, self.isLocked, self.screensAsleep, !self.systemSleeping else { return }
            if DisplayWaker.lidClosed(), self.targetScreen().map(TargetScreen.isBuiltIn) ?? true {
                LifecycleLog.note("wake: skipped, lid closed")
                return
            }
            self.inputBaseline = Date()
            let ok = DisplayWaker.wake()
            LifecycleLog.note("wake: display turned on for lock-screen lyrics (success=\(ok))")
        }
    }

    func setSessionInactive(_ inactive: Bool) {
        guard inactive != sessionInactive else { return }
        sessionInactive = inactive
        refresh()
    }

    private func readLocations() {
        setLocations(locationsOverride ?? DisplayLocations.load())
    }

    func setLocations(_ new: DisplayLocations) {
        guard new != locations || !started else { updateLockStatusMessage(); return }
        if new != locations {
            LifecycleLog.note("settings: lyrics=\(new.lyrics.rawValue) lighting=\(new.lighting.rawValue)")
        }
        locations = new
        updateLockStatusMessage()
        refresh()
    }

    /// Lock-screen layer usable for this lock.
    private var lockSupported: Bool {
        !disabled && !lockScreenDisabled && Self.lockLayerAvailable && !lockDelegationFailed
    }

    private func updateLockStatusMessage() {
        guard !isLocked else { return }
        let wanted = locations.lyrics.onLockScreen || locations.lighting.onLockScreen
        LockScreenEffectsStatus.shared.message =
            lockScreenDisabled ? "Lock screen disabled by launch option"
            : !Self.lockLayerAvailable ? "Lock screen unavailable on this macOS (SkyLight symbols missing)"
            : wanted ? "Lock screen: ready for the next lock (experimental private API)"
            : "Lock screen: nothing selected"
    }

    private func installCurrentLyrics() {
        guard let contentContainer, let view else { return }
        let d = decision
        let ambience = !isLocked && desktopAmbience && previewHost == nil
        let onStage = isLocked || ambience
        let host = !d.lyrics ? nil : onStage ? lockLyricsHost : (previewHost ?? desktopLyricsHost)
        contentContainer.installLyrics(host, below: view, onStage: onStage)
    }

    func setPreviewContent(_ content: AnyView?) {
        guard !disabled else { return }
        if let content {
            if let previewHost { previewHost.rootView = content }
            else { previewHost = NSHostingView(rootView: content) }
        } else {
            previewHost?.removeFromSuperview()
            previewHost = nil
        }
        installCurrentLyrics()
        refresh()
    }

    func show() {
        guard !disabled, let screen = targetScreen() else { return }
        let d = decision
        guard d.visible else { hide(); return }
        if panel == nil { buildPanel(on: screen) }
        guard let panel, let view else { return }
        panel.setFrame(screen.frame, display: false)
        let ambientVisible = d.glow     // lighting location + switch; lyrics are independent
        view.isPaused = !ambientVisible
        view.isHidden = !ambientVisible

        if isLocked {
            let host = lockHost(on: screen)
            installCurrentLyrics()
            updateGeometry()
            // Like upstream OverlayWindow.show: only order in + delegate when not already visible.
            // That still covers display wake (the host was ordered out), where ordering it back in
            // puts it in the ordinary Space behind the lock shield until it is delegated again.
            if !host.isVisible { do {
                host.orderFrontRegardless()   // gives it a window-server number
                try delegateLockWindow(host)
            } catch {
                lockDelegationFailed = true
                LifecycleLog.note("lock: delegation FAILED: \(error.localizedDescription) -> removing lock host until unlock")
                LockScreenEffectsStatus.shared.message = "Lock-screen host failed: \(error.localizedDescription)"
                restoreDesktopHost()
                hide()
                return
            } }
            if isLockScreenPresented { updateStage(animated: true) }
            if !isLockScreenPresented {
                isLockScreenPresented = true
                let lyricsAttached = lockLyricsHost?.isDescendant(of: view.superview ?? view) ?? false
                LifecycleLog.note("lock: host shown on \"\(screen.localizedName)\" \(WindowDiagnostics.describe(host)) glowVisible=\(ambientVisible) "
                    + "metalAttached=\(view.window === host) lyricsAttached=\(lyricsAttached) decision(\(d))")
                LockScreenEffectsStatus.shared.message = "Lock host delegated · check the log to confirm frames"
                startTelemetry()
                updateStage(animated: false)
            }
        } else {
            restoreDesktopHost()
            installCurrentLyrics()
            updateGeometry()
            panel.orderFrontRegardless()
            if !isShown || d != lastDesktopDecision || screen.localizedName != lastScreenName {
                LifecycleLog.note("desktop: panel shown on \"\(screen.localizedName)\" builtIn=\(TargetScreen.isBuiltIn(screen)) "
                    + "ambience=\(desktopAmbience) \(WindowDiagnostics.describe(panel)) decision(\(d))")
            }
            lastDesktopDecision = d
            lastScreenName = screen.localizedName
            isShown = true
            updateStage(animated: true)
        }
        isShown = true
        updateServices()
        onPresentationChanged?(true)
    }

    func hide() {
        if isShown || isLockScreenPresented {
            LifecycleLog.note("overlay: hidden (locked=\(isLocked) asleep=\(screensAsleep) inactive=\(sessionInactive) "
                + "lyrics=\(locations.lyrics.rawValue) lighting=\(locations.lighting.rawValue) delegationFailed=\(lockDelegationFailed))")
        }
        isShown = false
        isLockScreenPresented = false
        lastDesktopDecision = nil
        stopTelemetry()
        updateStage(animated: false)
        view?.isPaused = true
        panel?.orderOut(nil)
        experimentalPanel?.orderOut(nil)
        updateServices()
        onPresentationChanged?(false)
    }

    // MARK: State

    private var policyInputs: OverlayPresentationPolicy.Inputs {
        let s = model.settings
        return OverlayPresentationPolicy.Inputs(disabled: disabled, started: started, locked: isLocked,
            screensAsleep: screensAsleep, sessionInactive: sessionInactive, lockSupported: lockSupported,
            locations: locations, ambientEnabled: s.enabled && s.mode != .none,
            lyricsAvailable: lockLyricsHost != nil, previewRequested: previewHost != nil)
    }

    /// Current visibility, from the central policy.
    var decision: OverlayDecision { OverlayPresentationPolicy.decide(policyInputs) }

    private func refresh() {
        if decision.visible { show() } else { hide() }
    }

    /// Creates (once per lock) the click-through host and moves the shared content tree into it.
    private func lockHost(on screen: NSScreen) -> NSPanel {
        if let experimentalPanel {
            experimentalPanel.setFrame(screen.frame, display: false)
            return experimentalPanel
        }
        let host = GlowOverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.ignoresMouseEvents = true      // clicks and typing go to the lock screen, never here
        host.hidesOnDeactivate = false
        host.isReleasedWhenClosed = false
        host.becomesKeyOnlyIfNeeded = true
        host.animationBehavior = .none
        host.canBecomeVisibleWithoutLogin = true
        // Same level the original, working Constellation lock overlay used. Inside the private
        // Space it only orders our own windows; the Space's absolute level is what lifts it.
        // This window exists only while locked, so it never affects the desktop.
        host.level = .screenSaver
        host.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel?.orderOut(nil)
        panel?.contentView = nil
        host.contentView = contentContainer
        experimentalPanel = host
        LifecycleLog.note("lock: host created; content tree moved (metal + lyrics container)")
        return host
    }

    /// Called by AppModel with the player state.
    func setMusicPlaying(_ playing: Bool) {
        guard playing != musicPlaying else { return }
        musicPlaying = playing
        LifecycleLog.note("player: music \(playing ? "playing" : "paused/stopped")")
        updateStage(animated: true)
        updateServices()
    }

    var lockStageVisible: Bool { contentContainer?.stageVisible ?? false }
    var lockLyricsShowing: Bool { contentContainer?.lyricsShowing(lockLyricsHost) ?? false }

    /// Black while idle; any key / mouse / trackpad input reveals the wallpaper and login UI,
    /// and it returns to black after `revealSeconds` without input.
    private func updateStage(animated: Bool) {
        guard let contentContainer else { return }
        // Ambience monitor (unlocked): the black lyrics screen stays up while lyrics show; your
        // typing on the laptop must not hide it.
        if !isLocked {
            stopStageTimer()
            let ambience = isShown && desktopAmbience && previewHost == nil && decision.lyrics
            contentContainer.setStageVisible(ambience, animated: animated)
            return
        }
        // Lock screen: the black lyrics screen exists only while lock-screen lyrics are shown.
        guard isLockScreenPresented, decision.lyrics else {
            stopStageTimer()
            contentContainer.setStageVisible(false, animated: animated)
            return
        }
        let idle = UserActivity.secondsSinceLastInput()
        // Input counts only if it happened after the lock (or Lilt's own display wake) plus a short
        // grace for releasing Control-Command-Q. A key press that wakes a sleeping display counts,
        // so pressing space on a dark screen goes straight to the login screen.
        let lastInput = Date().addingTimeInterval(-idle)
        let freshInput = lastInput > inputBaseline.addingTimeInterval(1.5)
        let black = !freshInput || idle >= Self.revealSeconds
        if black != contentContainer.stageVisible {
            LifecycleLog.note(String(format: "stage: %@ (idle %.1fs)", black ? "black" : "revealed by input", idle))
        }
        contentContainer.setStageVisible(black, animated: animated)
        if stageTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStage(animated: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            stageTimer = timer
        }
    }

    private func stopStageTimer() {
        stageTimer?.invalidate()
        stageTimer = nil
    }

    private func startTelemetry() {
        stopTelemetry()
        lastFrameCount = renderer?.framesDrawn ?? 0
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.logLockTelemetry()
            }
        }
    }

    private func stopTelemetry() {
        telemetryTask?.cancel()
        telemetryTask = nil
    }

    private func logLockTelemetry() {
        guard isLocked, let host = experimentalPanel else { return }
        let frames = renderer?.framesDrawn ?? 0
        let fps = Double(frames - lastFrameCount) / 5
        lastFrameCount = frames
        let snap = audio.snapshot()
        let age = snap.timestamp > 0 ? CACurrentMediaTime() - snap.timestamp : -1
        let audioState: String
        if !audioRunning { audioState = "notRunning" }
        else if age < 0 { audioState = "noSamplesYet" }
        else if age < 0.5 { audioState = snap.audible ? "fresh+audible" : "fresh+silent" }
        else { audioState = String(format: "stale(%.1fs)", age) }
        let lyricsAttached = contentContainer.map { lockLyricsHost?.isDescendant(of: $0) ?? false } ?? false
        let lyricsShowing = contentContainer?.lyricsShowing(lockLyricsHost) ?? false
        LifecycleLog.note(String(format: "lock: tick fps=%.1f ", fps) + "paused=\(view?.isPaused ?? true) audio=\(audioState) "
            + "lyricsAttached=\(lyricsAttached) lyricsShowing=\(lyricsShowing) \(WindowDiagnostics.describe(host)) session(\(SessionState.current()))")
        let summary = fps < 1 ? "Glow not drawing" : String(format: "Glow drawing %.0f fps", fps)
        LockScreenEffectsStatus.shared.message = "\(summary) · audio \(audioState) · visibility needs your eyes"
    }

    private func restoreDesktopHost() {
        guard let experimentalPanel else { return }
        stopTelemetry()
        experimentalPanel.orderOut(nil)
        experimentalPanel.contentView = nil
        panel?.contentView = contentContainer
        experimentalPanel.close()
        self.experimentalPanel = nil
        isLockScreenPresented = false
        updateStage(animated: false)
        LifecycleLog.note("lock: host destroyed; content tree returned to desktop panel")
    }

    private func applySettings() {
        let new = GlowSettings.load()
        let old = model.settings
        guard new != old else { return }
        model.settings = new

        if !new.useAlbumColors || !hasAlbumColors { model.useDefaultColors() }
        if new.useAlbumColors && !old.useAlbumColors { palette.reset() }
        if new.followNotch != old.followNotch { updateGeometry() }
        refresh()
    }

    /// Starts/stops audio capture and artwork polling to match what is on screen.
    /// A stream that is already running is left alone across lock/unlock (no restart).
    private func updateServices() {
        let musicSync = model.settings.enabled && model.settings.mode == .musicSync
        let glowOnScreen = isShown && decision.glow
        let prewarm = OverlayPresentationPolicy.prewarmAudio(policyInputs, musicSync: musicSync, musicPlaying: musicPlaying)
        let wantAudio = musicSync && (glowOnScreen || prewarm)
        if wantAudio != audioRunning {
            audioRunning = wantAudio
            retryTask?.cancel()
            LifecycleLog.note("audio: \(wantAudio ? "start" : "stop") requested (locked=\(isLocked) "
                + "glowOnScreen=\(glowOnScreen) prewarmForLock=\(prewarm))")
            Task { [weak self, audio] in
                if wantAudio {
                    guard let self, self.audioRunning else { return }
                    await audio.restart()
                } else { await audio.stop() }
            }
        }
        if !wantAudio {
            AmbientLightingStatus.shared.message = !model.settings.enabled ? "Off"
                : (model.settings.mode == .idle ? "Idle animation" : "Hidden")
        }
        if (glowOnScreen || prewarm) && model.settings.useAlbumColors { palette.start() } else { palette.stop() }
    }

    /// Restarts a running capture (player launched/quit, display woke). While locked a healthy
    /// stream is NOT torn down; recovery waits for unlock unless the stream itself fails.
    private func restartAudioIfRunning() {
        guard audioRunning else { return }
        guard !isLocked else { pendingAudioRecovery = true; return }
        retryTask?.cancel()
        Task { [weak self, audio] in
            guard let self, self.audioRunning else { return }
            await audio.restart()
        }
    }

    private func handleAudioStatus(_ status: SystemAudioAnalyzer.Status) {
        guard audioRunning else { return }
        LifecycleLog.note("audio: status \"\(status.message)\" (locked=\(isLocked))")
        AmbientLightingStatus.shared.message = status.message
        // Capture can stop on its own (system interruption, lock). Try again a few seconds later,
        // also while locked; the lighting fades out meanwhile instead of faking activity.
        let shouldRetry: Bool
        switch status {
        case .failed, .needsPermission, .waitingForPlayer: shouldRetry = true
        default: shouldRetry = false
        }
        if shouldRetry, audioRunning {
            retryTask?.cancel()
            let delay: UInt64 = isLocked ? 10_000_000_000 : 5_000_000_000
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.audioRunning else { return }
                LifecycleLog.note("audio: retrying capture (locked=\(self.isLocked))")
                await self.audio.restart()
            }
        }
    }

    // MARK: Helpers

    private func observe(_ center: NotificationCenter, _ name: String,
                         _ handler: @escaping @MainActor @Sendable (GlowWindow) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// Prefer the built-in display (the one with the notch).
    /// The display chosen in Display Location → Screen (falls back to the built-in display).
    func targetScreen() -> NSScreen? {
        TargetScreen.resolve(screenChoiceOverride ?? TargetScreen.currentChoice)
    }

    /// Unlocked lyrics on an external monitor become a full black "ambience" screen; on the
    /// built-in display they stay a transparent overlay over your apps.
    private var desktopAmbience: Bool {
        if let ambienceOverride { return ambienceOverride }
        guard let screen = targetScreen() else { return false }
        return !TargetScreen.isBuiltIn(screen)
    }

    private func buildPanel(on screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            AmbientLightingStatus.shared.message = "Metal is not available on this Mac"
            return
        }
        let renderer: GlowRenderer
        do {
            renderer = try GlowRenderer(model: model, device: device)
        } catch {
            AmbientLightingStatus.shared.message = "Lighting renderer failed: \(error.localizedDescription)"
            NSLog("Lilt ambient lighting: renderer failed: \(error)")
            return
        }

        let window = GlowOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.canBecomeVisibleWithoutLogin = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.animationBehavior = .none
        // Above app windows and the menu bar, below menus, alerts and every secure
        // lock-screen / login window. Never use shielding levels here.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let v = GlowBorderView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.preferredFramesPerSecond = screen.maximumFramesPerSecond
        v.enableSetNeedsDisplay = false
        v.isPaused = true
        v.wantsLayer = true
        v.layer?.isOpaque = false
        v.autoresizingMask = [.width, .height]
        v.renderer = renderer

        let container = CombinedOverlayContentView(frame: v.frame)
        container.autoresizingMask = [.width, .height]
        container.addSubview(v)
        container.installLyrics(previewHost, below: v)
        window.contentView = container
        contentContainer = container
        panel = window
        view = v
        self.renderer = renderer
    }

    /// Read-only state for the unlocked window smoke test; never delegates a secure Space.
    var presentationSnapshot: (window: NSPanel?, metal: GlowBorderView?, hasLyrics: Bool, audioRunning: Bool) {
        let lyricsHost = isLocked ? lockLyricsHost : (previewHost ?? desktopLyricsHost)
        let attached = contentContainer.map { lyricsHost?.isDescendant(of: $0) ?? false } ?? false
        return (experimentalPanel ?? panel, view, attached, audioRunning)
    }

    /// Rebuilds the distance field only when the screen size or notch geometry changes.
    private func updateGeometry() {
        guard let screen = targetScreen() else { return }
        if let panel, panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        let size = screen.frame.size
        let notch = model.settings.followNotch ? NotchMetrics.forScreen(screen) : nil
        let key = "\(size.width)x\(size.height)|\(notch.map { "\($0.left),\($0.right),\($0.height)" } ?? "-")"
        guard key != geometryKey, renderer != nil else { return }
        geometryKey = key
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            let field = await Task.detached(priority: .userInitiated) {
                GlowField.build(size: size, notch: notch)
            }.value
            guard !Task.isCancelled else { return }
            self?.renderer?.setField(field)
        }
    }
}
