import Foundation

/// What one AI session is doing.
public enum SessionState: String, Sendable, CaseIterable {
    case needsYou = "needs-you"
    case working
    case done

    var urgency: Int {
        switch self {
        case .needsYou: 2
        case .working:  1
        case .done:     0
        }
    }

    public var light: Light {
        switch self {
        case .needsYou: .red
        case .working:  .yellow
        case .done:     .green
        }
    }
}

public enum Light: String, Sendable {
    case red, yellow, green
}

/// A state report from a hook. Raw names match the hook arguments and the old URL paths.
public enum Signal: Equatable, Sendable {
    case set(SessionState)
    case end

    public init?(_ raw: String) {
        switch raw {
        case "executing":           self = .set(.working)
        case "permission", "error": self = .set(.needsYou)
        case "idle":                self = .set(.done)
        case "end", "off":          self = .end
        default:                    return nil
        }
    }
}
