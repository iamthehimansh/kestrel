import AppKit
import SwiftUI
import KestrelKeymap

/// Shows a bound key and changes it: "Press a Key…" captures the next keyboard key or
/// mouse button, and the Mouse / Gamepad submenus pick buttons that are awkward to press.
struct KeyField: View {
    let title: String
    @Binding var key: String?
    var optional = false

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            Menu {
                Button("Press a Key…") { startCapture() }
                Menu("Mouse") {
                    ForEach(KeyNames.mouse, id: \.self) { k in Button(KeyNames.shortLabel(k) + "  " + k) { key = k } }
                }
                Menu("Gamepad") {
                    ForEach(KeyNames.pad, id: \.self) { k in Button(k) { key = k } }
                }
                if optional {
                    Divider()
                    Button("None") { key = nil }
                }
            } label: {
                Text(capturing ? "Press a key…" : (key.map { "\(KeyNames.shortLabel($0))  \($0)" } ?? "None"))
                    .foregroundStyle(capturing ? Color.accentColor : (key == nil ? .secondary : .primary))
            }
            .fixedSize()
        }
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        stopCapture()
        capturing = true
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            guard capturing else { return event }
            var name: String?
            switch event.type {
            case .keyDown:
                if event.keyCode == 0x35 { stopCapture(); return nil } // Esc cancels
                name = KeyNames.macKeyCodes[event.keyCode]
            case .flagsChanged:
                let k = KeyNames.macKeyCodes[event.keyCode]
                let down: Bool
                switch k {
                case "Shift", "RightShift": down = event.modifierFlags.contains(.shift)
                case "Ctrl", "RightCtrl": down = event.modifierFlags.contains(.control)
                case "Alt", "RightAlt": down = event.modifierFlags.contains(.option)
                case "CapsLock": down = true
                default: down = false
                }
                if down { name = k }
            case .rightMouseDown:
                name = "MouseRight"
            case .otherMouseDown:
                switch event.buttonNumber {
                case 2: name = "MouseMiddle"
                case 3: name = "Mouse4"
                case 4: name = "Mouse5"
                default: name = nil
                }
            case .scrollWheel:
                if event.scrollingDeltaY > 0 { name = "WheelUp" } else if event.scrollingDeltaY < 0 { name = "WheelDown" }
            default:
                break
            }
            guard let name else { return event }
            key = name
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        capturing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A key field for a non-optional key.
struct RequiredKeyField: View {
    let title: String
    @Binding var key: String

    var body: some View {
        KeyField(title: title, key: Binding(get: { key }, set: { if let v = $0 { key = v } }))
    }
}

/// Two number fields for a normalized screen position.
struct PointField: View {
    let title: String
    @Binding var point: NPoint

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text("X").foregroundStyle(.secondary)
                TextField("X", value: Binding(get: { point.x }, set: { point = NPoint($0, point.y).clamped }),
                          format: .number.precision(.fractionLength(3)))
                    .frame(width: 64)
                Text("Y").foregroundStyle(.secondary)
                TextField("Y", value: Binding(get: { point.y }, set: { point = NPoint(point.x, $0).clamped }),
                          format: .number.precision(.fractionLength(3)))
                    .frame(width: 64)
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

/// A labelled slider with its value shown.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// When a control is live, as a picker.
struct ModePicker: View {
    @Binding var mode: ControlMode?

    var body: some View {
        Picker("Active", selection: Binding(get: { mode ?? .always }, set: { mode = $0 == .always ? nil : $0 })) {
            Text("Always").tag(ControlMode.always)
            Text("Only while aiming").tag(ControlMode.look)
            Text("Only with a free cursor").tag(ControlMode.cursor)
        }
    }
}

/// An optional label text field ("" clears it).
struct LabelField: View {
    @Binding var label: String?

    var body: some View {
        TextField("Label", text: Binding(get: { label ?? "" }, set: { label = $0.isEmpty ? nil : $0 }),
                  prompt: Text("e.g. Fire, Jump, Reload"))
    }
}
