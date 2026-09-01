import Foundation

public enum ProfileRegistryError: Error, Equatable, LocalizedError, Sendable {
    case invalidAlias
    case invalidProfileID
    case writeVerificationFailed
    case missingProfile

    public var errorDescription: String? {
        switch self {
        case .invalidAlias: return "Profile alias must not be empty"
        case .invalidProfileID: return "Profile ID is invalid"
        case .writeVerificationFailed: return "Profile metadata could not be verified"
        case .missingProfile: return "Profile does not exist"
        }
    }
}

/// Stores only profile identity and display metadata. Codex credential files are deliberately opaque.
public final class ProfileRegistry: @unchecked Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) throws {
        self.rootDirectory = (rootDirectory ?? Self.defaultRootDirectory()).standardizedFileURL
        try Self.ensureSecureDirectory(self.rootDirectory, permissions: 0o700)
    }

    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CodexTouchBar/Profiles", isDirectory: true)
    }

    public func register(alias: String, id: UUID = UUID()) throws -> AccountProfile {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlias.isEmpty else { throw ProfileRegistryError.invalidAlias }
        let profileDirectory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let codexHome = profileDirectory.appendingPathComponent("codex-home", isDirectory: true)
        try Self.ensureSecureDirectory(profileDirectory, permissions: 0o700)
        try Self.ensureSecureDirectory(codexHome, permissions: 0o700)

        let profile = AccountProfile(id: id, alias: normalizedAlias, codexHome: codexHome)
        try writeMetadata(profile)
        guard try self.profile(id: id) == profile else { throw ProfileRegistryError.writeVerificationFailed }
        return profile
    }

    public func profile(id: UUID) throws -> AccountProfile? {
        let metadataURL = metadataURL(for: id)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let data = try Data(contentsOf: metadataURL)
        let profile = try JSONDecoder().decode(AccountProfile.self, from: data)
        let expectedHome = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("codex-home", isDirectory: true).standardizedFileURL
        let resolvedHome = profile.codexHome.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let homeAttributes = try? FileManager.default.attributesOfItem(atPath: profile.codexHome.path)
        let homePermissions = (homeAttributes?[.posixPermissions] as? NSNumber)?.intValue
        guard profile.id == id,
              profile.codexHome.standardizedFileURL.path == expectedHome.path,
              resolvedHome.hasPrefix(rootPrefix),
              (homeAttributes?[.type] as? FileAttributeType) == .typeDirectory,
              homePermissions == 0o700 else {
            throw ProfileRegistryError.invalidProfileID
        }
        return profile
    }

    public func allProfiles() throws -> [AccountProfile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.hasDirectoryPath }
            .compactMap { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                return try profile(id: id)
            }
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private func metadataURL(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("profile.json")
    }

    private func writeMetadata(_ profile: AccountProfile) throws {
        let url = metadataURL(for: profile.id)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try JSONDecoder().decode(AccountProfile.self, from: Data(contentsOf: url)) == profile else {
            throw ProfileRegistryError.writeVerificationFailed
        }
    }

    private static func ensureSecureDirectory(_ url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actual = (attrs[.posixPermissions] as? NSNumber)?.intValue
        guard actual == permissions else { throw ProfileRegistryError.writeVerificationFailed }
    }
}
