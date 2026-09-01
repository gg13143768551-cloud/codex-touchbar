import Foundation

#if os(macOS)
import OSLog
#endif

public struct RedactingLogger: Sendable {
    public init() {}

    public func error(code: String, method: String, version: String?, elapsedMilliseconds: Int) {
        let safeCode = code.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let safeMethod = method.filter { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-" }
        let safeVersion = version?.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } ?? "unknown"
        #if os(macOS)
        Logger(subsystem: "com.codex.touchbar", category: "gateway").error(
            "code=\(safeCode, privacy: .public) method=\(safeMethod, privacy: .public) version=\(safeVersion, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public)"
        )
        #else
        _ = (safeCode, safeMethod, safeVersion, elapsedMilliseconds)
        #endif
    }
}
