// Renders the DevDash app icon to macos/Resources/AppIcon.icns.
// Usage: swift macos/scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws on a 1024pt canvas following the macOS icon grid (824pt body, 100pt margin).
func draw(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0E1420))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x243049), color(0x0B1019)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft accent glow in the upper left.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x4F8CFF, 0.35), color(0x4F8CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 760), startRadius: 0, endCenter: CGPoint(x: 330, y: 760), endRadius: 520, options: [])
    ctx.restoreGState()

    // Inner hairline.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Three rack units, each with a status light and activity bars.
    let statuses: [UInt32] = [0x34D399, 0x34D399, 0xFBBF24]
    let loads: [[CGFloat]] = [[0.55, 0.8, 0.4, 0.7], [0.3, 0.5, 0.9, 0.6], [0.75, 0.45, 0.6, 0.35]]
    let unitWidth: CGFloat = 560, unitHeight: CGFloat = 148, gap: CGFloat = 40
    let totalHeight = unitHeight * 3 + gap * 2
    for index in 0..<3 {
        let y = 512 + totalHeight / 2 - unitHeight - CGFloat(index) * (unitHeight + gap)
        let unit = CGRect(x: 512 - unitWidth / 2, y: y, width: unitWidth, height: unitHeight)
        let unitPath = CGPath(roundedRect: unit, cornerWidth: 38, cornerHeight: 38, transform: nil)

        ctx.saveGState()
        ctx.addPath(unitPath)
        ctx.clip()
        let face = CGGradient(colorsSpace: space, colors: [color(0x3A4863), color(0x263146)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(face, start: CGPoint(x: 0, y: unit.maxY), end: CGPoint(x: 0, y: unit.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(unitPath)
        ctx.setStrokeColor(color(0xFFFFFF, 0.12))
        ctx.setLineWidth(3)
        ctx.strokePath()

        // Status light with glow.
        let light = CGPoint(x: unit.minX + 78, y: unit.midY)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: color(statuses[index], 0.9))
        ctx.setFillColor(color(statuses[index]))
        ctx.fillEllipse(in: CGRect(x: light.x - 24, y: light.y - 24, width: 48, height: 48))
        ctx.restoreGState()

        // Activity meters.
        let barX = unit.minX + 150
        let barWidth: CGFloat = 70, barGap: CGFloat = 24, maxBar: CGFloat = 84
        for (bar, load) in loads[index].enumerated() {
            let height = max(16, maxBar * load)
            let rect = CGRect(x: barX + CGFloat(bar) * (barWidth + barGap), y: unit.midY - maxBar / 2, width: barWidth, height: height)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.setFillColor(color(0x7FA8FF, 0.35 + 0.5 * load))
            ctx.fillPath()
        }
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high
    draw(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try render(pixels: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
