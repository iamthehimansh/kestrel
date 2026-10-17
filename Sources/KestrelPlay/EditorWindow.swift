import AppKit
import KestrelCore
import KestrelKeymap

/// Visual keymap editor. Shows a screenshot of the running game (or a blank 16:9 canvas)
/// with every control drawn on top.
///
/// Mouse: drag a control to move it, double-click empty space to add a tap.
/// Keys:  select a control and press any key to rebind it; [ / ] shrink/grow a radius;
///        Delete removes; Cmd-S saves; Esc closes.
public enum KeymapEditorApp {
    public static func run(keymap: Keymap, saveTo url: URL, background: NSImage?, aspect: Double) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let size = NSSize(width: 1280, height: (1280 / aspect).rounded())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Kestrel keymap: \(keymap.name) → \(url.lastPathComponent)"
        window.contentAspectRatio = size
        let view = EditorView(editor: KeymapEditor(keymap: keymap, aspect: aspect), background: background, saveTo: url)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            app.terminate(nil)
        }
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

final class EditorView: NSView {
    private var editor: KeymapEditor
    private let background: NSImage?
    private let saveTo: URL
    private var selected: Int?
    private var dragging = false
    private var dirty = false
    private var status = "Drag to move · double-click to add · select + key to rebind · [ ] radius · ⌫ delete · ⌘S save"

    init(editor: KeymapEditor, background: NSImage?, saveTo: URL) {
        self.editor = editor
        self.background = background
        self.saveTo = saveTo
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func norm(_ p: NSPoint) -> NPoint { NPoint(p.x / bounds.width, p.y / bounds.height).clamped }
    private func pt(_ p: NPoint) -> NSPoint { NSPoint(x: p.x * bounds.width, y: p.y * bounds.height) }

    override func mouseDown(with event: NSEvent) {
        let p = norm(convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, editor.hitTest(p) == nil {
            selected = editor.addTap(at: p, key: "F")
            dirty = true
            status = "Added a tap bound to F. Press a key to rebind it."
        } else {
            selected = editor.hitTest(p)
            dragging = selected != nil
            if let s = selected {
                let c = editor.keymap.controls[s]
                status = "\(c.typeName) · keys \(c.keys.joined(separator: ", "))" + (label(c).map { " · \($0)" } ?? "")
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let s = selected else { return }
        editor.move(s, to: norm(convert(event.locationInWindow, from: nil)))
        dirty = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" { save(); return }
        switch event.keyCode {
        case 0x35: window?.performClose(nil); return // Esc
        case 0x33, 0x75: // Backspace / Delete
            if let s = selected { editor.remove(s); selected = nil; dirty = true; status = "Removed." }
        case 0x21, 0x1E: // [ ]
            if let s = selected {
                let ok = editor.resize(s, by: event.keyCode == 0x1E ? 1.1 : 1 / 1.1)
                status = ok ? "Resized." : "This control has no radius."
                if ok { dirty = true }
            }
        default:
            guard let s = selected, let key = KeyNames.macKeyCodes[event.keyCode] else { return }
            if editor.rebind(s, to: key) { dirty = true; status = "Bound to \(key)." }
            else { status = "This control has several keys; edit them in the JSON file." }
        }
        needsDisplay = true
    }

    private func save() {
        let problems = editor.keymap.validate()
        guard problems.isEmpty else { status = "Not saved: " + problems[0]; needsDisplay = true; return }
        do {
            try editor.keymap.encoded().write(to: saveTo, options: .atomic)
            dirty = false
            status = "Saved \(saveTo.path)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
        needsDisplay = true
    }

    private func label(_ c: Control) -> String? {
        switch c {
        case .tap(let v): return v.label
        case .turbo(let v): return v.label
        case .skill(let v): return v.label
        case .swipe(let v): return v.label
        case .combo(let v): return v.label
        case .macro(let v): return v.label
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        if let background {
            NSGraphicsContext.current?.saveGraphicsState()
            // Flipped view: draw the image right side up.
            let t = NSAffineTransform()
            t.translateX(by: 0, yBy: bounds.height)
            t.scaleX(by: 1, yBy: -1)
            t.concat()
            background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.85)
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            NSColor(calibratedWhite: 1, alpha: 0.06).setStroke()
            for i in 1..<10 {
                let x = bounds.width * CGFloat(i) / 10, y = bounds.height * CGFloat(i) / 10
                NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: bounds.height))
                NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y), to: NSPoint(x: bounds.width, y: y))
            }
        }
        for (i, c) in editor.keymap.controls.enumerated() {
            if case .macro = c { continue }
            draw(c, selected: i == selected)
        }
        let macros = editor.keymap.controls.compactMap { c -> String? in
            if case .macro(let m) = c { return "⚙︎ \(m.key): \(m.label ?? "macro")" }
            return nil
        }
        if !macros.isEmpty { text(macros.joined(separator: "   "), at: NSPoint(x: 12, y: 12), center: false) }
        text((dirty ? "● " : "") + status, at: NSPoint(x: 12, y: bounds.height - 26), center: false)
    }

    private func draw(_ c: Control, selected: Bool) {
        let a = pt(c.anchor)
        let color = selected ? NSColor.systemYellow : NSColor.white
        switch c {
        case .joystick(let j):
            circle(a, j.radius * bounds.width, color)
        case .look(let l):
            circle(a, l.radius * bounds.width, color.withAlphaComponent(0.4))
        case .skill(let s) where s.radius > 0:
            circle(a, s.radius * bounds.width, color.withAlphaComponent(0.5))
        case .swipe(let s):
            arrow(pt(s.from), pt(s.to), color)
        case .combo(let cb):
            for (k, p) in cb.points.enumerated() { text("\(k + 1)", at: pt(p), center: true, color: color) }
        default: break
        }
        let keys = c.keys.map(KeyNames.shortLabel)
        let name: String
        switch c {
        case .joystick: name = keys.prefix(4).joined()
        case .look: name = "👁"
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
