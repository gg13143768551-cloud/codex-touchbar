import Foundation

public struct ConfigWriteResult: Equatable, Sendable {
    public let selection: ModelSelection
    public let readbackMatched: Bool

    public init(selection: ModelSelection, readbackMatched: Bool) {
        self.selection = selection
        self.readbackMatched = readbackMatched
    }
}

public protocol CodexGateway: Sendable {
    func readSnapshot() async throws -> AppSnapshot
    func writeSelection(model: String, effort: String) async throws -> ConfigWriteResult
    func startTurn(threadID: String, input: String, selection: ModelSelection) async throws
    func stop() async
}

public protocol CodexSessionFactory: Sendable {
    func open(profile: AccountProfile) async throws -> any CodexGateway
}

public enum GatewayError: Error, Equatable, LocalizedError, Sendable {
    case unsupported(String)
    case invalidResponse(String)
    case notAuthenticated
    case profileMismatch
    case processFailed(String)
    case timeout(String)
    case configurationNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .unsupported(let value): return "Unsupported: \(value)"
        case .invalidResponse(let value): return "Invalid response: \(value)"
        case .notAuthenticated: return "Authentication required"
        case .profileMismatch: return "The server is not using the selected profile home"
        case .processFailed(let value): return "Codex process failed: \(value)"
        case .timeout(let value): return "Timed out: \(value)"
        case .configurationNotConfirmed: return "Configuration was not confirmed by the server"
        }
    }
}
