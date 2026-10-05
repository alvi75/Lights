import Foundation

public enum ToolIntegrationError: Error, LocalizedError {
    case invalidJSON(String)
    case writeFailed(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let p):  return "Invalid JSON in: \(p)"
        case .writeFailed(let p):  return "Failed to write: \(p)"
        case .notImplemented(let t): return "\(t) integration not yet implemented"
        }
    }
}
