import XCTest
import CodexTouchCore

final class StableAdapterContractTests: XCTestCase {
    func testCurrentSchemaFixturesDecodeToCompleteSnapshot() async throws {
        let fixtureDirectory = try XCTUnwrap(Bundle.module.url(forResource: "AppServer", withExtension: nil, subdirectory: "Fixtures"))
        let rpc = try FixtureRPC(directory: fixtureDirectory)
        let profile = AccountProfile(id: UUID(), alias: "Fixture", codexHome: URL(fileURLWithPath: "/redacted/codex-home"))
        let adapter = StableProtocolAdapter(client: rpc, profile: profile, version: "0.147.0")
        let snapshot = try await adapter.readSnapshot()
        XCTAssertEqual(snapshot.connection, .connected)
        XCTAssertEqual(snapshot.authentication, .authenticated)
        XCTAssertEqual(snapshot.quota.lastKnown(.fiveHour)?.remainingPercent, 72)
        XCTAssertEqual(snapshot.quota.lastKnown(.sevenDay)?.remainingPercent, 54)
        XCTAssertEqual(snapshot.usage.dailyBuckets.count, 2)
        XCTAssertEqual(snapshot.models.first?.supportedReasoningEfforts.count, 3)
        XCTAssertEqual(snapshot.selection?.effort, "medium")
    }

    func testUncertainConfigWriteUsesReadbackWithoutRetryingWrite() async throws {
        let home = URL(fileURLWithPath: "/redacted/codex-home")
        let rpc = UncertainWriteRPC(codexHome: home.path)
        let profile = AccountProfile(id: UUID(), alias: "Fixture", codexHome: home)
        let adapter = StableProtocolAdapter(client: rpc, profile: profile, version: "0.147.0")

        let result = try await adapter.writeSelection(model: "gpt-5.6", effort: "high")
        let batchWriteCount = await rpc.batchWriteCount

        XCTAssertTrue(result.readbackMatched)
        XCTAssertTrue(result.selection.confirmed)
        XCTAssertEqual(batchWriteCount, 1)
    }

    func testUnauthenticatedAccountProducesLoginStateWithoutProtectedReads() async throws {
        let home = URL(fileURLWithPath: "/redacted/codex-home")
        let rpc = UnauthenticatedRPC(codexHome: home.path)
        let profile = AccountProfile(id: UUID(), alias: "Fixture", codexHome: home)
        let adapter = StableProtocolAdapter(client: rpc, profile: profile, version: "0.147.0")

        let snapshot = try await adapter.readSnapshot()
        let requestedMethods = await rpc.requestedMethods

        XCTAssertEqual(snapshot.connection, .connected)
        XCTAssertEqual(snapshot.authentication, .requiresLogin)
        XCTAssertEqual(requestedMethods, ["initialize", "account/read"])
    }

    func testUnexpectedTransportExitReinitializesOnce() async throws {
        let home = URL(fileURLWithPath: "/redacted/codex-home")
        let rpc = RestartingRPC(codexHome: home.path)
        let profile = AccountProfile(id: UUID(), alias: "Fixture", codexHome: home)
        let adapter = StableProtocolAdapter(client: rpc, profile: profile, version: "0.147.0")

        let snapshot = try await adapter.readSnapshot()
        let startCount = await rpc.startCount

        XCTAssertEqual(snapshot.connection, .connected)
        XCTAssertEqual(snapshot.authentication, .authenticated)
        XCTAssertEqual(startCount, 2)
    }
}

private actor UncertainWriteRPC: AppServerRPC {
    let codexHome: String
    private(set) var batchWriteCount = 0
    private var started = false

    init(codexHome: String) { self.codexHome = codexHome }

    func start() async throws { started = true }

    func request(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard started else { throw AppServerRPCError.notStarted }
        switch method {
        case "initialize":
            return .object(["codexHome": .string(codexHome)])
        case "config/batchWrite":
            batchWriteCount += 1
            throw GatewayError.timeout(method)
        case "config/read":
            return .object(["config": .object([
                "model": .string("gpt-5.6"),
                "model_reasoning_effort": .string("high")
            ])])
        default:
            throw AppServerRPCError.methodNotFound(method)
        }
    }

    func notify(method: String, params: JSONValue?) async throws {}
    func notificationStream() async -> AsyncStream<AppServerNotification> { AsyncStream { _ in } }
    func stop() async { started = false }
}

private actor UnauthenticatedRPC: AppServerRPC {
    let codexHome: String
    private(set) var requestedMethods: [String] = []
    private var started = false

    init(codexHome: String) { self.codexHome = codexHome }

    func start() async throws { started = true }

    func request(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard started else { throw AppServerRPCError.notStarted }
        requestedMethods.append(method)
        switch method {
        case "initialize": return .object(["codexHome": .string(codexHome)])
        case "account/read": return .object(["account": .null, "requiresOpenaiAuth": .bool(true)])
        default: throw AppServerRPCError.remote(code: -32000, message: "authentication required")
        }
    }

    func notify(method: String, params: JSONValue?) async throws {}
    func notificationStream() async -> AsyncStream<AppServerNotification> { AsyncStream { _ in } }
    func stop() async { started = false }
}

private actor RestartingRPC: AppServerRPC {
    let codexHome: String
    private(set) var startCount = 0
    private var started = false
    private var shouldFailAccountRead = true

    init(codexHome: String) { self.codexHome = codexHome }

    func start() async throws {
        started = true
        startCount += 1
    }

    func request(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard started else { throw AppServerRPCError.notStarted }
        switch method {
        case "initialize":
            return .object(["codexHome": .string(codexHome)])
        case "account/read":
            if shouldFailAccountRead {
                shouldFailAccountRead = false
                started = false
                throw AppServerRPCError.terminated(1)
            }
            return .object([
                "account": .object(["type": .string("chatgpt"), "email": .null, "planType": .string("plus")]),
                "requiresOpenaiAuth": .bool(true)
            ])
        case "account/rateLimits/read":
            return .object(["rateLimits": .object([
                "primary": .object(["windowDurationMins": .number(300), "usedPercent": .number(10), "resetsAt": .null]),
                "secondary": .null
            ])])
        case "account/usage/read":
            return .object(["dailyUsageBuckets": .array([]), "summary": .object([:])])
        case "model/list":
            return .object(["data": .array([])])
        case "config/read":
            return .object(["config": .object([:])])
        default:
            throw AppServerRPCError.methodNotFound(method)
        }
    }

    func notify(method: String, params: JSONValue?) async throws {}
    func notificationStream() async -> AsyncStream<AppServerNotification> { AsyncStream { _ in } }
    func stop() async { started = false }
}
