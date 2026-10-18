import Foundation

/// Native streaming is availability-gated independently of the legacy app/CLI.
@available(macOS 15, *)
public enum EmulatorStreamProtocol {
    public static let service = "android.emulation.control.EmulatorController"
}
