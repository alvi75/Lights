import Foundation
import LightsCore

final class CodexIntegration: ToolIntegration {
    let id = "codex-cli"
    let displayName = "Codex CLI"
    let supportLevel: SupportLevel = .events

    var hooksPath:  String { "\(NSHomeDirectory())/.codex/hooks.json" }
    var configPath: String { "\(NSHomeDirectory())/.codex/config.toml" }
    var dir:        String { "\(NSHomeDirectory())/.codex" }

    func detectStatus() -> InstallStatus {
        let hasDir = FileManager.default.fileExists(atPath: dir)
        guard hasDir || isCommandAvailable("codex") else { return .toolNotInstalled }
        return hookStatus(path: hooksPath, specs: JSONHookMerger.codexHookSpecs)
    }

    func install() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try LocalFiles.installHookScript()
        try JSONHookMerger.update(hooksPath) {
            JSONHookMerger.installing(JSONHookMerger.codexHookSpecs, into: $0)
        }
        try ensureFeaturesHooksEnabled()
    }

    func uninstall() throws {
        try JSONHookMerger.update(hooksPath, JSONHookMerger.uninstalling)
        // Don't touch features.hooks — user may need it for other tools.
    }

    /// Append `features.hooks = true` to config.toml if not present.
    /// No TOML parser — simple text scan.
    private func ensureFeaturesHooksEnabled() throws {
        let fm = FileManager.default
        var content = ""
        if fm.fileExists(atPath: configPath) {
            content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        }
        // Already there (inline form)?
        if content.range(of: #"features\.hooks\s*=\s*true"#,
                         options: .regularExpression) != nil {
            return
        }
        // Already there inside [features] section?
        if content.contains("[features]"),
           content.range(of: #"(?m)^\s*hooks\s*=\s*true"#,
                         options: .regularExpression) != nil {
            return
        }
        _ = try? JSONHookMerger.backup(configPath)
        var newContent = content
        if !newContent.isEmpty && !newContent.hasSuffix("\n") { newContent += "\n" }
        newContent += "\n# Lights: enable lifecycle hooks subsystem\nfeatures.hooks = true\n"
        try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}
