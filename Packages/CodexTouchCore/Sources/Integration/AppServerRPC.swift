import Foundation

public struct JSONRPCErrorPayload: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCMessage: Codable, Equatable, Sendable {
    /// Codex app-server uses JSON-RPC-style JSONL without requiring a
    /// `jsonrpc` member. Keep it optional so conventional 2.0 envelopes are
    /// accepted while outgoing Codex requests omit the field.
    public let jsonrpc: String?
    public let id: Int?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCErrorPayload?

    public init(
        jsonrpc: String? = nil,
        id: Int? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCErrorPayload? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

public struct AppServerNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

public enum AppServerRPCError: Error, Equatable, LocalizedError, Sendable {
    case methodNotFound(String)
    case remote(code: Int, message: String)
    case malformedMessage
    case notStarted
    case terminated(Int32)

    public var errorDescription: String? {
        switch self {
        case .methodNotFound(let method): return "Method not found: \(method)"
        case .remote(_, let message): return message
        case .malformedMessage: return "Malformed app-server message"
        case .notStarted: return "App-server is not running"
        case .terminated(let status): return "App-server exited (\(status))"
        }
    }
}

public protocol AppServerRPC: Sendable {
    func start() async throws
    func request(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    func notify(method: String, params: JSONValue?) async throws
    func notificationStream() async -> AsyncStream<AppServerNotification>
    func stop() async
}
