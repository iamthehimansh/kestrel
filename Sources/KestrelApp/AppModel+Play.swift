import AppKit
import KestrelCore
import KestrelKeymap
import KestrelPlay

/// Keymaps (choose, edit, save) and key mapping (on/off, record, replay).
extension AppModel {
    func reloadKeymaps() { keymaps = library.all() }

    func selectionChanged() {
        selectedControl = nil
        screenshot = nil
        let id = selection.flatMap(instance)?.settings.keymap
        if editingKeymapID != id || !keymapDirty { loadKeymap(id: id) }
    }

    func loadKeymap(id: String?) {
        editingKeymapID = id
        editingKeymap = id.flatMap { try? library.resolve($0).keymap }
        if id != nil && editingKeymap == nil { editingKeymapID = nil }
        keymapDirty = false
        selectedControl = nil
    }

    /// Sets which keymap an instance plays with and opens it in the editor.
    func assignKeymap(_ i: Int, id: String?) {
        guard let store else { return }
        do {
            var inst = try store.load(i)
            inst.settings.keymap = id
            try store.save(inst)
            reload()
        } catch { errorMessage = "\(error)" }
        loadKeymap(id: id)
    }

    var editingEntry: KeymapLibrary.Entry? { editingKeymapID.flatMap { id in keymaps.first { $0.id == id } } }

    func saveKeymap() {
        guard let id = editingKeymapID, let km = editingKeymap else { return }
        do {
            try library.save(km, id: id)
            keymapDirty = false
            reloadKeymaps()
            notice = "Saved keymap “\(km.name)”"
        } catch { errorMessage = "\(error)" }
    }

    func saveKeymapAsNew(_ i: Int, name: String) {
        guard var km = editingKeymap else { return }
        km.name = name
        let id = library.freeID(name)
        do {
            try library.save(km, id: id)
            reloadKeymaps()
            assignKeymap(i, id: id)
        } catch { errorMessage = "\(error)" }
    }

    func newKeymap(_ i: Int, name: String, package: String?) {
        let pkg = package?.trimmingCharacters(in: .whitespaces)
        var km = Keymap(name: name, package: pkg?.isEmpty == false ? pkg : nil, controls: [])
        if let inst = instance(i) { km.aspect = Double(inst.settings.width) / Double(max(inst.settings.height, 1)) }
        let id = library.freeID(name)
        do {
            try library.save(km, id: id)
            reloadKeymaps()
            assignKeymap(i, id: id)
        } catch { errorMessage = "\(error)" }
    }

    func revertKeymap() { loadKeymap(id: editingKeymapID) }

    /// Deletes the user's copy; a bundled preset with the same name shows again.
    func deleteUserKeymap(_ i: Int) {
        guard let id = editingKeymapID else { return }
        do {
            try library.deleteUser(id: id)
            reloadKeymaps()
            if (try? library.resolve(id)) != nil { loadKeymap(id: id) } else { assignKeymap(i, id: nil) }
        } catch { errorMessage = "\(error)" }
    }

    func importKeymap(_ i: Int, from url: URL) {
        do {
            let km = try Keymap.load(url)
            let id = library.freeID(km.name.isEmpty ? url.deletingPathExtension().lastPathComponent : km.name)
            try library.save(km, id: id)
            reloadKeymaps()
            assignKeymap(i, id: id)
            notice = "Imported “\(km.name)”"
        } catch { errorMessage = "Could not import \(url.lastPathComponent): \(error)" }
    }

    func exportKeymap(to url: URL) {
        guard let km = editingKeymap else { return }
        do { try km.encoded().write(to: url, options: .atomic) } catch { errorMessage = "\(error)" }
    }

    var currentAspect: Double {
        guard let inst = selection.flatMap(instance) else { return 16.0 / 9.0 }
        return Double(inst.settings.width) / Double(max(inst.settings.height, 1))
    }

    /// Applies an edit to the keymap in the editor.
    func editKeymap(_ body: (inout KeymapEditor) -> Void) {
        guard let km = editingKeymap else { return }
        var e = KeymapEditor(keymap: km, aspect: currentAspect)
        body(&e)
        if e.keymap != km {
            editingKeymap = e.keymap
            keymapDirty = true
        }
    }

    func addControl(_ type: String) {
        var added: Int?
        editKeymap { added = $0.addControl(type, at: NPoint(0.5, 0.5)) }
        if let added { selectedControl = added }
        else if type == "look" { errorMessage = "A keymap can have only one aim (look) control." }
        else { errorMessage = "No free keys left for a new control." }
    }

    func deleteSelectedControl() {
        guard let s = selectedControl else { return }
        editKeymap { $0.remove(s) }
        selectedControl = nil
    }

    func refreshScreenshot(_ i: Int) {
        guard let adb = adb(i), state(i) == .running else { return }
        work.async {
            let data = try? adb.screenshotData()
            DispatchQueue.main.async {
                if let data, self.selection == i { self.screenshot = NSImage(data: data) }
            }
        }
    }

    // MARK: - Key mapping

    /// The keymap to play with: the one open in the editor if it belongs to this instance
    /// (so unsaved edits can be tried live), else the instance's saved choice.
    func playKeymap(_ i: Int) -> Keymap? {
        guard let inst = instance(i), let id = inst.settings.keymap else { return nil }
        if selection == i, editingKeymapID == id, let km = editingKeymap { return km }
        return try? library.resolve(id).keymap
    }

    func startKeymapping(_ i: Int, record: Bool = false) {
        guard let store, let inst = instance(i) else { return }
        guard state(i) == .running else { errorMessage = "Start the instance first."; return }
        guard let km = playKeymap(i) else { errorMessage = "Choose a keymap in the Controls tab first."; return }
        guard sessions[i] == nil, busy[i] == nil else { return }
        busy[i] = "Starting key mapping…"
        let report: (String) -> Void = { [weak self] msg in self?.sessionStatus[i] = msg }
        // Let the busy label draw: the session pushes touchd and opens the touch channel.
        DispatchQueue.main.async {
            defer { self.busy[i] = nil }
            do {
                let session: KeymapSession
                if #available(macOS 15, *), let player = self.nativePlayers[i] as? NativePlayerSessionController {
                    session = try MainActor.assumeIsolated {
                        let sink = try player.acquireKeymapInput()
                        do {
                            return try KeymapSession(instance: inst, store: store, keymap: km, record: record,
                                sink: sink, inputSize: try player.keymapInputSize(),
                                windowProvider: { MainActor.assumeIsolated { player.keymapWindowState() } },
                                hintParentWindow: player.player.window,
                                onStatus: report)
                        } catch {
                            player.releaseKeymapInput()
                            throw error
                        }
                    }
                } else {
                    session = try KeymapSession(instance: inst, store: store, keymap: km, record: record, onStatus: report)
                }
                self.sessions[i] = session
                if #available(macOS 15, *), let player = self.nativePlayers[i] as? NativePlayerSessionController {
                    MainActor.assumeIsolated {
                        player.player.setKeymappingEnabled(true)
                        session.setHintOpacity(player.player.hintOpacity)
                    }
                }
                self.activeSessions.insert(i)
                if record { self.recordingSessions.insert(i) }
                self.sessionStatus[i] = "Key mapping on with “\(km.name)”. Click the game window; \(KeyNames.shortLabel(km.resolvedLookToggle)) toggles aim, F12 hides hints."
            } catch {
                self.errorMessage = "\(error)"
            }
        }
    }

    func stopKeymapping(_ i: Int) {
        if #available(macOS 15, *), let player = nativePlayers[i] as? NativePlayerSessionController {
            MainActor.assumeIsolated { player.player.setKeymappingEnabled(false) }
        }
        guard let session = sessions.removeValue(forKey: i) else { return }
        let recording = session.stop()
        if #available(macOS 15, *), let player = nativePlayers[i] as? NativePlayerSessionController {
            MainActor.assumeIsolated { player.releaseKeymapInput() }
        }
        activeSessions.remove(i)
        recordingSessions.remove(i)
        sessionStatus[i] = nil
        if let recording, !recording.entries.isEmpty {
            let dir = recordingsDir(i)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let id = instance(i)?.settings.keymap ?? "keymap"
            let url = dir.appendingPathComponent("\(id)__\(fmt.string(from: Date())).txt")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try recording.serialized().write(to: url, atomically: true, encoding: .utf8)
                notice = "Saved recording (\(recording.entries.count) inputs, \(Int(recording.duration / 1000)) s)"
            } catch { errorMessage = "Could not save the recording: \(error)" }
        }
    }

    func stopAllKeymapping() { for i in Array(sessions.keys) { stopKeymapping(i) } }

    func recordingsDir(_ i: Int) -> URL { paths.instanceDir(i).appendingPathComponent("recordings") }

    func recordings(_ i: Int) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDir(i), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Plays a recording back through the keymap it was made with (or the current one).
    func replay(_ i: Int, file: URL) {
        guard busy[i] == nil else { return }
        guard let store, let inst = instance(i) else { return }
        guard state(i) == .running else { errorMessage = "Start the instance first."; return }
        guard sessions[i] == nil else { errorMessage = "Turn key mapping off before replaying."; return }
        let recordedID = file.lastPathComponent.components(separatedBy: "__").first
        guard let km = recordedID.flatMap({ try? library.resolve($0).keymap }) ?? playKeymap(i) else {
            errorMessage = "The keymap this recording was made with is gone."
            return
        }
        let s = inst.settings
        if #available(macOS 15, *), let player = nativePlayers[i] as? NativePlayerSessionController {
            do {
                let recording = try InputRecording.parse(String(contentsOf: file, encoding: .utf8))
                busy[i] = "Replaying \(file.deletingPathExtension().lastPathComponent)…"
                try MainActor.assumeIsolated {
                    try player.replay(recording, keymap: km, sensitivity: s.mouseSensitivity) { [weak self] result in
                        guard let self else { return }
                        if case .failure(let error) = result, !(error is CancellationError) {
                            self.errorMessage = "Replay failed: \(error)"
                        }
                        if self.busy[i]?.hasPrefix("Replaying ") == true { self.busy[i] = nil }
                    }
                }
            } catch {
                busy[i] = nil
                errorMessage = "Replay failed: \(error)"
            }
            return
        }
        perform(i, "Replaying \(file.deletingPathExtension().lastPathComponent)…") {
            let recording = try InputRecording.parse(String(contentsOf: file, encoding: .utf8))
            let sink = try DeviceSink(adb: ADB(sdk: store.sdk, serial: inst.ports.serial), width: s.width, height: s.height)
            let driver = Driver(engine: KeymapEngine(keymap: km, screenWidth: s.width, screenHeight: s.height,
                                                     sensitivity: s.mouseSensitivity), sink: sink)
            driver.replay(recording)
            driver.stop()
        }
    }

    func deleteRecording(_ url: URL) {
        do { try FileManager.default.removeItem(at: url); objectWillChange.send() } catch { errorMessage = "\(error)" }
    }
}
