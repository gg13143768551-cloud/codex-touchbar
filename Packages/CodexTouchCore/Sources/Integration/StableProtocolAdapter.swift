import Foundation

/// Adapter for the documented app-server v2 shapes observed from codex-cli 0.147.0.
/// All uncertain decoding stays in this file so a protocol change cannot corrupt domain state.
public actor StableProtocolAdapter: CodexGateway {
    private let client: any AppServerRPC
    private let profile: AccountProfile
    private let version: String
    private var initialized = false
    private var serverCodexHome: URL?
    private var pluginTurnInProgress = false
    private var notificationTask: Task<Void, Never>?
    private var intentionallyStopped = false

    public init(client: any AppServerRPC, profile: AccountProfile, version: String) {
        self.client = client
        self.profile = profile
        self.version = version
    }

    public func readSnapshot() async throws -> AppSnapshot {
        guard !intentionallyStopped else { throw AppServerRPCError.notStarted }
        do {
            return try await readSnapshotOnce()
        } catch AppServerRPCError.notStarted, AppServerRPCError.terminated(_) {
            guard !intentionallyStopped else { throw AppServerRPCError.notStarted }
            await resetTransport()
            return try await readSnapshotOnce()
        }
    }

    private func readSnapshotOnce() async throws -> AppSnapshot {
        try await ensureInitialized()
        guard serverCodexHome?.path == profile.codexHome.standardizedFileURL.path else {
            throw GatewayError.profileMismatch
        }
        let fetchedAt = Date()

        let accountResponse: WireAccountResponse
        do {
            let accountRaw = try await client.request(method: "account/read", params: .object([:]), timeout: 10)
            accountResponse = try decode(WireAccountResponse.self, from: accountRaw)
        } catch let error as GatewayError {
            throw error
        } catch let error as AppServerRPCError {
            throw error
        } catch {
            throw GatewayError.invalidResponse("Stable account response did not match schema")
        }
        let account = accountResponse.account.map(makeAccountIdentity)
        guard account != nil else {
            return AppSnapshot(
                profile: profile,
                serverCodexHome: serverCodexHome,
                connection: .connected,
                authentication: .requiresLogin,
                usage: UsageSnapshot(availability: .unavailable),
                fetchedAt: fetchedAt
            )
        }

        async let limitsRaw = client.request(method: "account/rateLimits/read", params: .object([:]), timeout: 10)
        async let modelsRaw = client.request(method: "model/list", params: .object(["includeHidden": .bool(false)]), timeout: 10)
        async let configRaw = client.request(method: "config/read", params: .object(["includeLayers": .bool(false)]), timeout: 10)

        let limitsResponse: WireRateLimitsResponse
        let modelsResponse: WireModelListResponse
        let configResponse: WireConfigReadResponse
        do {
            limitsResponse = try decode(WireRateLimitsResponse.self, from: try await limitsRaw)
            modelsResponse = try decode(WireModelListResponse.self, from: try await modelsRaw)
            configResponse = try decode(WireConfigReadResponse.self, from: try await configRaw)
        } catch let error as GatewayError {
            throw error
        } catch let error as AppServerRPCError {
            throw error
        } catch {
            throw GatewayError.invalidResponse("Stable app-server response did not match schema")
        }

        let quotaWindows = limitsResponse.quotaWindows
        let quota = QuotaParser.parse(windows: quotaWindows, fetchedAt: fetchedAt)
        let models = modelsResponse.data.map(makeModelOption)
        let configuredModel = configResponse.config.model
        let configuredEffort = configResponse.config.reasoningEffort
        let effectiveModel = configuredModel ?? models.first(where: \.isDefault)?.model ?? models.first?.model
        let selection: ModelSelection? = effectiveModel.map { modelName in
            let option = models.first(where: { $0.model == modelName })
            let fallbackEffort = option?.compatibleEffort(preferred: configuredEffort) ?? configuredEffort ?? "unknown"
            let confirmed = option.map { configuredEffort == nil || $0.supports(effort: configuredEffort) } ?? false
            return ModelSelection(model: modelName, effort: configuredEffort ?? fallbackEffort, confirmed: confirmed)
        }

        let usage = await readUsage(now: fetchedAt)
        return AppSnapshot(
            profile: profile,
            serverCodexHome: serverCodexHome,
            account: account,
            connection: .connected,
            authentication: .authenticated,
            quota: quota,
            usage: usage,
            models: models,
            selection: selection,
            pluginTurnInProgress: pluginTurnInProgress,
            fetchedAt: fetchedAt
        )
    }

    public func writeSelection(model: String, effort: String) async throws -> ConfigWriteResult {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError.invalidResponse("Model and reasoning effort are required")
        }
        try await ensureInitialized()
        let edits: [JSONValue] = [
            .object(["keyPath": .string("model"), "mergeStrategy": .string("replace"), "value": .string(model)]),
            .object(["keyPath": .string("model_reasoning_effort"), "mergeStrategy": .string("replace"), "value": .string(effort)])
        ]
        var writeError: Error?
        do {
            _ = try await client.request(
                method: "config/batchWrite",
                params: .object(["edits": .array(edits), "reloadUserConfig": .bool(false)]),
                timeout: 10
            )
        } catch {
            // Do not retry a non-idempotent write. Its outcome may be unknown,
            // so perform the same authoritative readback used after success.
            writeError = error
        }
        do {
            let raw = try await client.request(
                method: "config/read",
                params: .object(["includeLayers": .bool(false)]),
                timeout: 10
            )
            let config = try decode(WireConfigReadResponse.self, from: raw).config
            let matched = config.model == model && config.reasoningEffort == effort
            if matched {
                return ConfigWriteResult(selection: ModelSelection(model: model, effort: effort, confirmed: true), readbackMatched: true)
            }
            if let writeError { throw writeError }
            return ConfigWriteResult(selection: ModelSelection(model: model, effort: effort, confirmed: false), readbackMatched: false)
        } catch {
            if let writeError { throw writeError }
            throw error
        }
    }

    public func startTurn(threadID: String, input: String, selection: ModelSelection) async throws {
        try await ensureInitialized()
        pluginTurnInProgress = true
        do {
            _ = try await client.request(
                method: "turn/start",
                params: .object([
                    "threadId": .string(threadID),
                    "input": .array([.object(["type": .string("text"), "text": .string(input)])]),
                    "model": .string(selection.model),
                    "effort": .string(selection.effort)
                ]),
                timeout: 10
            )
        } catch {
            pluginTurnInProgress = false
            throw error
        }
    }

    public func stop() async {
        intentionallyStopped = true
        initialized = false
        serverCodexHome = nil
        pluginTurnInProgress = false
        notificationTask?.cancel()
        notificationTask = nil
        await client.stop()
    }

    private func ensureInitialized() async throws {
        guard !intentionallyStopped else { throw AppServerRPCError.notStarted }
        guard !initialized else { return }
        do {
            try await client.start()
            let initializeRaw = try await client.request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("codex-touchbar"),
                        "title": .string("Codex Touch Bar"),
                        "version": .string("0.1.0")
                    ]),
                    "capabilities": .object([
                        "experimentalApi": .bool(false),
                        "mcpServerOpenaiFormElicitation": .bool(false),
                        "requestAttestation": .bool(false)
                    ])
                ]),
                timeout: 10
            )
            let initializeResponse = try decode(WireInitializeResponse.self, from: initializeRaw)
            serverCodexHome = URL(fileURLWithPath: initializeResponse.codexHome).standardizedFileURL
            try await client.notify(method: "initialized", params: .object([:]))
            initialized = true
            let stream = await client.notificationStream()
            notificationTask = Task { [weak self] in
                for await notification in stream {
                    if notification.method == "account/rateLimits/updated" {
                        await self?.observeRateLimitUpdate(notification.params)
                    } else {
                        await self?.observeActivity(notification.method)
                    }
                }
            }
            _ = version // retained for telemetry and version-gated adapter selection.
        } catch {
            await resetTransport()
            throw error
        }
    }

    private func resetTransport() async {
        initialized = false
        serverCodexHome = nil
        pluginTurnInProgress = false
        notificationTask?.cancel()
        notificationTask = nil
        await client.stop()
    }

    private func observeRateLimitUpdate(_ params: JSONValue?) {
        // Sparse push updates are consumed for liveness; the next read remains authoritative.
        _ = params
    }

    private func observeActivity(_ method: String) {
        switch method {
        case "turn/started": pluginTurnInProgress = true
        case "turn/completed": pluginTurnInProgress = false
        default: break
        }
    }

    private func readUsage(now: Date) async -> UsageSnapshot {
        do {
            let raw = try await client.request(method: "account/usage/read", params: .object([:]), timeout: 10)
            let response = try decode(WireUsageResponse.self, from: raw)
            let buckets = response.buckets
            return UsageSnapshot.fromServerBuckets(
                buckets,
                serviceDate: response.serviceDate,
                serviceTimeZoneIdentifier: response.serviceTimeZoneIdentifier,
                now: now,
                fetchedAt: now
            )
        } catch let error as AppServerRPCError {
            if case .methodNotFound = error { return UsageSnapshot(availability: .unsupported) }
            return UsageSnapshot(availability: .unavailable)
        } catch {
            return UsageSnapshot(availability: .unavailable)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do { return try JSONDecoder().decode(type, from: value.data()) }
        catch { throw GatewayError.invalidResponse("Unable to decode stable app-server response") }
    }

    private func makeAccountIdentity(_ account: WireAccount) -> AccountIdentity {
        switch account.type {
        case "chatgpt": return AccountIdentity(kind: .chatGPT, maskedEmail: maskEmail(account.email), planType: account.planType)
        case "amazonBedrock": return AccountIdentity(kind: .amazonBedrock)
        default: return AccountIdentity(kind: .keyAccount)
        }
    }

    private func maskEmail(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        guard let first = local.first else { return "***@\(domain)" }
        return "\(first)***@\(domain)"
    }

    private func makeModelOption(_ model: WireModel) -> ModelOption {
        ModelOption(
            id: model.id,
            model: model.model,
            displayName: model.displayName,
            defaultReasoningEffort: model.defaultReasoningEffort,
            supportedReasoningEfforts: model.supportedReasoningEfforts.map {
                ReasoningEffortOption(value: $0.reasoningEffort, description: $0.description)
            },
            hidden: model.hidden,
            isDefault: model.isDefault
        )
    }
}

private struct WireAccountResponse: Decodable {
    let account: WireAccount?
    let requiresOpenaiAuth: Bool
}

private struct WireInitializeResponse: Decodable {
    let codexHome: String
}

private struct WireAccount: Decodable {
    let type: String
    let email: String?
    let planType: String?
}

private struct WireRateLimitsResponse: Decodable {
    let rateLimits: WireRateLimitSnapshot
    let rateLimitsByLimitId: [String: WireRateLimitSnapshot]?

    var quotaWindows: [WireQuotaWindow] {
        // The multi-bucket response can include unrelated model buckets. The
        // documented `codex` bucket is authoritative when present.
        let snapshot = rateLimitsByLimitId?["codex"] ?? rateLimits
        return [snapshot.primary, snapshot.secondary].compactMap { $0?.domain }
    }
}

private struct WireRateLimitSnapshot: Decodable {
    let primary: WireQuotaWindowDTO?
    let secondary: WireQuotaWindowDTO?
}

private struct WireQuotaWindowDTO: Decodable {
    let windowDurationMins: Int64?
    let usedPercent: Int
    let resetsAt: Int64?
}

private extension WireQuotaWindowDTO {
    var domain: WireQuotaWindow { WireQuotaWindow(windowDurationMins: windowDurationMins, usedPercent: usedPercent, resetsAt: resetsAt) }
}

private struct WireUsageResponse: Decodable {
    let dailyUsageBucketsWire: [DailyUsageBucketDTO]?
    let serviceDate: String?
    let serviceTimeZoneIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case dailyUsageBucketsWire = "dailyUsageBuckets"
        case serviceDate
        case serviceTimeZoneIdentifier = "timeZone"
    }
}

private struct DailyUsageBucketDTO: Decodable {
    let startDate: String
    let tokens: Int64
}

private extension WireUsageResponse {
    var buckets: [DailyUsageBucket] {
        (dailyUsageBucketsWire ?? []).map { DailyUsageBucket(startDate: $0.startDate, tokens: $0.tokens) }
    }
}

private struct WireModelListResponse: Decodable {
    let data: [WireModel]
}

private struct WireModel: Decodable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let hidden: Bool
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [WireEffort]
}

private struct WireEffort: Decodable {
    let reasoningEffort: String
    let description: String
}

private struct WireConfigReadResponse: Decodable {
    let config: WireConfig
}

private struct WireConfig: Decodable {
    let model: String?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case reasoningEffort = "model_reasoning_effort"
    }
}
