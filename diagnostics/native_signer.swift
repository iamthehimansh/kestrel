// Diagnostic pipe adapter for the shipping CryptoKit signer. Never run with stdout
// attached to a terminal: responses include ephemeral bearer credentials.
import Darwin
import Foundation

@main
struct NativeSignerProbe {
    static func main() {
        guard isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else {
            fputs("Native signer requires private input/output pipes\n", stderr)
            exit(2)
        }
        let signer = EmulatorTokenSigner()
        var requests = 0
        while let line = readLine() {
            requests += 1
            guard requests <= 64, line.utf8.count <= 1024 else { exit(2) }
            do {
                guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                      let operation = request["operation"] else { throw KestrelError.invalid("Bad request") }
                let response: [String: Any]
                switch operation {
                case "public":
                    response = ["jwks": try JSONSerialization.jsonObject(with: signer.publicKeySet()),
                                "policy": try JSONSerialization.jsonObject(with: EmulatorTokenSigner.accessPolicy()),
                                "key_id": signer.keyID]
                case "token":
                    guard let name = request["method"], let method = EmulatorRPCMethod(rawValue: name) else {
                        throw KestrelError.invalid("Unsupported method")
                    }
                    let mode = request["mode"] ?? "valid"
                    guard ["valid", "expired", "wrong"].contains(mode) else {
                        throw KestrelError.invalid("Unsupported diagnostic mode")
                    }
                    let selected: EmulatorRPCMethod = mode == "wrong"
                        ? (method == .getScreenshot ? .streamScreenshot : .getScreenshot) : method
                    let date = mode == "expired" ? Date().addingTimeInterval(-180) : Date()
                    response = ["token": try signer.token(for: selected, now: date, lifetime: 60)]
                default: throw KestrelError.invalid("Unsupported operation")
                }
                let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            } catch {
                // Do not print requests, credentials or crypto-library error details.
                FileHandle.standardOutput.write(Data("{\"error\":\"request rejected\"}\n".utf8))
            }
        }
    }
}
