import Foundation

public struct CodexCapability: Equatable, Sendable {
    public let executableURL: URL
    public let version: String
    public let supportsAppServer: Bool

    public init(executableURL: URL, version: String, supportsAppServer: Bool) {
        self.executableURL = executableURL
        self.version = version
        self.supportsAppServer = supportsAppServer
    }
}

public struct CapabilityResolver: Sendable {
    public init() {}

    public func resolve(explicitURL: URL? = nil) throws -> CodexCapability {
        let candidates = explicitURL.map { [$0] } ?? defaultCandidates()
        for candidate in candidates {
            let url = candidate.standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            guard let versionOutput = try? run(executable: url, arguments: ["--version"]),
                  let version = normalizedVersion(from: versionOutput),
                  let help = try? run(executable: url, arguments: ["app-server", "--help"]) else { continue }
            return CodexCapability(
                executableURL: url,
                version: version,
                supportsAppServer: help.lowercased().contains("app-server")
            )
        }
        throw GatewayError.unsupported("Codex app-server executable not found")
    }

    private func defaultCandidates() -> [URL] {
        var values = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ]
        values.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex"))
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            values.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            })
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func run(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GatewayError.processFailed("Codex capability probe failed") }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func normalizedVersion(from output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard firstLine.lowercased().contains("codex") else { return nil }
        return firstLine.split(separator: " ").last.map(String.init)
    }
}
