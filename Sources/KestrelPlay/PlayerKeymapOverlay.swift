import AppKit
import KestrelKeymap

/// Stages edits independently of the saved keymap while video continues underneath.
final class PlayerKeymapOverlay: NSView {
    let canvas: KeymapCanvasView
    let status = NSTextField(labelWithString: "Drag to move · double-click to add · select and press a key to rebind")
    var onSave: ((Keymap) throws -> Void)?
    var onDismiss: (() -> Void)?
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(keymap: Keymap, aspect: Double) {
        canvas = KeymapCanvasView(keymap: keymap, aspect: aspect)
        super.init(frame: .zero)
        canvas.overlaysLiveVideo = true
        canvas.showsStatus = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.96).cgColor
        bar.layer?.cornerRadius = 8
        status.font = .systemFont(ofSize: 11)
        status.textColor = .white
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        saveButton.target = self
        saveButton.action = #selector(saveEditing)
        for button in [saveButton, cancel] { button.bezelStyle = .rounded }
        for view in [status, saveButton, cancel] { bar.addArrangedSubview(view) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        canvas.onSave = { [weak self] _ in
            guard let self else { return "Editor closed" }
            return self.commit() ? "Saved" : self.status.stringValue
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @discardableResult
    func commit() -> Bool {
        let keymap = canvas.editor.keymap
        let problems = keymap.validate()
        guard problems.isEmpty else { status.stringValue = problems.joined(separator: "; "); return false }
        guard let onSave else { status.stringValue = "Saving is unavailable"; return false }
        do {
            try onSave(keymap)
            onDismiss?()
            return true
        } catch {
            status.stringValue = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    @objc private func saveEditing() { _ = commit() }
    @objc func cancelEditing() { onDismiss?() }
}
