import Foundation

public struct LiveCodexSessionFactory: CodexSessionFactory {
    private let capability: CodexCapability

    public init(capability: CodexCapability) {
        self.capability = capability
    }

    public func open(profile: AccountProfile) async throws -> any CodexGateway {
        guard capability.supportsAppServer else {
            throw GatewayError.unsupported("This Codex version does not expose app-server")
        }
        let client = AppServerClient(executableURL: capability.executableURL, codexHome: profile.codexHome)
        return StableProtocolAdapter(client: client, profile: profile, version: capability.version)
    }
}

public struct UnsupportedSessionFactory: CodexSessionFactory {
    private let reason: String

    public init(reason: String) { self.reason = reason }

    public func open(profile: AccountProfile) async throws -> any CodexGateway {
        UnsupportedAdapter(reason: reason)
    }
}
