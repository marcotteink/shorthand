// Renders the Shorthand app icon: white bolt on a teal-to-blue gradient squircle.
// Usage: swift make_icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let canvas: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Standard macOS icon grid: 824pt squircle centered on a 1024pt transparent canvas
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185, yRadius: 185
)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.04, green: 0.33, blue: 0.82, alpha: 1.0),  // deep blue (bottom)
    NSColor(calibratedRed: 0.11, green: 0.75, blue: 0.87, alpha: 1.0)   // teal (top)
])!
gradient.draw(in: squircle, angle: 90)

// White bolt, tinted from the SF Symbol so it matches the menu bar icon
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let boltSize = bolt.size
    let tinted = NSImage(size: boltSize)
    tinted.lockFocus()
    bolt.draw(in: NSRect(origin: .zero, size: boltSize))
    NSColor.white.set()
    NSRect(origin: .zero, size: boltSize).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 30
    shadow.set()

    tinted.draw(
        in: NSRect(
            x: (canvas - boltSize.width) / 2,
            y: (canvas - boltSize.height) / 2,
            width: boltSize.width,
            height: boltSize.height
        ),
        from: .zero, operation: .sourceOver, fraction: 1.0
    )
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
