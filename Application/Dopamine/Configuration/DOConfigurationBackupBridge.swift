import Foundation

/// Thin adapter between the Objective-C Dopamine settings screens and the
/// configuration backup implementation carried over from Irisin.
@objc(DOConfigurationBackupBridge)
public final class DOConfigurationBackupBridge: NSObject {
    @objc public static func backups(inDirectory directory: URL) -> [[String: Any]] {
        guard let records = try? ConfigurationBackupStorage.records(in: directory) else { return [] }
        return records.map { record in
            let snapshot = try? ConfigurationBackupStorage.load(from: record.url)
            let bytes = snapshot?.files.values.reduce(0) { $0 + $1.count } ?? 0
            let count = snapshot?.files.count ?? 0
            return [
                "path": record.url.path,
                "name": record.url.lastPathComponent,
                "date": record.created,
                "size": bytes,
                "fileCount": count,
            ]
        }
    }

    @objc public static func createBackup(inDirectory directory: URL, root: String) throws -> URL {
        let engine = ConfigurationBackupEngine(root: root)
        let snapshot = try engine.capture()
        let record = try ConfigurationBackupStorage.publish(snapshot, in: directory, allowPruning: true)
        return record.url
    }

    @objc public static func restoreBackup(atPath path: String, root: String) throws {
        let snapshot = try ConfigurationBackupStorage.load(from: URL(fileURLWithPath: path, isDirectory: true))
        try ConfigurationBackupEngine(root: root).restore(snapshot, preferences: true, sources: true)
    }
}
