import Foundation
import CodexTouchCore

actor FixtureRPC: AppServerRPC {
    private let fixtures: [String: JSONValue]
    private var started = false
    private var continuation: AsyncStream<AppServerNotification>.Continuation?

    init(directory: URL) throws {
        let names = ["account", "rate-limits", "usage", "models", "config", "initialize"]
        var loaded: [String: JSONValue] = [:]
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
            loaded[name] = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        fixtures = loaded
    }

    func start() async throws { started = true }

    func request(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard started else { throw AppServerRPCError.notStarted }
        switch method {
        case "initialize": return fixtures["initialize"]!
        case "account/read": return fixtures["account"]!
        case "account/rateLimits/read": return fixtures["rate-limits"]!
        case "account/usage/read": return fixtures["usage"]!
        case "model/list": return fixtures["models"]!
        case "config/read": return fixtures["config"]!
        default: throw AppServerRPCError.methodNotFound(method)
        }
    }

    func notify(method: String, params: JSONValue?) async throws {}

    func notificationStream() async -> AsyncStream<AppServerNotification> {
        AsyncStream { continuation = $0 }
    }

    func stop() async { started = false; continuation?.finish() }
}
