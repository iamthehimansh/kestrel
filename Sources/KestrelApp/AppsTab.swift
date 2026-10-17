import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KestrelCore

struct AppsTab: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var packages: [String] = []
    @State private var loading = false
    @State private var playPackage = ""
    @State private var filter = ""
    @State private var choosingAPK = false
    @State private var dropTargeted = false

    var body: some View {
        let running = model.state(index) == .running
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.openPlayStore(index) } label: { Label("Google Play", systemImage: "bag") }
                    .buttonStyle(.borderedProminent)
                TextField("Open a Play Store page by package, e.g. com.dts.freefireth", text: $playPackage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.openPlayStore(index, package: playPackage) }
                Button("Open Page") { model.openPlayStore(index, package: playPackage) }
                    .disabled(playPackage.trimmingCharacters(in: .whitespaces).isEmpty)
                Divider().frame(height: 20)
                Button { choosingAPK = true } label: { Label("Install APK…", systemImage: "square.and.arrow.down") }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh the app list")
            }
            .disabled(!running)
            .padding(14)
            Divider()
            if !running {
                placeholder("Start the instance to see and install apps.", icon: "power")
            } else if loading && packages.isEmpty {
                ProgressView("Loading apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if packages.isEmpty {
                placeholder("No apps yet. Install games from Google Play or drop an .apk file here.", icon: "square.grid.2x2")
            } else {
                List {
                    ForEach(filtered, id: \.self) { pkg in AppRow(index: index, package: pkg, onChange: refresh) }
                }
                .searchable(text: $filter, placement: .toolbar, prompt: "Filter apps")
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "apk" else { return }
                    DispatchQueue.main.async { model.installAPK(index, url) { refresh() } }
                }
            }
            return true
        }
        .fileImporter(isPresented: $choosingAPK,
                      allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    model.installAPK(index, url) {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        refresh()
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.state(index)) { _ in refresh() }
    }

    private var filtered: [String] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? packages : packages.filter { $0.lowercased().contains(f) }
    }

    private func refresh() {
        guard model.state(index) == .running else { packages = []; return }
        loading = true
        model.packages(index) { list in
            packages = list
            loading = false
        }
    }

    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let package: String
    let onChange: () -> Void
    @State private var confirmUninstall = false

    var body: some View {
        let keymap = model.keymapEntry(forPackage: package)
        HStack(spacing: 12) {
            Image(systemName: keymap != nil ? "gamecontroller.fill" : "app")
                .font(.title2)
                .foregroundStyle(keymap != nil ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(keymap?.keymap.name ?? package).lineLimit(1)
                Text(keymap != nil ? "\(package) · keymap ready" : package)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if keymap != nil {
                Button { model.play(index, package) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .help("Open the game and turn on its key mapping")
            }
            Button("Open") { model.launchApp(index, package) }
            Menu {
                Button("Close App") { model.stopApp(index, package) }
                Button("Open in Google Play") { model.openPlayStore(index, package: package) }
                Divider()
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .confirmationDialog("Uninstall \(package)?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstallApp(index, package) { onChange() } }
        } message: {
            Text("The app and its data are removed from this instance.")
        }
    }
}

// MARK: - Snapshots

struct SnapshotsTab: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var snapshots: [Snapshot] = []
    @State private var naming = false
    @State private var deleting: String?

    var body: some View {
        let state = model.state(index)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save states").font(.headline)
                    Text("Save the whole Android state, game included, and come back to it in seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { naming = true } label: { Label("Save Current State…", systemImage: "square.and.arrow.down.on.square") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state != .running)
                    .help(state == .running ? "Save what is on screen now" : "Start the instance to save a state")
            }
            .padding(14)
            Divider()
            if snapshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No saved states yet.").foregroundStyle(.secondary)
                    Text("Stopping an instance always keeps its state, so Start resumes where you left off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(snapshots, id: \.name) { snap in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.name)
                            Text([snap.date.map { $0.formatted(date: .abbreviated, time: .shortened) }, formatBytes(snap.sizeBytes)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch state {
                        case .running:
                            Button("Restore") { model.restoreSnapshot(index, name: snap.name) }
                                .help("Jump back to this state now")
                        case .stopped:
                            Button("Start from Here") { model.start(index, snapshot: snap.name) }
                                .help("Boot straight into this state")
                        case .booting:
                            EmptyView()
                        }
                        Button(role: .destructive) { deleting = snap.name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this state")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(isPresented: $naming) {
            NamePrompt(title: "Save Current State",
                       message: "Letters, digits, '.', '_' and '-'.",
                       action: "Save",
                       name: defaultName(),
                       isValid: Snapshots.isValidName) { name in
                model.saveSnapshot(index, name: name) { refresh() }
            }
        }
        .confirmationDialog("Delete “\(deleting ?? "")”?", isPresented: Binding(get: { deleting != nil },
                                                                              set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting { model.deleteSnapshot(index, name: d) { refresh() } }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.busy[index]) { _ in refresh() }
    }

    private func refresh() { snapshots = model.snapshots(index) }

    private func defaultName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        return "save-\(fmt.string(from: Date()))"
    }
}
