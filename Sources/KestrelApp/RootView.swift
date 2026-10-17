import AppKit
import SwiftUI
import KestrelCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.sdkReady {
                NavigationSplitView {
                    InstanceList()
                        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
                } detail: {
                    if let i = model.selection, model.instance(i) != nil {
                        InstanceDetail(index: i)
                    } else {
                        EmptyInstances()
                    }
                }
            } else {
                SetupView()
            }
        }
        .sheet(isPresented: $model.showNewInstance) { NewInstanceSheet() }
        .sheet(item: Binding(get: { model.renaming.map(IdentifiedIndex.init) },
                             set: { model.renaming = $0?.id })) { item in
            RenameSheet(index: item.id)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.deleting != nil },
                                                             set: { if !$0 { model.deleting = nil } })) {
            Button("Delete", role: .destructive) { if let d = model.deleting { model.delete(d) } }
        } message: {
            Text("Its Android data, apps and snapshots are removed. This cannot be undone.")
        }
        .alert("Kestrel", isPresented: Binding(get: { model.errorMessage != nil },
                                               set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) { NoticeToast() }
    }

    private var deleteTitle: String {
        "Delete “\(model.deleting.flatMap(model.instance)?.settings.name ?? "instance")”?"
    }
}

struct NoticeToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let notice = model.notice {
            Text(notice)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if model.notice == notice { model.notice = nil }
                }
        }
    }
}

struct EmptyInstances: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No instance selected").font(.title2)
            Text("Create an Android instance to install and play games.")
                .foregroundStyle(.secondary)
            Button("New Instance…") { model.showNewInstance = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct InstanceList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Instances") {
                ForEach(model.instances, id: \.index) { inst in
                    InstanceRow(instance: inst)
                        .tag(inst.index)
                        .contextMenu { menu(inst.index) }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Start All") { model.startAll() }
                    Button("Stop All") { model.stopAll() }
                } label: {
                    Label("All Instances", systemImage: "square.stack.3d.up")
                }
                .help("Start or stop every instance")
                Button { model.showNewInstance = true } label: {
                    Label("New Instance", systemImage: "plus")
                }
                .help("New instance (⌘N)")
            }
        }
    }

    @ViewBuilder
    private func menu(_ i: Int) -> some View {
        switch model.state(i) {
        case .stopped:
            Button("Start") { model.start(i) }
            Button("Cold Boot") { model.start(i, cold: true) }
        case .running:
            Button("Stop") { model.stop(i) }
        case .booting:
            Button("Starting…") {}.disabled(true)
        }
        Divider()
        Button("Rename…") { model.renaming = i }
        Button("Duplicate") { model.clone(i) }
        Button("Show Data in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.paths.instanceDir(i)])
        }
        Divider()
        Button("Delete…", role: .destructive) { model.deleting = i }
            .disabled(model.state(i) != .stopped)
    }
}

struct InstanceRow: View {
    @EnvironmentObject var model: AppModel
    let instance: Instance

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: model.state(instance.index))
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.settings.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.activeSessions.contains(instance.index) {
                Image(systemName: "keyboard").foregroundStyle(.green).help("Key mapping is on")
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if let b = model.busy[instance.index] { return b }
        let s = instance.settings
        return "\(s.width)×\(s.height) · \(s.cpuCount) CPU · \(formatGB(s.memoryMB))"
    }
}

struct StatusDot: View {
    let state: RunState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .help(text)
    }

    private var color: Color {
        switch state {
        case .stopped: return .gray.opacity(0.6)
        case .booting: return .orange
        case .running: return .green
        }
    }

    private var text: String {
        switch state {
        case .stopped: return "Stopped"
        case .booting: return "Starting"
        case .running: return "Running"
        }
    }
}
