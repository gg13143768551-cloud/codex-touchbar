import Foundation

/// Experimental decoding is opt-in and version allow-listed. Unknown versions never fall through.
public actor ExperimentalProtocolAdapter: CodexGateway {
    public static let allowListedVersions: Set<String> = ["0.147.0"]
    private let delegate: StableProtocolAdapter

    public init(client: any AppServerRPC, profile: AccountProfile, version: String) throws {
        guard Self.allowListedVersions.contains(version) else {
            throw GatewayError.unsupported("Experimental protocol version is not allow-listed")
        }
        self.delegate = StableProtocolAdapter(client: client, profile: profile, version: version)
    }

    public func readSnapshot() async throws -> AppSnapshot { try await delegate.readSnapshot() }
    public func writeSelection(model: String, effort: String) async throws -> ConfigWriteResult {
        try await delegate.writeSelection(model: model, effort: effort)
    }
    public func startTurn(threadID: String, input: String, selection: ModelSelection) async throws {
        try await delegate.startTurn(threadID: threadID, input: input, selection: selection)
    }
    public func stop() async { await delegate.stop() }
}
