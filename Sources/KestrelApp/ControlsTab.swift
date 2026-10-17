import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KestrelKeymap
import KestrelPlay

/// Visual keymap editor: the game screen with every control drawn on it, an inspector for
/// the selected control, and the keymap's own settings.
struct ControlsTab: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var pendingKeymap: String??
    @State private var namingNew = false
    @State private var namingCopy = false
    @State private var importing = false
    @State private var exporting = false
    @State private var showRecordings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.editingKeymap == nil {
                noKeymap
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        KeymapCanvasRepresentable()
                            .frame(minWidth: 480, minHeight: 300)
                        canvasFooter
                    }
                    ControlInspector()
                        .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
                }
            }
        }
        .onAppear { if model.screenshot == nil { model.refreshScreenshot(index) } }
        .confirmationDialog("Discard unsaved changes to “\(model.editingKeymap?.name ?? "")”?",
                            isPresented: Binding(get: { pendingKeymap != nil }, set: { if !$0 { pendingKeymap = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let p = pendingKeymap { model.assignKeymap(index, id: p) }
            }
        }
        .sheet(isPresented: $namingNew) {
            NamePrompt(title: "New Keymap", message: "Start from an empty layout for this instance.",
                       action: "Create", name: "My Game", isValid: { !$0.isEmpty }) { name in
                model.newKeymap(index, name: name, package: nil)
            }
        }
        .sheet(isPresented: $namingCopy) {
            NamePrompt(title: "Duplicate Keymap", message: "Saves a copy you can change freely.",
                       action: "Duplicate", name: "\(model.editingKeymap?.name ?? "Keymap") copy", isValid: { !$0.isEmpty }) { name in
                model.saveKeymapAsNew(index, name: name)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                model.importKeymap(index, from: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .fileExporter(isPresented: $exporting, document: KeymapDocument(keymap: model.editingKeymap),
                      contentType: .json, defaultFilename: model.editingKeymapID ?? "keymap") { _ in }
        .sheet(isPresented: $showRecordings) { RecordingsSheet(index: index) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Keymap", selection: Binding(
                get: { model.editingKeymapID ?? "" },
                set: { id in
                    let next: String? = id.isEmpty ? nil : id
                    if model.keymapDirty { pendingKeymap = .some(next) } else { model.assignKeymap(index, id: next) }
                })) {
                Text("None").tag("")
                ForEach(model.keymaps, id: \.id) { e in
                    Text(e.keymap.name + (e.isUser ? "" : " (preset)")).tag(e.id)
                }
            }
            .frame(maxWidth: 320)
            Menu {
                Section("Add Control") {
                    ForEach(ControlKind.all, id: \.type) { k in
                        Button { model.addControl(k.type) } label: { Label(k.title, systemImage: k.icon) }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
            .disabled(model.editingKeymap == nil)
            Menu {
                Button("New Keymap…") { namingNew = true }
                Button("Duplicate…") { namingCopy = true }.disabled(model.editingKeymap == nil)
                Divider()
                Button("Import…") { importing = true }
                Button("Export…") { exporting = true }.disabled(model.editingKeymap == nil)
                Divider()
                Button(model.editingEntry?.isUser == true ? "Delete My Copy" : "Delete") { model.deleteUserKeymap(index) }
                    .disabled(model.editingEntry?.isUser != true)
                Divider()
                Button("Recordings…") { showRecordings = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Revert") { model.revertKeymap() }.disabled(!model.keymapDirty)
            Button("Save") { model.saveKeymap() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!model.keymapDirty || !(model.editingKeymap?.validate().isEmpty ?? false))
        }
        .padding(12)
    }

    private var canvasFooter: some View {
        HStack(spacing: 10) {
            Button { model.refreshScreenshot(index) } label: { Label("Refresh Screen", systemImage: "arrow.clockwise") }
                .disabled(model.state(index) != .running)
                .help("Show the game's current screen behind the controls")
            if model.screenshot != nil {
                Button("Hide Screen") { model.screenshot = nil }
            }
            Spacer()
            if let problem = model.editingKeymap?.validate().first {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(problem)
            } else if model.editingEntry?.isUser == false {
                Text("Preset · saving keeps your own copy").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(8)
    }

    private var noKeymap: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No keymap for this instance").font(.title3)
            Text("Pick a game preset from the menu above, or start a new layout.")
                .foregroundStyle(.secondary)
            Button("New Keymap…") { namingNew = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The control types users can add, with menu titles and icons.
struct ControlKind {
    let type: String
    let title: String
    let icon: String

    static let all: [ControlKind] = [
        .init(type: "tap", title: "Tap / Fire button", icon: "hand.tap"),
        .init(type: "joystick", title: "Joystick (WASD)", icon: "dpad"),
        .init(type: "look", title: "Aim with the mouse", icon: "scope"),
        .init(type: "skill", title: "Skill (aim at cursor)", icon: "sparkles"),
        .init(type: "turbo", title: "Turbo (auto-repeat)", icon: "bolt"),
        .init(type: "swipe", title: "Swipe", icon: "hand.draw"),
        .init(type: "combo", title: "Combo (tap sequence)", icon: "list.number"),
        .init(type: "scroll", title: "Mouse wheel", icon: "computermouse"),
        .init(type: "pinch", title: "Pinch zoom", icon: "arrow.up.left.and.arrow.down.right"),
        .init(type: "macro", title: "Macro (script)", icon: "chevron.left.forwardslash.chevron.right"),
    ]

    static func title(_ type: String) -> String { all.first { $0.type == type }?.title ?? type }
    static func icon(_ type: String) -> String { all.first { $0.type == type }?.icon ?? "circle" }
}

/// Wraps the shared AppKit canvas and keeps it in sync with the model both ways.
struct KeymapCanvasRepresentable: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> KeymapCanvasView {
        // Capture the resolved object: the stored closures outlive this view value, and
        // reading an @EnvironmentObject outside a view update is not allowed.
        let model = self.model
        let canvas = KeymapCanvasView(keymap: model.editingKeymap ?? Keymap(name: "", controls: []), aspect: model.currentAspect)
        canvas.showsStatus = false
        canvas.onChange = { km in
            DispatchQueue.main.async {
                model.editingKeymap = km
                model.keymapDirty = true
            }
        }
        canvas.onSelect = { sel in DispatchQueue.main.async { model.selectedControl = sel } }
        canvas.onSave = { _ in
            model.saveKeymap()
            return "Saved"
        }
        return canvas
    }

    func updateNSView(_ canvas: KeymapCanvasView, context: Context) {
        if let km = model.editingKeymap, km != canvas.editor.keymap || canvas.aspect != model.currentAspect {
            canvas.setKeymap(km, aspect: model.currentAspect)
        }
        if canvas.selected != model.selectedControl { canvas.setSelected(model.selectedControl, notify: false) }
        if canvas.background !== model.screenshot { canvas.background = model.screenshot }
    }
}

/// Lets SwiftUI's file exporter write a keymap.
struct KeymapDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var keymap: Keymap?

    init(keymap: Keymap?) { self.keymap = keymap }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        keymap = try Keymap.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let keymap else { throw CocoaError(.fileWriteUnknown) }
        return FileWrapper(regularFileWithContents: try keymap.encoded())
    }
}

/// Inputs recorded with "Turn On and Record Inputs", replayable later.
struct RecordingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recordings").font(.title2.bold())
            Text("Record with Key Mapping → Turn On and Record Inputs. Replay plays the same inputs back with the same timing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let files = model.recordings(index)
            if files.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(files, id: \.self) { url in
                    HStack {
                        Image(systemName: "waveform.path")
                        Text(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "__", with: " · "))
                            .lineLimit(1)
                        Spacer()
                        Button("Replay") { model.replay(index, file: url); dismiss() }
                            .disabled(model.state(index) != .running)
                        Button(role: .destructive) { model.deleteRecording(url) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 200)
            }
            HStack {
                Button("Show in Finder") {
                    let dir = model.recordingsDir(index)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
