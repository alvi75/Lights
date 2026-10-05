import Foundation
import LightsCore

final class ClaudeCodeIntegration: ToolIntegration {
    let id = "claude-code"
    let displayName = "Claude Code"
    let supportLevel: SupportLevel = .events

    var settingsPath: String { "\(NSHomeDirectory())/.claude/settings.json" }

    func detectStatus() -> InstallStatus {
        let hasSettings = FileManager.default.fileExists(atPath: settingsPath)
        guard hasSettings || isCommandAvailable("claude") else { return .toolNotInstalled }
        return hookStatus(path: settingsPath, specs: JSONHookMerger.claudeHookSpecs)
    }

    func install() throws {
        let dir = "\(NSHomeDirectory())/.claude"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try LocalFiles.installHookScript()
        try JSONHookMerger.update(settingsPath) {
            JSONHookMerger.installing(JSONHookMerger.claudeHookSpecs, into: $0)
        }
    }

    func uninstall() throws {
        try JSONHookMerger.update(settingsPath, JSONHookMerger.uninstalling)
    }
}
