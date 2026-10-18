import SwiftUI
import KestrelKeymap

extension Binding {
    /// A non-optional view of an optional value; writing stores it.
    func or<T>(_ fallback: T) -> Binding<T> where Value == T? {
        Binding<T>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

/// Edits the selected control and the keymap's own settings.
struct ControlInspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let i = model.selectedControl, let km = model.editingKeymap, km.controls.indices.contains(i) {
                controlSections(i, km.controls[i])
            } else {
                Section {
                    Text("Click a control on the screen to edit it, or add one with the + menu. Drag controls to move them.")
                        .foregroundStyle(.secondary)
                }
            }
            keymapSection
        }
        .formStyle(.grouped)
    }

    // MARK: Bindings

    /// A binding to the payload of control `i` while it keeps the same type.
    private func payload<T>(_ i: Int, _ extract: @escaping (Control) -> T?, _ wrap: @escaping (T) -> Control, _ initial: T) -> Binding<T> {
        Binding(get: {
            guard let km = model.editingKeymap, km.controls.indices.contains(i), let v = extract(km.controls[i]) else { return initial }
            return v
        }, set: { v in model.editKeymap { $0.update(i, to: wrap(v)) } })
    }

    private func keymapField<T>(_ kp: WritableKeyPath<Keymap, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { model.editingKeymap?[keyPath: kp] ?? fallback },
                set: { v in model.editKeymap { e in var k = e.keymap; k[keyPath: kp] = v; e.replace(with: k) } })
    }

    // MARK: Control

    @ViewBuilder
    private func controlSections(_ i: Int, _ c: Control) -> some View {
        Section {
            HStack {
                Label(ControlKind.title(c.typeName), systemImage: ControlKind.icon(c.typeName)).font(.headline)
                Spacer()
                Button(role: .destructive) { model.deleteSelectedControl() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this control")
            }
        }
        switch c {
        case .tap(let v):
            let b = payload(i, { if case .tap(let x) = $0 { return x }; return nil }, Control.tap, v)
            Section {
                RequiredKeyField(title: "Key", key: b.key)
                PointField(title: "Position", point: b.at)
                ModePicker(mode: b.mode)
                LabelField(label: b.label)
            }
        case .turbo(let v):
            let b = payload(i, { if case .turbo(let x) = $0 { return x }; return nil }, Control.turbo, v)
            Section {
                RequiredKeyField(title: "Key", key: b.key)
                PointField(title: "Position", point: b.at)
                ValueSlider(title: "Every", value: b.intervalMs, range: 20...1000, step: 10, format: "%.0f ms")
                ModePicker(mode: b.mode)
                LabelField(label: b.label)
            }
        case .joystick(let v):
            let b = payload(i, { if case .joystick(let x) = $0 { return x }; return nil }, Control.joystick, v)
            Section("Keys") {
                KeyField(title: "Up", key: b.up, optional: true)
                KeyField(title: "Down", key: b.down, optional: true)
                KeyField(title: "Left", key: b.left, optional: true)
                KeyField(title: "Right", key: b.right, optional: true)
                StickPicker(stick: b.stick)
            }
            Section("Stick") {
                PointField(title: "Centre", point: b.center)
                ValueSlider(title: "Radius", value: b.radius, range: 0.01...0.5, step: 0.005, format: "%.3f")
                ValueSlider(title: "Push distance", value: b.travel.or(1), range: 0.25...4, step: 0.05, format: "%.2f×")
            }
            Section("Walk and sprint") {
                KeyField(title: "Walk key", key: b.walkKey, optional: true)
                ValueSlider(title: "Walk speed", value: b.walkScale.or(0.5), range: 0.1...1, step: 0.05)
                KeyField(title: "Sprint key", key: b.sprintKey, optional: true)
                ValueSlider(title: "Sprint push", value: b.sprintScale.or(1.6), range: 1...3, step: 0.1)
            }
        case .look(let v):
            let b = payload(i, { if case .look(let x) = $0 { return x }; return nil }, Control.look, v)
            Section("Aim") {
                PointField(title: "Drag area centre", point: b.center)
                ValueSlider(title: "Drag radius", value: b.radius, range: 0.02...0.5, step: 0.01)
                ValueSlider(title: "Sensitivity", value: b.sensitivity, range: 0.1...5, step: 0.05)
                Text("\(KeyNames.shortLabel(model.editingKeymap?.resolvedLookToggle ?? "Grave")) toggles aiming while playing; holding \(KeyNames.shortLabel(model.editingKeymap?.resolvedFreeCursor ?? "Alt")) frees the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Scope") {
                KeyField(title: "Scope key", key: b.scopeKey, optional: true)
                ValueSlider(title: "Scoped sensitivity", value: b.scopeSensitivity.or(0.5), range: 0.1...1, step: 0.05)
            }
            Section("Gamepad") {
                StickPicker(stick: b.stick)
                ValueSlider(title: "Stick speed", value: b.stickSpeed.or(1000), range: 100...3000, step: 50, format: "%.0f")
            }
        case .skill(let v):
            let b = payload(i, { if case .skill(let x) = $0 { return x }; return nil }, Control.skill, v)
            Section {
                RequiredKeyField(title: "Key", key: b.key)
                PointField(title: "Button", point: b.at)
                ValueSlider(title: "Aim radius", value: b.radius, range: 0...0.3, step: 0.005, format: "%.3f")
                Toggle("Cast on press", isOn: b.quickCast.or(false))
                ModePicker(mode: b.mode)
                LabelField(label: b.label)
            }
            Section("Cancel") {
                KeyField(title: "Hold to cancel", key: Binding(get: { b.wrappedValue.cancelKey }, set: { k in
                    b.wrappedValue.cancelKey = k
                    if k != nil && b.wrappedValue.cancelAt == nil { b.wrappedValue.cancelAt = NPoint(0.9, 0.2) }
                }), optional: true)
                if b.wrappedValue.cancelKey != nil {
                    PointField(title: "Cancel area", point: b.cancelAt.or(NPoint(0.9, 0.2)))
                }
            }
        case .swipe(let v):
            let b = payload(i, { if case .swipe(let x) = $0 { return x }; return nil }, Control.swipe, v)
            Section {
                RequiredKeyField(title: "Key", key: b.key)
                PointField(title: "From", point: b.from)
                PointField(title: "To", point: b.to)
                ValueSlider(title: "Duration", value: b.durationMs, range: 10...2000, step: 10, format: "%.0f ms")
                ModePicker(mode: b.mode)
                LabelField(label: b.label)
            }
        case .combo(let v):
            let b = payload(i, { if case .combo(let x) = $0 { return x }; return nil }, Control.combo, v)
            Section {
                RequiredKeyField(title: "Key", key: b.key)
                ValueSlider(title: "Between taps", value: b.intervalMs, range: 20...1000, step: 10, format: "%.0f ms")
                ModePicker(mode: b.mode)
                LabelField(label: b.label)
            }
            Section("Taps, in order") {
                ForEach(b.wrappedValue.points.indices, id: \.self) { k in
                    HStack {
                        PointField(title: "\(k + 1)", point: Binding(
                            get: { b.wrappedValue.points.indices.contains(k) ? b.wrappedValue.points[k] : NPoint(0.5, 0.5) },
                            set: { if b.wrappedValue.points.indices.contains(k) { b.wrappedValue.points[k] = $0 } }))
                        Button(role: .destructive) { b.wrappedValue.points.remove(at: k) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(b.wrappedValue.points.count <= 1)
                    }
                }
                Button("Add Tap") {
                    let last = b.wrappedValue.points.last ?? NPoint(0.5, 0.5)
                    b.wrappedValue.points.append(NPoint(last.x + 0.05, last.y).clamped)
                }
            }
        case .scroll(let v):
            let b = payload(i, { if case .scroll(let x) = $0 { return x }; return nil }, Control.scroll, v)
            Section {
                KeyField(title: "Up key", key: b.upKey, optional: true)
                KeyField(title: "Down key", key: b.downKey, optional: true)
                Text("None means the mouse wheel.").font(.caption).foregroundStyle(.secondary)
                PointField(title: "Position", point: b.at)
                ValueSlider(title: "Distance", value: b.distance, range: 0.02...0.8, step: 0.01)
                ValueSlider(title: "Duration", value: b.durationMs.or(120), range: 10...1000, step: 10, format: "%.0f ms")
                ModePicker(mode: b.mode)
            }
        case .pinch(let v):
            let b = payload(i, { if case .pinch(let x) = $0 { return x }; return nil }, Control.pinch, v)
            Section {
                RequiredKeyField(title: "Zoom in", key: b.inKey)
                RequiredKeyField(title: "Zoom out", key: b.outKey)
                PointField(title: "Centre", point: b.center)
                ValueSlider(title: "Spread", value: b.spread, range: 0.02...0.5, step: 0.01)
                ValueSlider(title: "Duration", value: b.durationMs.or(180), range: 20...1000, step: 10, format: "%.0f ms")
                ModePicker(mode: b.mode)
            }
        case .macro(let v):
            let b = payload(i, { if case .macro(let x) = $0 { return x }; return nil }, Control.macro, v)
            Section {
                RequiredKeyField(title: "Key", key: b.key)
                Toggle("Repeat while held", isOn: b.loop.or(false))
                ModePicker(mode: b.mode)
                LabelField(label: b.label)
            }
            Section("Script") {
                TextEditor(text: b.script)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                if let problem = macroProblem(b.wrappedValue.script) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("tap X Y · press F X Y · move F X Y · release F · swipe X1 Y1 X2 Y2 MS · wait MS · repeat N … end. Coordinates go from 0 to 1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func macroProblem(_ script: String) -> String? {
        do {
            _ = try MacroScript.compile(MacroScript.parse(script))
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Keymap

    @ViewBuilder
    private var keymapSection: some View {
        if model.editingKeymap != nil {
            Section("Keymap") {
                TextField("Name", text: keymapField(\.name, ""))
                TextField("Game package", text: Binding(
                    get: { model.editingKeymap?.package ?? "" },
                    set: { v in model.editKeymap { e in var k = e.keymap; k.package = v.isEmpty ? nil : v; e.replace(with: k) } }),
                          prompt: Text("e.g. com.pubg.imobile"))
                    .help("The Play button in Apps uses this keymap for that game")
                KeyField(title: "Toggle aiming", key: Binding(
                    get: { model.editingKeymap?.lookToggleKey ?? "Grave" },
                    set: { v in model.editKeymap { e in var k = e.keymap; k.lookToggleKey = v == "Grave" ? nil : v; e.replace(with: k) } }))
                KeyField(title: "Hold to free cursor", key: Binding(
                    get: { model.editingKeymap?.freeCursorKey ?? "Alt" },
                    set: { v in model.editKeymap { e in var k = e.keymap; k.freeCursorKey = v == "Alt" ? nil : v; e.replace(with: k) } }))
                Toggle("Start with aiming on", isOn: keymapField(\.startInLook, nil).or(false))
                ValueSlider(title: "Mouse sensitivity", value: keymapField(\.mouseSensitivity, nil).or(1), range: 0.1...5, step: 0.05)
                LabeledContent("Controls", value: "\(model.editingKeymap?.controls.count ?? 0)")
            }
        }
    }
}

/// Which gamepad stick also drives a joystick or aim control.
struct StickPicker: View {
    @Binding var stick: String?

    var body: some View {
        Picker("Gamepad stick", selection: Binding(get: { stick ?? "" }, set: { stick = $0.isEmpty ? nil : $0 })) {
            Text("None").tag("")
            Text("Left stick").tag("left")
            Text("Right stick").tag("right")
        }
    }
}
