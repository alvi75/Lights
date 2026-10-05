import AppKit
import LightsCore

/// Follows the terminal tab you last focused, or VS Code when that was last in front.
/// Switching to any other app keeps what was followed; clicking into a different tab,
/// window or editor switches to it.
@MainActor
final class FocusTracker {
    /// Terminals that report the focused tab's tty over AppleScript.
    static let scripts: [String: String] = [
        "com.apple.Terminal":
            #"tell application id "com.apple.Terminal" to tty of selected tab of front window"#,
        "com.googlecode.iterm2":
            #"tell application id "com.googlecode.iterm2" to tty of current session of current window"#,
    ]

    /// VS Code and forks. Their terminals set TERM_PROGRAM=vscode, which the hook reports.
    static let editors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
        "com.vscodium",
    ]

    private let queue = DispatchQueue(label: "lights.focus")
    private var timer: Timer?
    private var livenessTimer: Timer?
    private var isQuerying = false
    private var hasFollowed = false
    private var failures = 0
    private var pausedUntil = Date.distantPast
    private let model: LightsModel

    init(model: LightsModel) {
        self.model = model
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocus() }
        }
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneClosedTabs() }
        }
        checkFocus()
    }

    private func checkFocus() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.editors.contains(front) {
            hasFollowed = true
            model.follow(.editor)
            return
        }
        guard !isQuerying, Date() >= pausedUntil, let bundle = terminalToAsk() else { return }
        isQuerying = true
        let script = Self.scripts[bundle] ?? ""
        queue.async { [weak self] in
            let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 3)
            let tty = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isQuerying = false
                guard result.succeeded, tty.hasPrefix("/dev/") else {
                    self.noteFailure(result.stderr)
                    return
                }
                self.failures = 0
                self.hasFollowed = true
                self.model.follow(.tab(String(tty.dropFirst("/dev/".count))))
            }
        }
    }

    /// Slows down after repeated failures, e.g. when Automation access was denied (-1743).
    private func noteFailure(_ stderr: String) {
        failures += 1
        guard failures >= 3 else { return }
        if failures == 3 {
            NSLog("[Lights] can't read the focused terminal tab: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines)). Allow Lights under System Settings → Privacy & Security → Automation.")
        }
        pausedUntil = Date().addingTimeInterval(10)
    }

    /// The frontmost terminal; before anything is followed, any running one.
    private func terminalToAsk() -> String? {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.scripts[front] != nil {
            return front
        }
        guard !hasFollowed else { return nil }
        return Self.scripts.keys.sorted().first {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    private func pruneClosedTabs() {
        queue.async { [weak self] in
            let result = Shell.run("/bin/ps", ["-axo", "tty=,args="], timeout: 5)
            guard result.succeeded else { return }
            let live = LiveTabs.parse(result.stdout)
            DispatchQueue.main.async { self?.model.retain(liveTabs: live) }
        }
    }
}
