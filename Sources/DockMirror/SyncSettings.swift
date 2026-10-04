import Foundation

/// How often DockMirror looks at the other Macs' files.
///
/// Edits to this Mac's Dock don't wait for it: they are noticed as they
/// happen and shared straight away (except in `manual`). A longer interval
/// only means other Macs' edits arrive here later, in exchange for less
/// reading of iCloud Drive and fewer wake-ups.
enum SyncInterval: Int, CaseIterable {
    case everyMinute = 60
    case every5Minutes = 300
    case every15Minutes = 900
    case every30Minutes = 1800
    case hourly = 3600
    /// Nothing happens until Sync Now is clicked — not even for edits here.
    case manual = 0

    var title: String {
        switch self {
        case .everyMinute: return "Every Minute"
        case .every5Minutes: return "Every 5 Minutes"
        case .every15Minutes: return "Every 15 Minutes"
        case .every30Minutes: return "Every 30 Minutes"
        case .hourly: return "Every Hour"
        case .manual: return "Only When I Click Sync Now"
        }
    }

    var seconds: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue) }
}

enum SyncSettings {
    private static let key = "sync.checkInterval"

    /// Every minute unless changed, which is how 1.0.0 behaved.
    static var checkInterval: SyncInterval {
        get {
            guard let raw = UserDefaults.standard.object(forKey: key) as? Int else { return .everyMinute }
            return SyncInterval(rawValue: raw) ?? .everyMinute
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
