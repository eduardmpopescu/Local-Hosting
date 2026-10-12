// Renders AppIcon.icns: run `swift Resources/make-icon.swift <output.icns>`.
// Everything is drawn from plain shapes: a blue tile with a white three-unit server rack.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func withShadow(_ shadowColor: NSColor, blur: CGFloat, offsetY: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offsetY)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Tile: the standard macOS icon footprint with a soft drop shadow.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let w = tile.width
    let tilePath = roundedRect(tile, w * 0.225)
    withShadow(color(0x000000, 0.3), blur: s * 0.025, offsetY: -s * 0.01) {
        color(0x2B44B8).setFill()
        tilePath.fill()
    }
    NSGradient(colors: [color(0x5C7DFA), color(0x3553D6), color(0x1F3192)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tilePath, angle: -90)
    // A faint sheen across the top half.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: w, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The rack: three units stacked, centred on the tile.
    let unitWidth = w * 0.62
    let unitHeight = w * 0.155
    let gap = w * 0.045
    let corner = w * 0.04
    let rackHeight = unitHeight * 3 + gap * 2
    let left = tile.midX - unitWidth / 2
    let bottom = tile.midY - rackHeight / 2

    for i in 0..<3 {
        let y = bottom + CGFloat(2 - i) * (unitHeight + gap)
        let unit = NSRect(x: left, y: y, width: unitWidth, height: unitHeight)
        let unitPath = roundedRect(unit, corner)

        withShadow(color(0x0B1650, 0.45), blur: w * 0.03, offsetY: -w * 0.012) {
            color(0xFFFFFF).setFill()
            unitPath.fill()
        }
        NSGradient(colors: [color(0xFFFFFF), color(0xE4EAFF)])!.draw(in: unitPath, angle: -90)

        // Vent slot on the left.
        let slotHeight = w * 0.026
        let slot = NSRect(x: unit.minX + w * 0.065, y: unit.midY - slotHeight / 2, width: w * 0.2, height: slotHeight)
        color(0x2B44B8, 0.32).setFill()
        roundedRect(slot, slotHeight / 2).fill()

        // Status light on the right: the top unit is "running".
        let dot = w * 0.05
        let light = NSRect(x: unit.maxX - w * 0.065 - dot, y: unit.midY - dot / 2, width: dot, height: dot)
        (i == 0 ? color(0x2FBF7A) : color(0x3553D6)).setFill()
        NSBezierPath(ovalIn: light).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
exit(task.terminationStatus)
