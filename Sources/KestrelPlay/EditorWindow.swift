import AppKit
import KestrelCore
import KestrelKeymap

/// Stand-alone keymap editor window for `kestrel keymap edit`. The Kestrel app embeds the
/// same KeymapCanvasView in its Controls tab.
public enum KeymapEditorApp {
    public static func run(keymap: Keymap, saveTo url: URL, background: NSImage?, aspect: Double) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let size = NSSize(width: 1280, height: (1280 / aspect).rounded())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Kestrel keymap: \(keymap.name) → \(url.lastPathComponent)"
        window.contentAspectRatio = size
        let canvas = KeymapCanvasView(keymap: keymap, aspect: aspect)
        canvas.background = background
        canvas.status = "Drag to move · double-click to add · select + key to rebind · [ ] radius · ⌫ delete · ⌘S save"
        canvas.onSave = { km in
            let problems = km.validate()
            guard problems.isEmpty else { throw KestrelError.invalid(problems[0]) }
            try km.encoded().write(to: url, options: .atomic)
            return "Saved \(url.path)"
        }
        window.contentView = canvas
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            app.terminate(nil)
        }
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
