import Foundation

/// What each terminal tab is running, read from `ps -axo pid=,ppid=,tty=,args=`.
public struct TabActivity: Equatable, Sendable {
    /// Tabs that run an AI tool, or an SSH session that may run one remotely.
    public let live: Set<String>
    /// Tabs that run Claude Code.
    public let claude: Set<String>
    /// Tabs whose Claude Code keeps the Mac awake with `caffeinate`, which it does while
    /// it works and for about 30 seconds after.
    public let busy: Set<String>

    public init(live: Set<String>, claude: Set<String>, busy: Set<String>) {
        self.live = live
        self.claude = claude
        self.busy = busy
    }

    static let programs: Set<String> = ["claude", "codex", "ssh"]

    private struct Process {
        let parent: Substring
        let tty: String
        let names: [String]
    }

    public static func parse(_ psOutput: String) -> TabActivity {
        var processes: [Substring: Process] = [:]
        for line in psOutput.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 4 else { continue }
            // npm installs show up as `node /path/to/claude`, so the first two words count.
            let names = words.dropFirst(3).prefix(2).map(programName)
            processes[words[0]] = Process(parent: words[1], tty: String(words[2]), names: names)
        }
        let inTabs = processes.values.filter { $0.tty.hasPrefix("ttys") }
        let isClaude = { (p: Process) in p.names.contains("claude") }
        return TabActivity(
            live: Set(inTabs.filter { $0.names.contains(where: programs.contains) }.map(\.tty)),
            claude: Set(inTabs.filter(isClaude).map(\.tty)),
            busy: Set(inTabs.filter { p in
                p.names.first == "caffeinate" && processes[p.parent].map(isClaude) == true
            }.map(\.tty))
        )
    }

    static func programName(_ word: Substring) -> String {
        let base = word.split(separator: "/").last.map(String.init) ?? String(word)
        return base.split(separator: ".").first.map(String.init) ?? base
    }
}
