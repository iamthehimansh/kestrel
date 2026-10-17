// Draws Kestrel's app icon (1024x1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-square body on the macOS icon grid (824 px with a 100 px inset), warm gradient.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.16, alpha: 1),
                    NSColor(calibratedRed: 0.62, green: 0.13, blue: 0.29, alpha: 1)])!.draw(in: shape, angle: -60)

// White game controller symbol in the middle.
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2 - 10,
                           width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: out))
print(out)
