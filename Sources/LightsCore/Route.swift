import Foundation

/// HTTP routes served on 127.0.0.1:9876.
public enum Route: Equatable, Sendable {
    case signal(Signal, tab: String)
    case status
    case snapshot
    case health
    case badRequest
    case notFound

    /// `/state?s=<signal>&tab=<tty>` is what the hook script sends. The bare paths
    /// (`/executing`, `/permission`, `/idle`, `/off`) still work for manual use.
    public init(path: String) {
        let parts = URLComponents(string: path)
        switch parts?.path ?? path {
        case "/state":
            let items = parts?.queryItems ?? []
            let raw = items.first { $0.name == "s" }?.value ?? ""
            let tab = items.first { $0.name == "tab" }?.value ?? SessionStore.unknownTab
            guard let signal = Signal(raw), Self.isValidTab(tab) else {
                self = .badRequest
                return
            }
            self = .signal(signal, tab: tab)
        case "/executing", "/permission", "/idle", "/off":
            let name = String((parts?.path ?? path).dropFirst())
            self = Signal(name).map { .signal($0, tab: SessionStore.unknownTab) } ?? .notFound
        case "/status":
            self = .status
        case "/snapshot":
            self = .snapshot
        case "/", "/health":
            self = .health
        default:
            self = .notFound
        }
    }

    static func isValidTab(_ tab: String) -> Bool {
        tab.count <= 32 && tab.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Value of the token header, if the request carries one.
    public static func token(in rawRequest: String) -> String? {
        let name = HookScript.tokenHeader.lowercased() + ":"
        for line in rawRequest.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix(name) {
                return line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Compares without stopping at the first difference.
    public static func tokenMatches(_ given: String?, _ expected: String) -> Bool {
        guard let given, given.utf8.count == expected.utf8.count, !expected.isEmpty else { return false }
        return zip(given.utf8, expected.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Browsers add these headers; hooks (curl) never do. Rejecting them stops
    /// any web page from flipping the light through a cross-site request.
    public static func isFromBrowser(_ rawRequest: String) -> Bool {
        let lower = rawRequest.lowercased()
        return lower.contains("\r\norigin:") || lower.contains("\r\nsec-fetch-")
    }
}
