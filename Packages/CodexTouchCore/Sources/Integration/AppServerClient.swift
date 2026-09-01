import Foundation

/// JSON-RPC-over-stdio process transport. It owns only the selected CODEX_HOME boundary.
public actor AppServerClient: AppServerRPC {
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONRPCMessage, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let codexHome: URL
    private let arguments: [String]
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var processGeneration: UUID?
    private var nextRequestID = 1
    private var pending: [Int: Pending] = [:]
    private var receiveBuffer = Data()
    private var started = false
    private var notificationContinuation: AsyncStream<AppServerNotification>.Continuation?

    public init(executableURL: URL, codexHome: URL, arguments: [String] = ["app-server", "--stdio"]) {
        self.executableURL = executableURL.standardizedFileURL
        self.codexHome = codexHome.standardizedFileURL
        self.arguments = arguments
    }

    public func start() async throws {
        guard !started else { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GatewayError.processFailed("Codex executable is missing or not executable")
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let generation = UUID()
        receiveBuffer.removeAll(keepingCapacity: true)
        process.executableURL = executableURL
        process.arguments = arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_ACCESS_TOKEN"] {
            childEnvironment.removeValue(forKey: key)
        }
        childEnvironment["CODEX_HOME"] = codexHome.path
        process.environment = childEnvironment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let client = self else { return }
            Task { await client.consume(data, generation: generation) }
        }
        // Drain stderr without recording its content; otherwise a noisy process can block.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] process in
            guard let client = self else { return }
            let status = process.terminationStatus
            Task { await client.processTerminated(status: status, generation: generation) }
        }
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        processGeneration = generation
        do {
            try process.run()
            started = true
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            processGeneration = nil
            throw GatewayError.processFailed("Unable to start app-server")
        }
    }

    public func request(method: String, params: JSONValue?, timeout: TimeInterval = 10) async throws -> JSONValue {
        guard started else { throw AppServerRPCError.notStarted }
        let id = nextRequestID
        nextRequestID += 1

        let response = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONRPCMessage, Error>) in
                let timeoutTask = Task { [weak self] in
                    let boundedTimeout = timeout.isFinite ? max(timeout, 0.1) : 10
                    let nanos = UInt64(min(boundedTimeout, 86_400) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    guard !Task.isCancelled else { return }
                    await self?.timeout(id: id, method: method)
                }
                pending[id] = Pending(method: method, continuation: continuation, timeoutTask: timeoutTask)
                do {
                    try write(JSONRPCMessage(id: id, method: method, params: params))
                } catch {
                    pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
                    timeoutTask.cancel()
                }
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
        return try response.flatMapResult()
    }

    public func notify(method: String, params: JSONValue?) async throws {
        guard started else { throw AppServerRPCError.notStarted }
        try write(JSONRPCMessage(method: method, params: params))
    }

    public func notificationStream() async -> AsyncStream<AppServerNotification> {
        AsyncStream { continuation in
            notificationContinuation = continuation
        }
    }

    public func stop() async {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        notificationContinuation?.finish()
        notificationContinuation = nil
        let error = AppServerRPCError.terminated(-1)
        for (_, pendingRequest) in pending {
            pendingRequest.timeoutTask.cancel()
            pendingRequest.continuation.resume(throwing: error)
        }
        pending.removeAll()
        let processToStop = process
        processGeneration = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        if processToStop?.isRunning == true { processToStop?.terminate() }
        started = false
    }

    private func write(_ message: JSONRPCMessage) throws {
        guard let stdinPipe else { throw AppServerRPCError.notStarted }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw GatewayError.processFailed("Unable to write app-server request")
        }
    }

    private func consume(_ data: Data, generation: UUID) {
        guard processGeneration == generation else { return }
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(line))
                if let protocolVersion = message.jsonrpc, protocolVersion != "2.0" { continue }
                if let id = message.id, let request = pending.removeValue(forKey: id) {
                    request.timeoutTask.cancel()
                    if let error = message.error {
                        if error.code == -32601 {
                            request.continuation.resume(throwing: AppServerRPCError.methodNotFound(request.method))
                        } else {
                            request.continuation.resume(throwing: AppServerRPCError.remote(code: error.code, message: error.message))
                        }
                    } else {
                        request.continuation.resume(returning: message)
                    }
                } else if message.id == nil, let method = message.method {
                    notificationContinuation?.yield(AppServerNotification(method: method, params: message.params))
                }
            } catch {
                // Deliberately do not include the raw line in logs or errors.
            }
        }
    }

    private func timeout(id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: GatewayError.timeout(method))
    }

    private func cancel(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func processTerminated(status: Int32, generation: UUID) {
        guard processGeneration == generation else { return }
        started = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        processGeneration = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        let error = AppServerRPCError.terminated(status)
        for (_, pendingRequest) in pending {
            pendingRequest.timeoutTask.cancel()
            pendingRequest.continuation.resume(throwing: error)
        }
        pending.removeAll()
        notificationContinuation?.finish()
    }
}

private extension JSONRPCMessage {
    func flatMapResult() throws -> JSONValue {
        guard let result else { throw GatewayError.invalidResponse("JSON-RPC response omitted result") }
        return result
    }
}
