import Foundation

/// Per-terminal-tab session states, keyed by the tab's tty name (e.g. "ttys002").
public struct SessionStore: Sendable {
    /// Bucket for reports that carry no tab (old curl hooks, SSH hosts without LC_* forwarding).
    public static let unknownTab = ""

    /// A tool finishing in parallel can report "working" just after a permission prompt
    /// opened; ignore that for a moment so the red light isn't lost.
    static let needsYouHold: TimeInterval = 0.25

    private struct Entry: Sendable {
        let state: SessionState
        let since: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var tabs: Set<String> { Set(entries.keys) }

    public func state(of tab: String) -> SessionState? {
        entries[tab]?.state
    }

    public mutating func apply(_ signal: Signal, tab: String, at now: Date = Date()) {
        guard case .set(let next) = signal else {
            entries[tab] = nil
            return
        }
        if let current = entries[tab] {
            if current.state == next { return }
            if current.state == .needsYou, next == .working,
               now.timeIntervalSince(current.since) < Self.needsYouHold {
                return
            }
        }
        entries[tab] = Entry(state: next, since: now)
    }

    /// Drops tabs that no longer run an AI tool or an SSH session.
    public mutating func retain(liveTabs: Set<String>) {
        entries = entries.filter { $0.key == Self.unknownTab || liveTabs.contains($0.key) }
    }

    /// The followed tab's state, or the most urgent session when no tab is being followed.
    /// A tab with no report of its own falls back to reports that came without a tab.
    public func displayed(following tab: String?) -> SessionState? {
        if let tab { return (entries[tab] ?? entries[Self.unknownTab])?.state }
        return entries.values.map(\.state).max { $0.urgency < $1.urgency }
    }
}
