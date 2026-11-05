import Foundation

/// What Claude Code says one of its sessions is doing. It keeps this in
/// ~/.claude/sessions/<pid>.json and updates it the moment things change, including
/// the moments no hook reports: Esc, a "no", an approval.
public struct ClaudeStatus: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case busy       // working
        case waiting    // a permission prompt, question, plan or other dialog needs you
        case idle       // turn over, or stopped with Esc
    }

    public let pid: Int
    public let sessionId: String
    public let phase: Phase
    public let since: Date

    public init(pid: Int, sessionId: String, phase: Phase, since: Date) {
        self.pid = pid
        self.sessionId = sessionId
        self.phase = phase
        self.since = since
    }

    public static func parse(_ data: Data) -> ClaudeStatus? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = record["pid"] as? Int,
              let sessionId = record["sessionId"] as? String, isSessionID(sessionId),
              let phase = (record["status"] as? String).flatMap(Phase.init(rawValue:)),
              let millis = (record["statusUpdatedAt"] as? NSNumber)?.doubleValue else { return nil }
        return ClaudeStatus(pid: pid, sessionId: sessionId, phase: phase,
                            since: Date(timeIntervalSince1970: millis / 1000))
    }

    public static func isSessionID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
