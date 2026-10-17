import AppKit
import KestrelKeymap

/// Visual keymap editor surface: the game screen (or a blank grid) with every control drawn
/// on top. Used by the Kestrel app and by `kestrel keymap edit`.
///
/// Mouse: click selects, drag moves, double-click empty space adds a tap.
/// Keys (when focused): any key rebinds the selected control, [ / ] shrink or grow a radius,
/// Delete removes, Esc deselects, Cmd-S saves.
public final class KeymapCanvasView: NSView {
    public private(set) var editor: KeymapEditor
    public var background: NSImage? { didSet { needsDisplay = true } }
    public private(set) var selected: Int?
    public var showsStatus = true { didSet { needsDisplay = true } }
    public var status = "Click a control to select it · drag to move · double-click to add · press a key to rebind"
    public private(set) var dirty = false

    /// The keymap changed through the canvas (drag, add, delete, rebind, resize).
    public var onChange: ((Keymap) -> Void)?
    /// The selection changed through the canvas.
    public var onSelect: ((Int?) -> Void)?
    /// Cmd-S. Return a status line to show; throw to show an error.
    public var onSave: ((Keymap) throws -> String)?

    private var dragging = false

    public init(keymap: Keymap, aspect: Double) {
        editor = KeymapEditor(keymap: keymap, aspect: aspect)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    public var aspect: Double { editor.aspect }

    /// Replaces the keymap from outside without reporting it back through onChange.
    public func setKeymap(_ keymap: Keymap, aspect: Double) {
        if aspect != editor.aspect {
            editor = KeymapEditor(keymap: keymap, aspect: aspect)
        } else {
            editor.replace(with: keymap)
        }
        if let s = selected, !keymap.controls.indices.contains(s) { selected = nil }
        needsDisplay = true
    }

    public func setSelected(_ index: Int?, notify: Bool) {
        let valid = index.flatMap { editor.keymap.controls.indices.contains($0) ? $0 : nil }
        guard valid != selected else { return }
        selected = valid
        if notify { onSelect?(valid) }
        needsDisplay = true
    }

    private func changed(_ message: String? = nil) {
        dirty = true
        if let message { status = message }
        onChange?(editor.keymap)
        needsDisplay = true
    }

    // MARK: Geometry

    /// The largest rect with the keymap's aspect ratio, centred in the view.
    private var content: NSRect {
        let a = CGFloat(max(editor.aspect, 0.01))
        var w = bounds.width, h = bounds.width / a
        if h > bounds.height { h = bounds.height; w = h * a }
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func norm(_ p: NSPoint) -> NPoint {
        let c = content
        return NPoint((p.x - c.minX) / max(c.width, 1), (p.y - c.minY) / max(c.height, 1)).clamped
    }

    private func pt(_ p: NPoint) -> NSPoint {
        let c = content
        return NSPoint(x: c.minX + p.x * c.width, y: c.minY + p.y * c.height)
    }

    // MARK: Mouse

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = norm(convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, editor.hitTest(p) == nil {
            guard let key = editor.freeKey(), let i = editor.addTap(at: p, key: key) else {
                status = "No free keys left."
                needsDisplay = true
                return
            }
            setSelected(i, notify: true)
            changed("Added a tap bound to \(key). Press a key to rebind it.")
            return
        }
        setSelected(editor.hitTest(p), notify: true)
        dragging = selected != nil
        if let s = selected {
            let c = editor.keymap.controls[s]
            status = "\(c.typeName) · \(c.keys.joined(separator: ", "))" + (c.label.map { " · \($0)" } ?? "")
        }
        needsDisplay = true
    }

    override public func mouseDragged(with event: NSEvent) {
        guard dragging, let s = selected else { return }
        editor.move(s, to: norm(convert(event.locationInWindow, from: nil)))
        changed()
    }

    override public func mouseUp(with event: NSEvent) { dragging = false }

    // MARK: Keys

    override public func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            save()
            return
        }
        switch event.keyCode {
        case 0x35: // Esc
            setSelected(nil, notify: true)
        case 0x33, 0x75: // Backspace / Delete
            if let s = selected {
                editor.remove(s)
                setSelected(nil, notify: true)
                changed("Removed.")
            }
        case 0x21, 0x1E: // [ ]
            if let s = selected {
                if editor.resize(s, by: event.keyCode == 0x1E ? 1.1 : 1 / 1.1) { changed("Resized.") }
                else { status = "This control has no radius." }
            }
        default:
            rebindSelected(KeyNames.macKeyCodes[event.keyCode])
        }
        needsDisplay = true
    }

    override public func flagsChanged(with event: NSEvent) {
        // Only on press, so Shift/Ctrl/Alt can be bound too.
        guard let key = KeyNames.macKeyCodes[event.keyCode] else { return }
        let pressed: Bool
        switch key {
        case "Shift", "RightShift": pressed = event.modifierFlags.contains(.shift)
        case "Ctrl", "RightCtrl": pressed = event.modifierFlags.contains(.control)
        case "Alt", "RightAlt": pressed = event.modifierFlags.contains(.option)
        default: return
        }
        if pressed { rebindSelected(key) }
    }

    private func rebindSelected(_ key: String?) {
        guard let s = selected, let key else { return }
        if editor.rebind(s, to: key) { changed("Bound to \(key).") }
        else { status = "This control has several keys; change them in the inspector." }
        needsDisplay = true
    }

    private func save() {
        guard let onSave else { return }
        do {
            status = try onSave(editor.keymap)
            dirty = false
        } catch {
            status = "Not saved: \(error)"
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override public func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        bounds.fill()
        let c = content
        if let background {
            NSGraphicsContext.current?.saveGraphicsState()
            // Flipped view: draw the image right side up.
            let t = NSAffineTransform()
            t.translateX(by: 0, yBy: c.minY * 2 + c.height)
            t.scaleX(by: 1, yBy: -1)
            t.concat()
            background.draw(in: c, from: .zero, operation: .sourceOver, fraction: 0.85)
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            c.fill()
            NSColor(calibratedWhite: 1, alpha: 0.06).setStroke()
            for i in 1..<10 {
                let x = c.minX + c.width * CGFloat(i) / 10, y = c.minY + c.height * CGFloat(i) / 10
                NSBezierPath.strokeLine(from: NSPoint(x: x, y: c.minY), to: NSPoint(x: x, y: c.maxY))
                NSBezierPath.strokeLine(from: NSPoint(x: c.minX, y: y), to: NSPoint(x: c.maxX, y: y))
            }
        }
        for (i, control) in editor.keymap.controls.enumerated() {
            if case .macro = control { continue }
            draw(control, selected: i == selected, scale: c.width)
        }
        let macros = editor.keymap.controls.enumerated().compactMap { i, control -> String? in
            if case .macro(let m) = control { return (i == selected ? "▸ " : "") + "⚙︎ \(KeyNames.shortLabel(m.key)): \(m.label ?? "macro")" }
            return nil
        }
        if !macros.isEmpty { text(macros.joined(separator: "   "), at: NSPoint(x: c.minX + 10, y: c.minY + 10), center: false) }
        if showsStatus {
            text((dirty ? "● " : "") + status, at: NSPoint(x: c.minX + 10, y: c.maxY - 26), center: false)
        }
    }

    private func draw(_ control: Control, selected: Bool, scale: CGFloat) {
        let a = pt(control.anchor)
        let color = selected ? NSColor.systemYellow : NSColor.white
        switch control {
        case .joystick(let j):
            circle(a, CGFloat(j.radius) * scale, color)
        case .look(let l):
            circle(a, CGFloat(l.radius) * scale, color.withAlphaComponent(0.4))
        case .skill(let s) where s.radius > 0:
            circle(a, CGFloat(s.radius) * scale, color.withAlphaComponent(0.5))
        case .swipe(let s):
            arrow(pt(s.from), pt(s.to), color)
        case .combo(let cb):
            for (k, p) in cb.points.enumerated() where k > 0 { text("\(k + 1)", at: pt(p), center: true, color: color) }
        case .pinch(let p):
            let d = CGFloat(p.spread) * scale
            arrow(a, NSPoint(x: a.x - d, y: a.y), color)
            arrow(a, NSPoint(x: a.x + d, y: a.y), color)
        default: break
        }
        let keys = control.keys.map(KeyNames.shortLabel)
        let name: String
        switch control {
        case .joystick(let j): name = keys.isEmpty ? "🕹 \(j.stick ?? "")" : keys.prefix(4).joined()
        case .look: name = "👁 aim"
        case .combo: name = "1 " + keys.joined(separator: "/")
        default: name = keys.joined(separator: "/")
        }
        text(name, at: a, center: true, color: color)
    }

    private func circle(_ c: NSPoint, _ r: CGFloat, _ color: NSColor) {
        color.withAlphaComponent(0.7).setStroke()
        let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        p.lineWidth = 2
        p.stroke()
    }

    private func arrow(_ a: NSPoint, _ b: NSPoint, _ color: NSColor) {
        color.withAlphaComponent(0.7).setStroke()
        let p = NSBezierPath()
        p.move(to: a)
        p.line(to: b)
        p.lineWidth = 2
        p.stroke()
        let ang = atan2(b.y - a.y, b.x - a.x)
        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: NSPoint(x: b.x - 12 * cos(ang - 0.4), y: b.y - 12 * sin(ang - 0.4)))
        head.move(to: b)
        head.line(to: NSPoint(x: b.x - 12 * cos(ang + 0.4), y: b.y - 12 * sin(ang + 0.4)))
        head.lineWidth = 2
        head.stroke()
    }

    private func text(_ s: String, at p: NSPoint, center: Bool, color: NSColor = .white) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let origin = center ? NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2) : p
        let box = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (s as NSString).draw(at: origin, withAttributes: attrs)
    }
}

extension Control {
    /// The optional display label of controls that have one.
    public var label: String? {
        switch self {
        case .tap(let v): return v.label
        case .turbo(let v): return v.label
        case .skill(let v): return v.label
        case .swipe(let v): return v.label
        case .combo(let v): return v.label
        case .macro(let v): return v.label
        default: return nil
        }
    }
}
