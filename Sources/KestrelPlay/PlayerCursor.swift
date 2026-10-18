import AppKit

/// View-local cursor; AppKit restores the normal cursor outside the game surface.
enum PlayerCursor {
    static let gold: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 32), flipped: true) { _ in
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 3, y: 2))
            arrow.line(to: NSPoint(x: 3, y: 25))
            arrow.line(to: NSPoint(x: 9, y: 20))
            arrow.line(to: NSPoint(x: 14, y: 30))
            arrow.line(to: NSPoint(x: 19, y: 27))
            arrow.line(to: NSPoint(x: 14, y: 18))
            arrow.line(to: NSPoint(x: 22, y: 17))
            arrow.close()
            NSColor(calibratedRed: 1, green: 0.76, blue: 0.18, alpha: 1).setFill()
            arrow.fill()
            NSColor(calibratedWhite: 0.12, alpha: 1).setStroke()
            arrow.lineWidth = 2
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 2))
    }()
}
