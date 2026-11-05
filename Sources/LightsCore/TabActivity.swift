import Foundation

/// What each terminal tab is running, read from `ps -axo pid=,ppid=,tty=,args=`.
public struct TabActivity: Equatable, Sendable {
    /// Tabs that run an AI tool, or an SSH session that may run one remotely.
    public let live: Set<String>
    /// Claude Code processes, by the tab they run in.
    public let claude: [String: Set<Int>]
    /// Tabs running ssh.
    public let ssh: Set<String>
    /// Every running process.
    public let pids: Set<Int>

    public init(live: Set<String>, claude: [String: Set<Int>], ssh: Set<String> = [], pids: Set<Int> = []) {
        self.live = live
        self.claude = claude
        self.ssh = ssh
        self.pids = pids
    }

    static let programs: Set<String> = ["claude", "codex", "ssh"]

    private struct Process {
        let pid: Int
        let tty: String
        let names: [String]
    }

    public static func parse(_ psOutput: String) -> TabActivity {
        let processes = psOutput.split(separator: "\n").compactMap { line -> Process? in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 4, let pid = Int(words[0]) else { return nil }
            // npm installs show up as `node /path/to/claude`, so the first two words count.
            return Process(pid: pid, tty: String(words[2]), names: words.dropFirst(3).prefix(2).map(programName))
        }
        let inTabs = processes.filter { $0.tty.hasPrefix("ttys") }
        let claude = inTabs.filter { $0.names.contains("claude") }
        return TabActivity(
            live: Set(inTabs.filter { $0.names.contains(where: programs.contains) }.map(\.tty)),
            claude: Dictionary(grouping: claude, by: \.tty).mapValues { Set($0.map(\.pid)) },
            ssh: Set(inTabs.filter { $0.names.contains("ssh") }.map(\.tty)),
            pids: Set(processes.map(\.pid))
        )
    }

    static func programName(_ word: Substring) -> String {
        let base = word.split(separator: "/").last.map(String.init) ?? String(word)
        return base.split(separator: ".").first.map(String.init) ?? base
    }
}
