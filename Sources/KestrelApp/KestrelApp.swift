import AppKit
import SwiftUI

@main
struct KestrelMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Kestrel") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Instance…") { model.showNewInstance = true }
                    .keyboardShortcut("n")
                    .disabled(!model.sdkReady)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run`; harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard !model.nativePlayers.isEmpty else { return .terminateNow }
        guard model.nativeQuitCompletion == nil else { return .terminateLater }
        model.nativeQuitFailed = false
        model.nativeQuitCompletion = { success in sender.reply(toApplicationShouldTerminate: success) }
        for index in Array(model.nativePlayers.keys) { model.stop(index) }
        return .terminateLater
    }

    /// Legacy external instances keep running; native sessions finish cleanup before quit.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopAllKeymapping()
    }
}

/// Shared formatting helpers.
func formatGB(_ mb: Int) -> String {
    mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct IdentifiedIndex: Identifiable {
    let id: Int
}
