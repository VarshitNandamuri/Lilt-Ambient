import AppKit
import Metal

/// Lilt --glow-render directory [seconds=17.5] [fps=8] [width=954] [height=624] [notch]
/// Deterministic Idle animation, rendered through the production Metal shader. No permissions needed.
@MainActor
func renderGlowSequence(arguments: [String]) throws {
    guard let path = arguments.first, let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "Lilt.Glow.Render", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Supply an output directory; a Metal GPU is required"])
    }
    let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 17.5 : 17.5
    let fps = arguments.count > 2 ? Double(arguments[2]) ?? 8 : 8
    let width = arguments.count > 3 ? Int(arguments[3]) ?? 954 : 954
    let height = arguments.count > 4 ? Int(arguments[4]) ?? 624 : 624
    guard seconds > 0, seconds <= 120, fps > 0, fps <= 120, width >= 64, height >= 64,
          width <= 4096, height <= 4096 else {
        throw NSError(domain: "Lilt.Glow.Render", code: 2)
    }
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let bounds = CGSize(width: 1470, height: Double(height) * 1470 / Double(width))
    let notch = arguments.contains("notch") ? NotchMetrics(left: 646, right: 824, height: 32) : nil
    let model = GlowModel()
    model.settings.mode = .idle
    model.useDefaultColors()
    // Fixed warm-up and 120 Hz simulation make exports independent of render speed/fps.
    var tick = 0
    func advance(to time: Double) {
        while Double(tick) / 120 <= time {
            model.step(now: 1 + Double(tick) / 120)
            tick += 1
        }
    }
    advance(to: 3)
    let renderer = try GlowRenderer(model: model, device: device)
    renderer.setField(GlowField.build(size: bounds, notch: notch))
    for index in 0..<Int((seconds * fps).rounded(.up)) {
        advance(to: 3 + Double(index) / fps)
        let bgra = try renderer.renderFrame(width: width, height: height, bounds: bounds)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        // Preserve premultiplied alpha for correct compositing in exported PNGs.
        bgra.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            let dst = rep.bitmapData!
            for p in stride(from: 0, to: bgra.count, by: 4) {
                dst[p] = src[p + 2]; dst[p + 1] = src[p + 1]
                dst[p + 2] = src[p]; dst[p + 3] = src[p + 3]
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Lilt.Glow.Render", code: 3)
        }
        try png.write(to: output.appendingPathComponent(String(format: "frame-%03d.png", index + 1)))
    }
    print("Rendered \(Int((seconds * fps).rounded(.up))) frames to \(path)")
}
