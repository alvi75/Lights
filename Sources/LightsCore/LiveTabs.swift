import Foundation

/// Finds terminal tabs that still run an AI tool, or an SSH session that may run one remotely.
public enum LiveTabs {
    static let programs: Set<String> = ["claude", "codex", "ssh"]

    /// Parses `ps -axo tty=,args=`. npm installs show up as `node /path/to/claude`,
    /// so the first two words are checked.
    public static func parse(_ psOutput: String) -> Set<String> {
        var live = Set<String>()
        for line in psOutput.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 2, words[0].hasPrefix("ttys") else { continue }
            let names = words.dropFirst().prefix(2).map(programName)
            if names.contains(where: programs.contains) {
                live.insert(String(words[0]))
            }
        }
        return live
    }

    static func programName(_ word: Substring) -> String {
        let base = word.split(separator: "/").last.map(String.init) ?? String(word)
        return base.split(separator: ".").first.map(String.init) ?? base
    }
}
