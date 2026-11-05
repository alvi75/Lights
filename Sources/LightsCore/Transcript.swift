import Foundation

/// Claude Code adds a line to the session transcript when you press Esc or turn down a
/// tool, a question or a plan. No hook fires for either, so Lights reads the transcript
/// the hooks name.
public enum Transcript {
    public static let maxPathLength = 1024
    static let marker = "[Request interrupted by user"

    /// Only `.jsonl` files under your home folder, named without `..` or the like.
    public static func isAllowed(_ path: String, home: String) -> Bool {
        let base = home.hasSuffix("/") ? home : home + "/"
        return home.count > 1
            && path.utf8.count <= maxPathLength
            && path.hasSuffix(".jsonl")
            && path.hasPrefix(base)
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && (path as NSString).standardizingPath == path
    }

    /// Bytes at the start of `data` that make up whole lines; the rest is still being written.
    public static func completeLength(of data: Data) -> Int {
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        return data.distance(from: data.startIndex, to: last) + 1
    }

    /// True if one of `lines` is the note Claude Code writes for an interrupt.
    public static func hasInterrupt(_ lines: Data) -> Bool {
        let needle = Data(marker.utf8)
        return lines.split(separator: UInt8(ascii: "\n")).contains { line in
            line.range(of: needle) != nil && isInterrupt(line)
        }
    }

    private static func isInterrupt(_ line: Data) -> Bool {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "user",
              let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { block in
            block["type"] as? String == "text" && (block["text"] as? String)?.hasPrefix(marker) == true
        }
    }
}
