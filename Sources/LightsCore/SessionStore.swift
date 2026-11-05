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

    /// Claude Code restarts its keep-awake process every few minutes, gone for a fraction
    /// of a second. Gone longer than this means it stopped working.
    static let idleGrace: TimeInterval = 5

    private struct Entry: Sendable {
        let state: SessionState
        let since: Date
        /// Last time the tab's Claude Code was seen working since `state` began.
        var lastBusy: Date? = nil
        /// Whether it was seen idle since `state` began.
        var sawIdle = false
    }

    private var entries: [String: Entry] = [:]
    /// Tabs whose session Lights has heard of, so one that just ended isn't guessed back.
    private var known: Set<String> = []

    public init() {}

    public var tabs: Set<String> { Set(entries.keys) }

    public func state(of tab: String) -> SessionState? {
        entries[tab]?.state
    }

    public mutating func apply(_ signal: Signal, tab: String, at now: Date = Date()) {
        known.insert(tab)
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
        let isKept = { (tab: String) in !tab.hasPrefix("ttys") || liveTabs.contains(tab) }
        entries = entries.filter { isKept($0.key) }
        known = known.filter(isKept)
    }

    /// No hook fires when you press Esc or answer a permission prompt, so each tab running
    /// Claude Code is checked against whether it's working. A tab Lights hasn't heard from,
    /// e.g. after Lights restarts, gets its state the same way.
    public mutating func reconcile(with activity: TabActivity, at now: Date = Date()) {
        for tab in activity.claude.subtracting(known) {
            let isBusy = activity.busy.contains(tab)
            entries[tab] = Entry(state: isBusy ? .working : .done, since: now, lastBusy: isBusy ? now : nil)
            known.insert(tab)
        }
        // Only tabs running Claude Code are ever busy; other entries come through unchanged.
        entries = Dictionary(uniqueKeysWithValues: entries.map { tab, entry in
            (tab, Self.checked(entry, isBusy: activity.busy.contains(tab), at: now))
        })
    }

    private static func checked(_ entry: Entry, isBusy: Bool, at now: Date) -> Entry {
        switch entry.state {
        case .working where isBusy:
            return Entry(state: .working, since: entry.since, lastBusy: now)
        case .working:
            // Seen working, then stopped with no Stop hook: Esc.
            guard let last = entry.lastBusy, now.timeIntervalSince(last) >= idleGrace else { return entry }
            return Entry(state: .done, since: now)
        case .needsYou where isBusy:
            // Idle while the prompt waited, then working again: it was approved.
            guard entry.sawIdle else { return Entry(state: .needsYou, since: entry.since, lastBusy: now) }
            return Entry(state: .working, since: now, lastBusy: now)
        case .needsYou:
            let quietSince = entry.lastBusy ?? entry.since
            guard now.timeIntervalSince(quietSince) >= idleGrace else { return entry }
            return Entry(state: .needsYou, since: entry.since, lastBusy: entry.lastBusy, sawIdle: true)
        case .done:
            return entry
        }
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
