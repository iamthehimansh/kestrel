import SwiftUI
import KestrelCore

enum DetailTab: String, CaseIterable, Identifiable {
    case apps = "Apps", controls = "Controls", snapshots = "Snapshots", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .controls: return "keyboard"
        case .snapshots: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct InstanceDetail: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var tab: DetailTab = .apps

    var body: some View {
        VStack(spacing: 0) {
            InstanceHeader(index: index)
            Divider()
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            Group {
                switch tab {
                case .apps: AppsTab(index: index)
                case .controls: ControlsTab(index: index)
                case .snapshots: SnapshotsTab(index: index)
                case .settings: SettingsTab(index: index)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(index)
    }
}

// MARK: - Header

struct InstanceHeader: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let state = model.state(index)
        let inst = model.instance(index)
        HStack(alignment: .center, spacing: 14) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(inst?.settings.name ?? "").font(.title2.bold())
                Text(model.busy[index] ?? stateText(state, inst))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy[index] != nil { ProgressView().controlSize(.small) }
            switch state {
            case .stopped:
                Menu {
                    Button("Cold Boot (full restart)") { model.start(index, cold: true) }
                    let snaps = model.snapshots(index)
                    if !snaps.isEmpty {
                        Section("Resume a Snapshot") {
                            ForEach(snaps, id: \.name) { s in
                                Button(s.name) { model.start(index, snapshot: s.name) }
                            }
                        }
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                } primaryAction: {
                    model.start(index)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("Start where you left off")
            case .booting:
                Button {} label: { Label("Starting…", systemImage: "hourglass") }.disabled(true)
            case .running:
                KeymapToggle(index: index)
                Button { model.saveScreenshot(index) } label: { Label("Screenshot", systemImage: "camera") }
                    .help("Save a screenshot to the Desktop")
                Button { model.stop(index) } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Shut down; the next Start resumes where it stopped")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottomLeading) {
            if let status = model.sessionStatus[index] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.leading, 43)
                    .padding(.bottom, 2)
                    .lineLimit(1)
            }
        }
    }

    private func stateText(_ s: RunState, _ inst: Instance?) -> String {
        guard let inst else { return "" }
        let base = "\(inst.settings.width)×\(inst.settings.height) · \(inst.settings.cpuCount) CPU · \(formatGB(inst.settings.memoryMB)) · adb 127.0.0.1:\(inst.ports.adb)"
        switch s {
        case .stopped: return "Stopped · \(base)"
        case .booting: return "Starting · \(base)"
        case .running: return "Running · \(base)"
        }
    }
}

/// On/off switch for key mapping, with a Record option.
struct KeymapToggle: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let on = model.activeSessions.contains(index)
        let recording = model.recordingSessions.contains(index)
        if on {
            Button {
                model.stopKeymapping(index)
            } label: {
                Label(recording ? "Stop Recording" : "Key Mapping On",
                      systemImage: recording ? "record.circle.fill" : "keyboard.fill")
            }
            .tint(recording ? .red : .green)
            .buttonStyle(.borderedProminent)
            .help("Turn key mapping off")
        } else {
            Menu {
                Button("Turn On and Record Inputs") { model.startKeymapping(index, record: true) }
            } label: {
                Label("Key Mapping", systemImage: "keyboard")
            } primaryAction: {
                model.startKeymapping(index)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(model.instance(index)?.settings.keymap == nil)
            .help(model.instance(index)?.settings.keymap == nil
                  ? "Pick a keymap in the Controls tab first"
                  : "Map keyboard, mouse and gamepad to touches")
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var s: InstanceSettings?
    @State private var device = "custom"

    var body: some View {
        Group {
            if s != nil {
                form
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        s = model.instance(index)?.settings
        device = Presets.devices.first { $0.value.brand == s?.deviceBrand && $0.value.model == s?.deviceModel }?.key
            ?? (s?.deviceModel == nil ? "none" : "custom")
    }

    private var binding: Binding<InstanceSettings> {
        Binding(get: { s ?? InstanceSettings(name: "") }, set: { s = $0 })
    }

    private var form: some View {
        let b = binding
        let saved = model.instance(index)?.settings
        let errors = s?.validate() ?? []
        return VStack(spacing: 0) {
            Form {
                Section("Performance") {
                    Stepper("CPU cores: \(b.wrappedValue.cpuCount)", value: b.cpuCount, in: 1...max(1, KestrelCore.Host.cores))
                    Picker("Memory", selection: b.memoryMB) {
                        ForEach(memoryChoices(b.wrappedValue.memoryMB), id: \.self) { Text(formatGB($0)).tag($0) }
                    }
                    Picker("Frame rate", selection: b.fpsLimit) {
                        ForEach([30, 60, 90, 120, 144, 165, 240], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Toggle("Show FPS", isOn: b.showFPS)
                }
                Section("Display") {
                    Picker("Resolution", selection: Binding(
                        get: { Presets.resolutions.first { $0.width == b.wrappedValue.width && $0.height == b.wrappedValue.height }?.id ?? "custom" },
                        set: { id in
                            if let r = Presets.resolution(id) { s?.width = r.width; s?.height = r.height; s?.dpi = r.dpi }
                        })) {
                        ForEach(Presets.resolutions, id: \.id) { Text(resolutionLabel($0)).tag($0.id) }
                        Text("Custom (\(b.wrappedValue.width)×\(b.wrappedValue.height))").tag("custom")
                    }
                    Stepper("Density: \(b.wrappedValue.dpi) dpi", value: b.dpi, in: 120...640, step: 20)
                }
                Section("Graphics") {
                    Picker("Renderer", selection: b.gpuMode) {
                        Text("Host GPU (Metal) · fastest").tag(GPUMode.host)
                        Text("Software (compatibility)").tag(GPUMode.swiftshader)
                    }
                    Toggle("Vulkan", isOn: b.vulkan)
                }
                Section("Device") {
                    Picker("Phone model", selection: $device) {
                        Text("Default (emulator)").tag("none")
                        ForEach(Presets.devices.keys.sorted(), id: \.self) { k in
                            Text("\(Presets.devices[k]!.manufacturer) \(Presets.devices[k]!.model)").tag(k)
                        }
                        if device == "custom" { Text("Custom").tag("custom") }
                    }
                    .onChange(of: device) { v in
                        if v == "none" { s?.deviceBrand = nil; s?.deviceModel = nil }
                        else if let d = Presets.devices[v] { s?.deviceBrand = d.brand; s?.deviceModel = d.model }
                    }
                    Stepper("Storage: \(b.wrappedValue.dataPartitionGB) GB", value: b.dataPartitionGB, in: 2...512, step: 2)
                        .help("Only applies to a new instance or after wiping its data")
                }
                Section("Input and sound") {
                    HStack {
                        Text("Mouse sensitivity")
                        Slider(value: b.mouseSensitivity, in: 0.2...4, step: 0.1)
                        Text(String(format: "%.1f×", b.wrappedValue.mouseSensitivity)).monospacedDigit().frame(width: 40)
                    }
                    Toggle("Sound and microphone", isOn: b.audio)
                    Toggle("Show the emulator window", isOn: b.window)
                }
                if !errors.isEmpty {
                    Section { ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) } }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if model.state(index) != .stopped {
                    Label("Changes apply after a restart.", systemImage: "info.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { load() }.disabled(s == saved)
                Button("Save") { if let s { model.saveSettings(index, s) } }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(s == saved || !errors.isEmpty)
            }
            .padding(12)
        }
    }

    private func memoryChoices(_ current: Int) -> [Int] {
        let maxMB = max(2048, KestrelCore.Host.memoryMB - 4096)
        var list = [2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768].filter { $0 <= maxMB }
        if !list.contains(current) { list.append(current); list.sort() }
        return list
    }
}
