import AppKit

/// Original scalable scenery; no downloaded or third-party artwork.
final class PlayerBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let sky = NSGradient(colors: [
            NSColor(srgbRed: 0.07, green: 0.09, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.17, green: 0.16, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 0.46, green: 0.28, blue: 0.35, alpha: 1)
        ])!
        sky.draw(in: bounds, angle: 270)
        NSColor(white: 1, alpha: 0.35).setFill()
        for i in 0..<65 {
            let x = CGFloat((i * 137 + 29) % 997) / 997 * bounds.width
            let y = (0.32 + CGFloat((i * 83 + 41) % 991) / 991 * 0.66) * bounds.height
            let radius: CGFloat = i % 9 == 0 ? 2 : 1
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius, height: radius)).fill()
        }
        for layer in 0..<3 {
            let ridge = NSBezierPath()
            ridge.move(to: .zero)
            for i in 0...12 {
                let x = CGFloat(i) / 12 * bounds.width
                let height = CGFloat((i * 37 + layer * 23) % 73) / 73
                let y = bounds.height * (0.06 + CGFloat(2 - layer) * 0.045 + height * 0.15)
                ridge.line(to: NSPoint(x: x, y: y))
            }
            ridge.line(to: NSPoint(x: bounds.width, y: 0))
            ridge.close()
            NSColor(srgbRed: 0.06 + Double(2-layer)*0.025,
                    green: 0.08 + Double(2-layer)*0.025,
                    blue: 0.14 + Double(2-layer)*0.045, alpha: 1).setFill()
            ridge.fill()
        }
    }
}

final class PlayerChromeButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor(white: 1, alpha: isHighlighted ? 0.18 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}
