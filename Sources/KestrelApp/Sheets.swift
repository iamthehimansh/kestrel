import SwiftUI
import KestrelCore

struct NewInstanceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var preset: PerformancePreset = .high
    @State private var resolution = "tablet-1920x1080"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Instance").font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Instance \(model.instances.count)"))
                Picker("Performance", selection: $preset) {
                    ForEach([PerformancePreset.low, .medium, .high], id: \.self) { p in
                        Text(presetLabel(p)).tag(p)
                    }
                }
                Picker("Screen", selection: $resolution) {
                    ForEach(Presets.resolutions, id: \.id) { r in
                        Text(resolutionLabel(r)).tag(r.id)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Android 16 with Google Play. Sign in with your own Google account inside Android to install apps; Kestrel has no account of its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.create(name: name, preset: preset, resolution: resolution)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func presetLabel(_ p: PerformancePreset) -> String {
        let cm = Presets.cpuMemory(p, hostCores: KestrelCore.Host.cores, hostMemoryMB: KestrelCore.Host.memoryMB)
        let mem = max(cm.memoryMB, SDKSetup.playMinimumMemoryMB)
        return "\(p.rawValue.capitalized) · \(cm.cpu) CPU, \(formatGB(mem))"
    }
}

func resolutionLabel(_ r: ResolutionPreset) -> String {
    let kind = r.width >= r.height ? "Landscape" : "Portrait"
    return "\(kind) \(r.width)×\(r.height) · \(r.dpi) dpi"
}

struct RenameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Instance").font(.title3.bold())
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.rename(index, to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = model.instance(index)?.settings.name ?? "" }
    }
}

/// A one-line text prompt used for snapshot and keymap names.
struct NamePrompt: View {
    let title: String
    let message: String
    let action: String
    @State var name: String
    let isValid: (String) -> Bool
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(message).font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    onCommit(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid(name.trimmingCharacters(in: .whitespaces)))
            }
        }
        .padding(20)
    }
}

// MARK: - First run

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var log: [String] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Welcome to Kestrel").font(.largeTitle.bold())
                    Text("Android games on your Mac. No account, no login.").foregroundStyle(.secondary)
                }
            }
            Text("Kestrel needs Google's Android emulator and the Android 16 Google Play image (several GB). It downloads them once into \(SDKSetup.sdkRoot().path).")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SDKSetup.components.filter(\.required), id: \.package) { c in
                    let ok = SDKSetup.isInstalled(c.package, root: SDKSetup.sdkRoot())
                    Label("\(c.purpose)", systemImage: ok ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(ok ? Color.green : Color.secondary)
                }
            }
            HStack {
                Button(running ? "Downloading…" : "Download and Set Up") {
                    running = true
                    log = ["Starting…"]
                    model.installSDK(log: { log.append($0) }) { _ in running = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
                Button("Check Again") { model.connectSDK() }.disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            if !log.isEmpty {
                ScrollView {
                    Text(log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: 720)
    }
}
