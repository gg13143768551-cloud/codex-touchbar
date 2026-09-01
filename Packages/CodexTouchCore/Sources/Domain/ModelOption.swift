import Foundation

public struct ReasoningEffortOption: Codable, Equatable, Sendable {
    public let value: String
    public let description: String

    public init(value: String, description: String) {
        self.value = value
        self.description = description
    }
}

public struct ModelOption: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let model: String
    public let displayName: String
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [ReasoningEffortOption]
    public let hidden: Bool
    public let isDefault: Bool

    public init(
        id: String,
        model: String,
        displayName: String,
        defaultReasoningEffort: String,
        supportedReasoningEfforts: [ReasoningEffortOption],
        hidden: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.hidden = hidden
        self.isDefault = isDefault
    }

    public func supports(effort: String?) -> Bool {
        guard let effort else { return false }
        return supportedReasoningEfforts.contains { $0.value == effort }
    }

    public func compatibleEffort(preferred: String?) -> String {
        if let preferred, supports(effort: preferred) { return preferred }
        return defaultReasoningEffort
    }
}

public struct ModelSelection: Codable, Equatable, Sendable {
    public let model: String
    public let effort: String
    public let confirmed: Bool

    public init(model: String, effort: String, confirmed: Bool) {
        self.model = model
        self.effort = effort
        self.confirmed = confirmed
    }
}
