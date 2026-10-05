import Foundation

public struct HookSpec: Sendable {
    public let event: String        // "UserPromptSubmit", "Notification", etc.
    public let matcher: String?     // "AskUserQuestion|ExitPlanMode", or nil
    public let command: String
    public let timeout: Int         // seconds
}

public enum JSONHookMerger {

    // MARK: - Lights hook specs

    private static func spec(_ event: String, _ matcher: String?, _ signal: String) -> HookSpec {
        HookSpec(event: event, matcher: matcher, command: HookScript.command(signal), timeout: 5)
    }

    public static let claudeHookSpecs: [HookSpec] = [
        spec("SessionStart",     nil, "idle"),
        spec("UserPromptSubmit", nil, "executing"),
        spec("PreToolUse",       "AskUserQuestion|ExitPlanMode", "permission"),
        // Any finished tool means work resumed, including after a permission was granted.
        spec("PostToolUse",      "*", "executing"),
        // Only prompts that need an answer; "idle_prompt" fires on a finished session.
        spec("Notification",     "permission_prompt|elicitation_dialog", "permission"),
        spec("Stop",             nil, "idle"),
        // Rate limit, out of credit, auth failure and other API errors that end the turn.
        spec("StopFailure",      nil, "error"),
        spec("SessionEnd",       nil, "end"),
    ]

    /// Codex uses `PermissionRequest` instead of `Notification`.
    public static let codexHookSpecs: [HookSpec] = [
        spec("UserPromptSubmit",  nil, "executing"),
        spec("PreToolUse",        "AskUserQuestion|ExitPlanMode", "permission"),
        spec("PostToolUse",       nil, "executing"),
        spec("PermissionRequest", nil, "permission"),
        spec("Stop",              nil, "idle"),
    ]

    public static let currentFragments = [HookScript.relativePath]

    /// Commands written by Lights 0.1 (direct curl to the app).
    public static let legacyFragments = [
        "9876/executing", "9876/permission", "9876/idle", "9876/off"
    ]

    /// Removes any earlier Lights hooks, then adds the current ones.
    public static func installing(_ specs: [HookSpec], into settings: [String: Any]) -> [String: Any] {
        var result = settings
        removeMatching(&result, fragments: currentFragments + legacyFragments)
        merge(into: &result, specs: specs)
        return result
    }

    public static func uninstalling(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        removeMatching(&result, fragments: currentFragments + legacyFragments)
        return result
    }

    // MARK: - File helpers

    public static func backup(_ path: String) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        let stamp = f.string(from: Date())
        let bak = "\(path).bak-lights-\(stamp)"
        if fm.fileExists(atPath: bak) { return bak }
        try fm.copyItem(atPath: path, toPath: bak)
        return bak
    }

    public static func readJSON(_ path: String) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parseJSON(data, source: path)
    }

    public static func parseJSON(_ data: Data, source: String) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolIntegrationError.invalidJSON(source)
        }
        return dict
    }

    public static func serialize(_ dict: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var s = String(data: data, encoding: .utf8) ?? ""
        if !s.hasSuffix("\n") { s += "\n" }
        return Data(s.utf8)
    }

    /// Writes only when the content changes, backing up the old file first.
    /// Returns false when there was nothing to do.
    @discardableResult
    public static func update(_ path: String, _ change: ([String: Any]) -> [String: Any]) throws -> Bool {
        let before = try readJSON(path)
        let after = change(before)
        let fm = FileManager.default
        if fm.fileExists(atPath: path), try serialize(before) == serialize(after) {
            return false
        }
        _ = try backup(path)
        // Write through symlinks and keep the file's mode (settings can hold API keys).
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let mode = (try? fm.attributesOfItem(atPath: real.path))?[.posixPermissions] as? NSNumber
        try serialize(after).write(to: real, options: .atomic)
        if let mode {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: real.path)
        }
        return true
    }

    // MARK: - Merge

    /// Merge specs into settings["hooks"]. Idempotent (skips duplicate commands).
    static func merge(into settings: inout [String: Any], specs: [HookSpec]) {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for spec in specs {
            var events = hooks[spec.event] as? [[String: Any]] ?? []

            let alreadyExists = events.contains { entry in
                let arr = entry["hooks"] as? [[String: Any]] ?? []
                return arr.contains { ($0["command"] as? String) == spec.command }
            }
            if alreadyExists { continue }

            let entryIdx = events.firstIndex { entry in
                (entry["matcher"] as? String) == spec.matcher
            }

            let newHook: [String: Any] = [
                "type": "command",
                "command": spec.command,
                "timeout": spec.timeout,
            ]

            if let idx = entryIdx {
                var entry = events[idx]
                var arr = entry["hooks"] as? [[String: Any]] ?? []
                arr.append(newHook)
                entry["hooks"] = arr
                events[idx] = entry
            } else {
                var newEntry: [String: Any] = ["hooks": [newHook]]
                if let m = spec.matcher { newEntry["matcher"] = m }
                events.append(newEntry)
            }
            hooks[spec.event] = events
        }
        settings["hooks"] = hooks
    }

    /// Remove hooks whose command contains any of the given fragments.
    static func removeMatching(_ settings: inout [String: Any], fragments: [String]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let events = value as? [[String: Any]] else { continue }
            var newEvents: [[String: Any]] = []
            for entry in events {
                guard let arr = entry["hooks"] as? [[String: Any]] else {
                    newEvents.append(entry); continue
                }
                let kept = arr.filter { hook in
                    let cmd = (hook["command"] as? String) ?? ""
                    return !fragments.contains(where: { cmd.contains($0) })
                }
                if !kept.isEmpty {
                    var newEntry = entry
                    newEntry["hooks"] = kept
                    newEvents.append(newEntry)
                }
            }
            if newEvents.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = newEvents
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    /// True if any hook command contains any of the given fragments.
    public static func containsAnyHook(_ settings: [String: Any], fragments: [String]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let events = value as? [[String: Any]] else { continue }
            for entry in events {
                guard let arr = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in arr {
                    let cmd = (hook["command"] as? String) ?? ""
                    if fragments.contains(where: { cmd.contains($0) }) { return true }
                }
            }
        }
        return false
    }

    /// True when every spec's command is present under its event.
    public static func containsAll(_ specs: [HookSpec], in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return specs.allSatisfy { spec in
            let events = hooks[spec.event] as? [[String: Any]] ?? []
            return events.contains { entry in
                let arr = entry["hooks"] as? [[String: Any]] ?? []
                return arr.contains { ($0["command"] as? String) == spec.command }
            }
        }
    }
}
