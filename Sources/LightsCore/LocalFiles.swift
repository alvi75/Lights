import Foundation

/// Files Lights owns on this Mac.
public enum LocalFiles {

    /// The secret hooks must send. Creates ~/.lights/auth (mode 600, folder 700) on first use.
    public static func ensureToken(home: String = NSHomeDirectory()) throws -> String {
        let path = "\(home)/\(HookScript.authRelativePath)"
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let token = parseToken(text) {
            return token
        }
        let token = makeToken()
        try writePrivate(authLine(token), to: path)
        return token
    }

    public static func authLine(_ token: String) -> String {
        "\(HookScript.tokenHeader): \(token)\n"
    }

    public static func parseToken(_ text: String) -> String? {
        let prefix = "\(HookScript.tokenHeader): "
        guard text.hasPrefix(prefix) else { return nil }
        let token = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count >= 32 && token.allSatisfy(\.isHexDigit) ? token : nil
    }

    static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    private static func writePrivate(_ text: String, to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        guard fm.createFile(atPath: path, contents: Data(text.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw ToolIntegrationError.writeFailed(path)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Writes ~/.lights/hook.sh when missing or out of date. Returns true if it wrote.
    @discardableResult
    public static func installHookScript(home: String = NSHomeDirectory()) throws -> Bool {
        let path = "\(home)/\(HookScript.relativePath)"
        let fm = FileManager.default
        if let existing = fm.contents(atPath: path),
           existing == Data(HookScript.contents.utf8),
           fm.isExecutableFile(atPath: path) {
            return false
        }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try Data(HookScript.contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return true
    }

    /// Shell startup files that get the LC_LIGHTS_TAB line. zsh is the macOS default,
    /// bash files only when they already exist.
    public static func shellRCPaths(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        let bash = ["\(home)/.bash_profile", "\(home)/.bashrc"].filter { fm.fileExists(atPath: $0) }
        return ["\(home)/.zshrc"] + bash
    }

    public static func hasShellSnippet(home: String = NSHomeDirectory()) -> Bool {
        let path = "\(home)/.zshrc"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.contains(HookScript.shellMarker)
    }

    /// Appends the snippet to each startup file that lacks it. Appends in place, so
    /// symlinked dotfiles, permissions and the rest of the file are left alone.
    public static func installShellSnippet(home: String = NSHomeDirectory()) throws {
        for path in shellRCPaths(home: home) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let text = (try? String(contentsOfFile: real, encoding: .utf8)) ?? ""
            if text.contains(HookScript.shellMarker) { continue }
            let prefix = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            let addition = Data((prefix + "\n" + HookScript.shellSnippet + "\n").utf8)
            if !FileManager.default.fileExists(atPath: real) {
                FileManager.default.createFile(atPath: real, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: real))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: addition)
        }
    }
}
