import Foundation
import LightsCore

enum SupportLevel {
    case events           // Real implementation: full event hooks
    case comingSoon       // Tool exists but integration not yet written
    case notSupported     // Tool has no event hooks at all
}

enum InstallStatus: Equatable {
    case toolNotInstalled
    case toolPresentHookMissing
    case outdated               // hooks from an older Lights; Install updates them
    case configured
    case unknown(String)
}

protocol ToolIntegration: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var supportLevel: SupportLevel { get }
    func blurb(for status: InstallStatus) -> String

    func detectStatus() -> InstallStatus
    func install() throws
    func uninstall() throws
}

extension ToolIntegration {
    /// Status of a JSON hooks file that should hold `specs`.
    func hookStatus(path: String, specs: [HookSpec]) -> InstallStatus {
        do {
            let dict = try JSONHookMerger.readJSON(path)
            if JSONHookMerger.containsAll(specs, in: dict),
               FileManager.default.isExecutableFile(atPath: "\(NSHomeDirectory())/\(HookScript.relativePath)") {
                return .configured
            }
            let any = JSONHookMerger.currentFragments + JSONHookMerger.legacyFragments
            return JSONHookMerger.containsAnyHook(dict, fragments: any) ? .outdated : .toolPresentHookMissing
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    func blurb(for status: InstallStatus) -> String {
        switch status {
        case .toolNotInstalled:        return "Not installed"
        case .toolPresentHookMissing:  return "Installed — Lights hook missing"
        case .outdated:                return "Older Lights hooks — click Update"
        case .configured:              return "Hooks configured ✓"
        case .unknown(let why):        return "Error: \(why)"
        }
    }

    /// Apps opened from Finder get a minimal PATH, so also look where installers put tools.
    func isCommandAvailable(_ cmd: String) -> Bool {
        let home = NSHomeDirectory()
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                    "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        if dirs.contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(cmd)") }) {
            return true
        }
        return Shell.run("/usr/bin/which", [cmd], timeout: 2).succeeded
    }
}
