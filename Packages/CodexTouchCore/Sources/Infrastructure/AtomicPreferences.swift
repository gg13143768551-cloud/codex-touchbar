import Foundation

public struct Preferences: Codable, Equatable, Sendable {
    public var selectedProfileID: UUID?
    public var oneTouchEnabled: Bool
    public var orderedProfileIDs: [UUID]
    public var codexExecutablePath: URL?

    public init(selectedProfileID: UUID? = nil, oneTouchEnabled: Bool = false, orderedProfileIDs: [UUID] = [], codexExecutablePath: URL? = nil) {
        self.selectedProfileID = selectedProfileID
        self.oneTouchEnabled = oneTouchEnabled
        self.orderedProfileIDs = orderedProfileIDs
        self.codexExecutablePath = codexExecutablePath
    }
}

public final class AtomicPreferences: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL.standardizedFileURL
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func read() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Preferences() }
        try Self.verifySecureRegularFile(fileURL)
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: fileURL))
    }

    @discardableResult
    public func write(_ preferences: Preferences) throws -> Preferences {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(preferences)
        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent(".preferences-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let readback = try read()
        guard readback == preferences else { throw ProfileRegistryError.writeVerificationFailed }
        return readback
    }

    @discardableResult
    public func setSelectedProfileID(_ id: UUID) throws -> Preferences {
        var current = try read()
        current.selectedProfileID = id
        return try write(current)
    }

    private static func verifySecureRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw ProfileRegistryError.writeVerificationFailed
        }
    }
}
