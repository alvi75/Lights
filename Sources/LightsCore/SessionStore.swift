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
        /// Red from an API error rather than a prompt; it stays until you act.
        var isError = false
    }

    private var entries: [String: Entry] = [:]
    /// Tabs whose session Lights has heard of, so one that just ended isn't guessed back.
    private var known: Set<String> = []
    /// Claude Code session id each tab's hooks reported.
    private var sessions: [String: String] = [:]
    /// Tabs showing a background job's light, as of the last check.
    private var followingJob: Set<String> = []

    public init() {}

    public var tabs: Set<String> { Set(entries.keys) }

    public func state(of tab: String) -> SessionState? {
        entries[tab]?.state
    }

    public mutating func apply(_ signal: Signal, tab: String, session: String? = nil, at now: Date = Date()) {
        known.insert(tab)
        if let session { sessions[tab] = session }
        let next: SessionState
        switch signal {
        case .end:
            entries[tab] = nil
            sessions[tab] = nil
            return
        case .failed:
            entries[tab] = Entry(state: .needsYou, since: now, isError: true)
            return
        case .set(let state):
            next = state
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
        sessions = sessions.filter { isKept($0.key) }
    }

    /// Checks each session against what Claude Code says it's doing (`statuses`), since
    /// no hook fires for Esc, a "no" or an approval. Tabs Lights hasn't heard from, e.g.
    /// after it restarts, get their state the same way.
    public mutating func reconcile(with activity: TabActivity, statuses: [ClaudeStatus], at now: Date = Date()) {
        let running = statuses.filter { activity.pids.contains($0.pid) }
        func ownStatus(of tab: String) -> ClaudeStatus? {
            running.filter { activity.claude[tab]?.contains($0.pid) == true || $0.sessionId == sessions[tab] }
                .max { $0.since < $1.since }
        }
        // A session moved to the background goes on working as a job under a pty of its
        // own, while the process left in the tab sits idle. The tab follows the job.
        func job(behind tab: String) -> ClaudeStatus? {
            guard let parked = ownStatus(of: tab)?.parkedJobId else { return nil }
            return running.filter { $0.jobId == parked }.max { $0.since < $1.since }
        }
        func status(of tab: String) -> ClaudeStatus? {
            job(behind: tab) ?? ownStatus(of: tab)
        }
        for tab in Set(activity.claude.keys).subtracting(known) {
            entries[tab] = Entry(state: status(of: tab)?.phase.state ?? .done, since: now)
            known.insert(tab)
        }
        // Tabless reports come from servers; with no ssh open, whatever sent them is gone.
        if activity.ssh.isEmpty {
            entries[Self.unknownTab] = nil
        }
        // A tab that took its session back, or whose job died, starts over from its own status:
        // the job's light would otherwise outlive the job, since the file's time doesn't move.
        let nowFollowing = Set(entries.keys.filter { job(behind: $0) != nil })
        for tab in followingJob.subtracting(nowFollowing) where entries[tab] != nil {
            entries[tab] = Entry(state: ownStatus(of: tab)?.phase.state ?? .done, since: now)
        }
        followingJob = nowFollowing
        entries = Dictionary(uniqueKeysWithValues: entries.map { tab, entry in
            (tab, status(of: tab).map { Self.checked(entry, against: $0, at: now) } ?? entry)
        })
        // The job's hooks (an API error among them) report under its pty; show them in the tab.
        let followed = entries.keys.compactMap { tab -> (String, Entry)? in
            guard let job = job(behind: tab),
                  let pty = activity.claude.first(where: { $0.value.contains(job.pid) })?.key,
                  pty != tab, let jobEntry = entries[pty] else { return nil }
            return (tab, jobEntry)
        }
        for (tab, entry) in followed { entries[tab] = entry }
    }

    private static func checked(_ entry: Entry, against status: ClaudeStatus, at now: Date) -> Entry {
        switch status.phase {
        case .waiting:
            // Holds while the prompt is open, even over a parallel tool's late report.
            return entry.state == .needsYou ? entry : Entry(state: .needsYou, since: now)
        case _ where status.since <= entry.since:
            return entry    // a hook reported after this change
        case .busy:
            return entry.state == .working ? entry : Entry(state: .working, since: now)
        case .idle, .shell:
            return entry.state == .done || entry.isError ? entry : Entry(state: .done, since: now)
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

extension ClaudeStatus.Phase {
    var state: SessionState {
        switch self {
        case .busy:           .working
        case .waiting:        .needsYou
        case .idle, .shell:   .done
        }
    }
}
