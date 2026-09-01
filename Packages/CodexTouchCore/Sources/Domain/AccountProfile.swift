import Foundation

public struct AccountProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var alias: String
    public let codexHome: URL

    public init(id: UUID, alias: String, codexHome: URL) {
        self.id = id
        self.alias = alias
        self.codexHome = codexHome.standardizedFileURL
    }
}

public enum AccountKind: String, Codable, Sendable {
    case chatGPT
    case keyAccount
    case amazonBedrock
}

public struct AccountIdentity: Codable, Equatable, Sendable {
    public let kind: AccountKind
    public let maskedEmail: String?
    public let planType: String?

    public init(kind: AccountKind, maskedEmail: String? = nil, planType: String? = nil) {
        self.kind = kind
        self.maskedEmail = maskedEmail
        self.planType = planType
    }
}
