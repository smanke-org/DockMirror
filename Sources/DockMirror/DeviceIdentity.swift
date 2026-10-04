import CryptoKit
import Foundation
import IOKit
import SystemConfiguration

/// A stable identity for this Mac that is safe to write into iCloud Drive.
enum DeviceIdentity {
    /// Derived from the hardware UUID, so it is stable across reinstalls and is
    /// *not* carried to a new Mac by Migration Assistant — a UUID generated and
    /// kept in UserDefaults would be, and two Macs would then share one file.
    /// Hashed so the raw hardware identifier never leaves the machine.
    static let deviceID: String = {
        let source = hardwareUUID() ?? fallbackUUID()
        let digest = SHA256.hash(data: Data("\(source):\(AppInfo.bundleIdentifier)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }()

    /// The name set in System Settings › General › About. Deliberately not
    /// `Host.current().localizedName`, which can block for seconds on DNS.
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Only reached if IOKit won't give up the hardware UUID.
    private static func fallbackUUID() -> String {
        let key = "sync.fallbackDeviceUUID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
