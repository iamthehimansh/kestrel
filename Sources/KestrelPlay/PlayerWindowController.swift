import AppKit
import Metal
import KestrelCore
import KestrelKeymap

public enum PlayerWindowAction: Int, CaseIterable, Sendable {
    case volumeDown, volumeUp, screenshot, rotate, back, home, recents, menu, keymapping

    public var keyCommand: PlayerKeyCommand? {
        switch self {
        case .volumeDown: return .volumeDown
        case .volumeUp: return .volumeUp
        case .back: return .back
        case .home: return .home
        case .recents: return .recents
        case .menu: return .menu
        case .screenshot, .rotate, .keymapping: return nil
        }
    }

    fileprivate var title: String {
        switch self {
        case .volumeDown: return "Volume down"
        case .volumeUp: return "Volume up"
        case .screenshot: return "Screenshot"
        case .rotate: return "Rotate"
        case .back: return "Back"
        case .home: return "Home"
        case .recents: return "Recent apps"
        case .menu: return "Menu"
        case .keymapping: return "Edit keymapping"
        }
    }
}

/// A native presentation window. The host supplies authenticated video and command handlers;
/// constructing this controller alone never launches a VM or fabricates a connected session.
public final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    public let frameView: PlayerFrameView
    public private(set) var isConnected = false
    public private(set) var sidePanelVisible = true
    public var onAction: ((PlayerWindowAction) -> Void)? { didSet { updateControls() } }
    public var supportedActions: Set<PlayerWindowAction> = [] { didSet { updateControls() } }
    public var commandBusy = false { didSet { updateControls() } }
    public var onDisconnect: (() -> Void)?
    public var onClose: (() -> Void)?
    private var closeNotified = false
    private let panel = NSStackView()
    private let placeholder = NSTextField(labelWithString: "Waiting for a video connection")
    private var actionButtons: [NSButton] = []
    private(set) var keymapOverlay: PlayerKeymapOverlay?
    public var isEditingKeymap: Bool { keymapOverlay != nil }

    public func showKeymapEditor(_ keymap: Keymap, aspect: Double,
                                save: @escaping (Keymap) throws -> Void,
                                dismissed: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard isConnected, keymapOverlay == nil, let display = frameView.superview else { return }
        frameView.setPointerHandler(nil)
        let overlay = PlayerKeymapOverlay(keymap: keymap, aspect: aspect)
        overlay.onSave = save
        overlay.onDismiss = { [weak self] in
            guard let self, self.keymapOverlay != nil else { return }
            self.keymapOverlay?.removeFromSuperview()
            self.keymapOverlay = nil
            self.updateControls()
            self.window?.makeFirstResponder(self.frameView)
            dismissed()
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        display.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: frameView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: frameView.bottomAnchor)
        ])
        keymapOverlay = overlay
        updateControls()
        window?.makeFirstResponder(overlay.canvas)
    }

    public func dismissKeymapEditor() { keymapOverlay?.cancelEditing() }
    private let splash = NSStackView()
    private let bootProgress = NSProgressIndicator()
    private let statusPanel = NSView()
    private let statusBadge = NSTextField(labelWithString: "OFFLINE")
    public private(set) var isBooting = false

    public func showBootProgress(_ stage: String) {
        precondition(Thread.isMainThread)
        guard !isConnected, !closeNotified else { return }
        isBooting = true
        placeholder.stringValue = stage
        splash.isHidden = false
        statusPanel.isHidden = false
        statusBadge.stringValue = "STARTING"
        bootProgress.isHidden = false
        bootProgress.startAnimation(nil)
    }

    public init(title: String, device: MTLDevice) throws {
        precondition(Thread.isMainThread)
        frameView = try PlayerFrameView(device: device)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1080, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Kestrel · \(title)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        buildContents(window)
        frameView.onRenderError = { [weak self] error in
            self?.disconnect(message: "Video stopped: \(error.localizedDescription)")
        }
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:device:)") }

    @discardableResult
    public func beginConnection() -> PlayerFrameMailbox.Stream {
        precondition(Thread.isMainThread)
        disconnect(message: "Reconnecting")
        isConnected = true
        frameView.isHidden = false
        splash.isHidden = true
        statusPanel.isHidden = true
        statusBadge.stringValue = "CONNECTED"
        let stream = frameView.beginStream()
        updateControls()
        return stream
    }

    public func disconnect(message: String) {
        precondition(Thread.isMainThread)
        let wasConnected = isConnected
        isConnected = false
        dismissKeymapEditor()
        frameView.stopStream()
        frameView.isHidden = true
        placeholder.stringValue = message
        statusPanel.isHidden = false
        statusBadge.stringValue = "OFFLINE"
        splash.isHidden = false
        isBooting = false
        bootProgress.stopAnimation(nil)
        bootProgress.isHidden = true
        updateControls()
        if wasConnected { onDisconnect?() }
    }

    /// Acceptance means the connected host callback was invoked, not that Android completed
    /// the operation. The host must surface command failures separately.
    @discardableResult
    public func perform(_ action: PlayerWindowAction) -> Bool {
        precondition(Thread.isMainThread)
        guard isConnected, !isEditingKeymap, !commandBusy, supportedActions.contains(action), let onAction else { return false }
        onAction(action)
        return true
    }

    public func setSidePanelVisible(_ visible: Bool) {
        precondition(Thread.isMainThread)
        sidePanelVisible = visible
        panel.isHidden = !visible
    }

    /// Resizes only the host window. Android's display and input pixel space stay unchanged.
    @discardableResult
    public func resizeDisplay(by factor: CGFloat) -> Bool {
        precondition(Thread.isMainThread)
        guard !closeNotified, factor.isFinite, (0.5...2).contains(factor),
              let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return false }
        let visible = screen.visibleFrame
        let original = window.frame
        let width = min(visible.width, max(window.minSize.width, original.width * factor))
        let height = min(visible.height, max(window.minSize.height, original.height * factor))
        let x = min(max(original.midX - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(original.maxY - height, visible.minY), visible.maxY - height)
        let resized = NSRect(x: x, y: y, width: width, height: height)
        guard resized != original else { return false }
        window.setFrame(resized, display: true)
        return true
    }

    public override func close() {
        notifyClose()
        super.close()
    }

    public func windowWillClose(_ notification: Notification) {
        notifyClose()
    }

    private func notifyClose() {
        precondition(Thread.isMainThread)
        disconnect(message: "Connection closed")
        guard !closeNotified else { return }
        closeNotified = true
        onClose?()
    }

    private func updateControls() {
        precondition(Thread.isMainThread)
        for button in actionButtons {
            let supported = PlayerWindowAction(rawValue: button.tag).map { supportedActions.contains($0) } ?? false
            button.isEnabled = isConnected && !isEditingKeymap && !commandBusy && onAction != nil && supported
        }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        if let action = PlayerWindowAction(rawValue: sender.tag) { _ = perform(action) }
    }

    @objc private func togglePanel(_ sender: Any?) { setSidePanelVisible(!sidePanelVisible) }
    @objc private func toggleFullscreen(_ sender: Any?) { window?.toggleFullScreen(sender) }
    @objc private func hidePlayer(_ sender: Any?) { window?.miniaturize(sender) }
    @objc private func smallerDisplay(_ sender: Any?) { _ = resizeDisplay(by: 0.8) }
    @objc private func largerDisplay(_ sender: Any?) { _ = resizeDisplay(by: 1.25) }

    private func chromeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = PlayerChromeButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(white: 0.85, alpha: 1)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
        return button
    }

    private func buildContents(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.065, green: 0.075, blue: 0.10, alpha: 1)
        let root = NSView()
        window.contentView = root
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        let brand = NSTextField(labelWithString: "KESTREL")
        brand.font = .systemFont(ofSize: 11, weight: .bold)
        brand.textColor = NSColor(white: 0.9, alpha: 1)
        toolbar.addArrangedSubview(brand)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        statusBadge.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        statusBadge.textColor = NSColor(srgbRed: 0.85, green: 0.70, blue: 0.40, alpha: 1)
        toolbar.addArrangedSubview(statusBadge)
        for (title, symbol, selector) in [
            ("Smaller", "minus.magnifyingglass", #selector(smallerDisplay(_:))),
            ("Larger", "plus.magnifyingglass", #selector(largerDisplay(_:))),
            ("Controls", "sidebar.right", #selector(togglePanel(_:))),
            ("Full screen", "arrow.up.left.and.arrow.down.right", #selector(toggleFullscreen(_:))),
            ("Hide", "minus", #selector(hidePlayer(_:)))
        ] {
            toolbar.addArrangedSubview(chromeButton(title, symbol: symbol, action: selector))
        }
        let display = PlayerBackdrop()
        display.wantsLayer = true
        display.layer?.masksToBounds = true
        frameView.translatesAutoresizingMaskIntoConstraints = false
        display.addSubview(frameView)
        let logo = NSImageView()
        logo.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Kestrel")
        logo.contentTintColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.39, alpha: 1)
        logo.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: "Kestrel")
        name.font = .systemFont(ofSize: 38, weight: .light)
        name.textColor = .white
        let subtitle = NSTextField(labelWithString: "YOUR GAMES. YOUR SPACE.")
        subtitle.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = NSColor(white: 0.8, alpha: 1)
        splash.orientation = .vertical
        splash.alignment = .centerX
        splash.spacing = 12
        for view in [logo, name, subtitle] { splash.addArrangedSubview(view) }
        splash.translatesAutoresizingMaskIntoConstraints = false
        display.addSubview(splash)
        statusPanel.wantsLayer = true
        statusPanel.layer?.backgroundColor = NSColor(white: 0.025, alpha: 0.62).cgColor
        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        display.addSubview(statusPanel)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = NSColor(white: 0.9, alpha: 1)
        placeholder.font = .systemFont(ofSize: 12, weight: .medium)
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 2
        statusPanel.addSubview(placeholder)
        bootProgress.style = .bar
        bootProgress.isIndeterminate = true
        bootProgress.isHidden = true
        bootProgress.translatesAutoresizingMaskIntoConstraints = false
        bootProgress.setAccessibilityLabel("Starting Android")
        statusPanel.addSubview(bootProgress)
        let hint = NSTextField(labelWithString: "Keyboard, mouse & controller ready when you are.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor(white: 0.60, alpha: 1)
        hint.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.addSubview(hint)
        panel.orientation = .vertical
        panel.alignment = .centerX
        panel.spacing = 2
        panel.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let railWidth = panel.widthAnchor.constraint(equalToConstant: 52)
        railWidth.priority = .defaultHigh
        railWidth.isActive = true
        panel.setContentHuggingPriority(.required, for: .horizontal)
        display.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let symbols: [PlayerWindowAction: String] = [
            .volumeDown: "speaker.minus", .volumeUp: "speaker.plus", .screenshot: "camera",
            .rotate: "rotate.right", .back: "chevron.left", .home: "house",
            .recents: "square.on.square", .menu: "line.3.horizontal", .keymapping: "keyboard"
        ]
        for action in PlayerWindowAction.allCases {
            if action == .screenshot || action == .back {
                let separator = NSBox()
                separator.boxType = .separator
                separator.widthAnchor.constraint(equalToConstant: 24).isActive = true
                panel.addArrangedSubview(separator)
            }
            let button = chromeButton(action.title, symbol: symbols[action]!, action: #selector(actionClicked(_:)))
            button.tag = action.rawValue
            panel.addArrangedSubview(button)
            actionButtons.append(button)
        }
        let body = NSStackView(views: [display, panel])
        body.orientation = .horizontal
        body.distribution = .fill
        body.spacing = 0
        body.alignment = .top
        for view in [toolbar, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            body.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            display.heightAnchor.constraint(equalTo: body.heightAnchor),
            display.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            frameView.leadingAnchor.constraint(equalTo: display.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: display.trailingAnchor),
            frameView.topAnchor.constraint(equalTo: display.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: display.bottomAnchor),
            logo.widthAnchor.constraint(equalToConstant: 56),
            logo.heightAnchor.constraint(equalToConstant: 56),
            splash.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            splash.centerYAnchor.constraint(equalTo: display.centerYAnchor, constant: -12),
            statusPanel.leadingAnchor.constraint(equalTo: display.leadingAnchor),
            statusPanel.trailingAnchor.constraint(equalTo: display.trailingAnchor),
            statusPanel.bottomAnchor.constraint(equalTo: display.bottomAnchor),
            statusPanel.heightAnchor.constraint(equalToConstant: 92),
            placeholder.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -20),
            placeholder.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 14),
            bootProgress.leadingAnchor.constraint(equalTo: placeholder.leadingAnchor),
            bootProgress.trailingAnchor.constraint(equalTo: placeholder.trailingAnchor),
            bootProgress.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: placeholder.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: placeholder.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: -12)
        ])
        frameView.isHidden = true
    }

}
