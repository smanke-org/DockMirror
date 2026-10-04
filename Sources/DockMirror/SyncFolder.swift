import DockMirrorCore
import Foundation

/// The shared folder in iCloud Drive: one `<deviceID>.json` per Mac.
///
/// Each Mac writes only its own file, so iCloud never has two writers to
/// reconcile. The app is unsandboxed, so this is ordinary file I/O — no iCloud
/// entitlement or provisioning profile is involved.
enum SyncFolder {
    /// `iCloud Drive/DockMirror/Devices`, or nil when iCloud Drive is off.
    /// `DOCKMIRROR_SYNC_FOLDER` redirects it, so a debug build — which shares
    /// this Mac's device ID — can be tested without touching the real file.
    static func url() -> URL? {
        if let override = ProcessInfo.processInfo.environment["DOCKMIRROR_SYNC_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.isWritableFile(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent("DockMirror/Devices", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func write(_ record: DeviceRecord, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(record.deviceID).json")
        let data = try encoder.encode(record)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// Every other Mac's record. Files iCloud has evicted are asked back and
    /// reported in `downloading`, so the caller can keep its last copy.
    static func readOthers(in folder: URL, excluding ownID: String) -> (records: [DeviceRecord], downloading: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var records: [DeviceRecord] = []
        var downloading = Set<String>()

        for name in names {
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                let id = String(real.dropLast(".json".count))
                guard id != ownID else { continue }
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                downloading.insert(id)
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix("."),
                  let data = coordinatedRead(folder.appendingPathComponent(name)),
                  let record = try? decoder.decode(DeviceRecord.self, from: data),
                  record.deviceID != ownID else { continue }
            records.append(record)
        }
        return (records, downloading)
    }

    /// Removes a Mac's file, for "Forget This Mac". A Mac that is still
    /// running DockMirror simply writes it again.
    static func remove(deviceID: String, in folder: URL) throws {
        let url = folder.appendingPathComponent("\(deviceID).json")
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { removeError = error }
        }
        if let error = coordinationError ?? removeError { throw error }
    }

    private static func coordinatedRead(_ url: URL) -> Data? {
        var coordinationError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            data = try? Data(contentsOf: target)
        }
        return data
    }
}
