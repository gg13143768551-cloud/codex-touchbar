import Foundation

public actor UnsupportedAdapter: CodexGateway {
    private let reason: String

    public init(reason: String) { self.reason = reason }

    public func readSnapshot() async throws -> AppSnapshot { throw GatewayError.unsupported(reason) }
    public func writeSelection(model: String, effort: String) async throws -> ConfigWriteResult {
        throw GatewayError.unsupported(reason)
    }
    public func startTurn(threadID: String, input: String, selection: ModelSelection) async throws {
        throw GatewayError.unsupported(reason)
    }
    public func stop() async {}
}
