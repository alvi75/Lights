import Foundation

/// What the light is following.
public enum Follow: Equatable, Sendable {
    case tab(String)    // a Terminal / iTerm2 tab, by tty name
    case editor         // VS Code and its forks; their terminals aren't told apart
}

/// Per-terminal-tab session states, keyed by the tab's tty name (e.g. "ttys002").
/// Sessions in VS Code terminals use keys starting with `editorPrefix`.
public struct SessionStore: Sendable {
    public static let editorPrefix = "vscode"
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

    /// Drops Mac terminal tabs that no longer run an AI tool or an SSH session.
    /// Other keys (editor sessions, no-tab reports) go away on their session-end report.
    public mutating func retain(liveTabs: Set<String>) {
        entries = entries.filter { !$0.key.hasPrefix("ttys") || liveTabs.contains($0.key) }
    }

    /// What to show for what's being followed. A tab with no report of its own falls back
    /// to reports that came without a tab; with nothing followed, the most urgent session.
    public func displayed(following follow: Follow?) -> SessionState? {
        switch follow {
        case .tab(let tab):
            return (entries[tab] ?? entries[Self.unknownTab])?.state
        case .editor:
            return mostUrgent(entries.filter { $0.key.hasPrefix(Self.editorPrefix) })
                ?? entries[Self.unknownTab]?.state
        case nil:
            return mostUrgent(entries)
        }
    }

    private func mostUrgent(_ subset: [String: Entry]) -> SessionState? {
        subset.values.map(\.state).max { $0.urgency < $1.urgency }
    }
}
