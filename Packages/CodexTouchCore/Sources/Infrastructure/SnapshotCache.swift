import Foundation

public final class SnapshotCache: @unchecked Sendable {
    private struct CacheRecord: Codable, Equatable {
        let profileID: UUID
        let quota: QuotaSnapshot
        let usage: UsageSnapshot
        let savedAt: Date
    }

    public let directory: URL
    public let retention: TimeInterval

    public init(directory: URL, retention: TimeInterval = 30 * 24 * 60 * 60) throws {
        self.directory = directory.standardizedFileURL
        self.retention = retention
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }

    public func write(profileID: UUID, quota: QuotaSnapshot, usage: UsageSnapshot, now: Date = Date()) throws {
        let record = CacheRecord(profileID: profileID, quota: quota, usage: usage, savedAt: now)
        let url = fileURL(for: profileID)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try read(profileID: profileID)?.savedAt == now else { throw ProfileRegistryError.writeVerificationFailed }
        try prune(now: now)
    }

    public func read(profileID: UUID) throws -> (quota: QuotaSnapshot, usage: UsageSnapshot, savedAt: Date)? {
        let url = fileURL(for: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw ProfileRegistryError.writeVerificationFailed
        }
        let record = try JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: url))
        guard record.profileID == profileID else { return nil }
        return (record.quota, record.usage, record.savedAt)
    }

    public func prune(now: Date = Date()) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls where url.pathExtension == "json" {
            guard let record = try? JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: url)) else { continue }
            if now.timeIntervalSince(record.savedAt) > retention { try FileManager.default.removeItem(at: url) }
        }
    }

    private func fileURL(for profileID: UUID) -> URL { directory.appendingPathComponent("\(profileID.uuidString).json") }
}
