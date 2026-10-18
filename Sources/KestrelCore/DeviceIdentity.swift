import Foundation

/// A complete, internally consistent phone identity: the full set of
/// guest-visible values that together should read as one real device.
///
/// Games correlate these values (a Samsung model must have a Samsung
/// fingerprint, board and bootloader), so a profile supplies all of them at
/// once rather than spoofing brand/model alone. Values are exposed to the
/// guest as emulator `-prop` overrides at launch (same mechanism the
/// existing brand/model presets use) and as `hw.glrenderer` / `hw.glvendor`
/// in the AVD config.
///
/// Scope: local client-side presentation only. This does not and cannot
/// influence server-side hardware attestation (Play Integrity), which is
/// unaffected by any property override.
public struct DeviceIdentity: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let brand: String
    public let manufacturer: String
    public let model: String
    /// Device codename, e.g. `e3q`.
    public let device: String
    /// Product name, e.g. `e3qxxx`.
    public let product: String
    /// Board / platform, e.g. `qcom`.
    public let board: String
    /// Hardware string, e.g. `qcom`.
    public let hardware: String
    /// Bootloader version string.
    public let bootloader: String
    /// Full `brand/product/device:version/buildid/incremental:type/tags`
    /// fingerprint; partition fingerprints are derived from it.
    public let fingerprint: String
    /// GPU renderer/vendor strings reported through GL/GLES.
    public let glRenderer: String
    public let glVendor: String

    public init(id: String, label: String, brand: String, manufacturer: String,
                model: String, device: String, product: String, board: String,
                hardware: String, bootloader: String, fingerprint: String,
                glRenderer: String, glVendor: String) {
        self.id = id
        self.label = label
        self.brand = brand
        self.manufacturer = manufacturer
        self.model = model
        self.device = device
        self.product = product
        self.board = board
        self.hardware = hardware
        self.bootloader = bootloader
        self.fingerprint = fingerprint
        self.glRenderer = glRenderer
        self.glVendor = glVendor
    }

    /// `ro.build.description` derived from the fingerprint parts.
    public var buildDescription: String {
        "\(product)-user \(fingerprint)"
            .replacingOccurrences(of: "\(product)-user \(brand)/\(product)/\(device):", with: "")
    }

    /// The complete `-prop` list. Keys mirror every identity value the
    /// detection probe measured leaking (`research/stealth/FINDINGS.md`
    /// vectors 1-13), including the per-partition product/model/name and
    /// fingerprint variants that stock images expose.
    public var properties: [(String, String)] {
        let version = fingerprint.split(separator: ":").count > 1
            ? String(fingerprint.split(separator: ":")[1].split(separator: "/").first ?? "16")
            : "16"
        var props: [(String, String)] = [
            ("ro.product.brand", brand),
            ("ro.product.manufacturer", manufacturer),
            ("ro.product.model", model),
            ("ro.product.name", product),
            ("ro.product.device", device),
            ("ro.product.board", board),
            ("ro.product.hardware", hardware),
            ("ro.hardware", hardware),
            ("ro.boot.hardware", hardware),
            ("ro.board.platform", board),
            ("ro.bootloader", bootloader),
            ("ro.build.characteristics", "default"),
            ("ro.build.fingerprint", fingerprint),
            ("ro.build.flavor", "\(product)-user"),
            ("ro.build.version.release", version),
        ]
        // Partition-scoped model/name/fingerprint properties (the stock image
        // exposes these under the sdk_gphone identity; a real device's all
        // agree with the main values).
        for partition in ["product", "odm", "vendor", "system", "system_ext", "system_dlkm", "vendor_dlkm"] {
            props += [
                ("ro.product.\(partition).brand", brand),
                ("ro.product.\(partition).manufacturer", manufacturer),
                ("ro.product.\(partition).model", model),
                ("ro.product.\(partition).name", product),
                ("ro.product.\(partition).device", device),
            ]
        }
        props += [
            ("ro.product.build.fingerprint", fingerprint),
            ("ro.system.build.fingerprint", fingerprint),
            ("ro.system_ext.build.fingerprint", fingerprint),
            ("ro.system_dlkm.build.fingerprint", fingerprint),
            ("ro.vendor.build.fingerprint", fingerprint),
            ("ro.vendor_dlkm.build.fingerprint", fingerprint),
            ("ro.odm.build.fingerprint", fingerprint),
        ]
        return props
    }

    public static let all: [DeviceIdentity] = [
        DeviceIdentity(
            id: "galaxys24ultra",
            label: "Galaxy S24 Ultra",
            brand: "samsung", manufacturer: "samsung", model: "SM-S928B",
            device: "e3q", product: "e3qxxx", board: "qcom", hardware: "qcom",
            bootloader: "R3C4-08.03.01.5",
            fingerprint: "samsung/e3qxxx/e3q:16/BP2A.250605.031/S928BXXU4BYE3:user/release-keys",
            glRenderer: "Adreno (TM) 740", glVendor: "Qualcomm Technologies Inc."),
        DeviceIdentity(
            id: "oneplus12",
            label: "OnePlus 12",
            brand: "OnePlus", manufacturer: "OnePlus", model: "CPH2581",
            device: "waffle", product: "waffle_eea", board: "qcom", hardware: "qcom",
            bootloader: "unknown",
            fingerprint: "OnePlus/waffle_eea/waffle:16/BP2A.250605.031/14092707:user/release-keys",
            glRenderer: "Adreno (TM) 750", glVendor: "Qualcomm Technologies Inc."),
        DeviceIdentity(
            id: "xiaomi14",
            label: "Xiaomi 14",
            brand: "Xiaomi", manufacturer: "Xiaomi", model: "23127PN0CG",
            device: "houji", product: "houji_eea", board: "qcom", hardware: "qcom",
            bootloader: "unknown",
            fingerprint: "Xiaomi/houji_eea/houji:16/BP2A.250605.031/OS2.0.104.0.VNCEUXM:user/release-keys",
            glRenderer: "Adreno (TM) 750", glVendor: "Qualcomm Technologies Inc."),
    ]

    public static func profile(_ id: String) -> DeviceIdentity? {
        all.first { $0.id == id }
    }
}
