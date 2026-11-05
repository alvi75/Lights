import Foundation
import LightsCore

// Run with: swift run lights-selftest

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if ok {
        passes += 1
    } else {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

func tempHome() -> String {
    let dir = NSTemporaryDirectory() + "lights-selftest-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Signals and colors

check(Signal("executing") == .set(.working), "executing means working")
check(Signal("permission") == .set(.needsYou), "permission needs you")
check(Signal("error") == .set(.needsYou), "API error needs you")
check(Signal("idle") == .set(.done), "idle means done")
check(Signal("end") == .end && Signal("off") == .end, "end and off clear the session")
check(Signal("bogus") == nil, "unknown signal rejected")
check(SessionState.needsYou.light == .red, "needs you is red")
check(SessionState.working.light == .yellow, "working is yellow")
check(SessionState.done.light == .green, "done is green")

// MARK: - SessionStore

do {
    let t0 = Date()
    var store = SessionStore()
    store.apply(.set(.working), tab: "ttys001", at: t0)
    store.apply(.set(.done), tab: "ttys002", at: t0)
    check(store.displayed(following: .tab("ttys001")) == .working, "follows the focused tab")
    check(store.displayed(following: .tab("ttys002")) == .done, "switching tabs switches state")
    check(store.displayed(following: .tab("ttys009")) == nil, "tab without a session shows off")

    store.apply(.set(.needsYou), tab: "ttys002", at: t0)
    check(store.displayed(following: nil) == .needsYou, "no followed tab shows the most urgent")

    store.apply(.set(.working), tab: "ttys002", at: t0.addingTimeInterval(0.1))
    check(store.state(of: "ttys002") == .needsYou, "working right after a prompt is ignored")
    store.apply(.set(.working), tab: "ttys002", at: t0.addingTimeInterval(0.5))
    check(store.state(of: "ttys002") == .working, "working after the hold is accepted")

    store.apply(.end, tab: "ttys002", at: t0)
    check(store.state(of: "ttys002") == nil, "session end removes the tab")

    store.apply(.set(.done), tab: SessionStore.unknownTab, at: t0)
    check(store.displayed(following: .tab("ttys009")) == .done, "tab without its own report falls back to tabless reports")
    store.retain(liveTabs: [])
    check(store.tabs == [SessionStore.unknownTab], "closed tabs dropped, unknown bucket kept")
}

do {
    let t0 = Date()
    var store = SessionStore()
    store.apply(.set(.done), tab: "ttys001", at: t0)
    store.apply(.set(.working), tab: "vscodepts76devbox", at: t0)
    store.apply(.set(.needsYou), tab: "vscodepts136devbox", at: t0)
    check(store.displayed(following: .editor) == .needsYou, "editor shows its most urgent session")
    check(store.displayed(following: .tab("ttys001")) == .done, "terminal tab ignores editor sessions")
    store.retain(liveTabs: [])
    check(store.state(of: "vscodepts76devbox") == .working, "editor sessions survive tab pruning")
    check(store.state(of: "ttys001") == nil, "closed terminal tab pruned")
    store.apply(.end, tab: "vscodepts136devbox", at: t0)
    store.apply(.end, tab: "vscodepts76devbox", at: t0)
    check(store.displayed(following: .editor) == nil, "editor with no sessions shows off")
}

// MARK: - Routes

check(Route(path: "/state?s=executing&tab=ttys002") == .signal(.set(.working), tab: "ttys002", transcript: nil), "state route")
check(Route(path: "/state?s=idle&tab=ttys002&transcript=%2FUsers%2Fme%2F.claude%2Fprojects%2Fp%2Fs.jsonl")
      == .signal(.set(.done), tab: "ttys002", transcript: "/Users/me/.claude/projects/p/s.jsonl"), "transcript passed along")
check(Route(path: "/state?s=idle&tab=ttys002&transcript=/" + String(repeating: "a", count: 2000) + ".jsonl")
      == .signal(.set(.done), tab: "ttys002", transcript: nil), "overlong transcript dropped, state kept")
check(Route(path: "/state?s=idle") == .signal(.set(.done), tab: SessionStore.unknownTab, transcript: nil), "state without tab")
check(Route(path: "/state?s=idle&tab=../etc") == .badRequest, "odd tab names rejected")
check(Route(path: "/state?s=nope&tab=ttys001") == .badRequest, "unknown state rejected")
check(Route(path: "/permission") == .signal(.set(.needsYou), tab: SessionStore.unknownTab, transcript: nil), "old path still works")
check(Route(path: "/status") == .status, "status route")
check(Route(path: "/nope") == .notFound, "unknown path")
check(Route.isFromBrowser("GET /idle HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\n\r\n"), "browser request detected")
check(Route.isFromBrowser("GET /idle HTTP/1.1\r\nHost: x\r\nSec-Fetch-Mode: no-cors\r\n\r\n"), "fetch metadata detected")
check(!Route.isFromBrowser("GET /idle HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: curl/8.7.1\r\n\r\n"), "curl allowed")

// MARK: - Token

do {
    let token = String(repeating: "ab", count: 32)
    let request = "GET /state?s=idle HTTP/1.1\r\nHost: 127.0.0.1\r\nx-lights-token:  \(token)\r\n\r\n"
    check(Route.token(in: request) == token, "token header read, any case")
    check(Route.token(in: "GET / HTTP/1.1\r\nHost: x\r\n\r\nX-Lights-Token: \(token)") == nil, "token in body ignored")
    check(Route.tokenMatches(token, token), "matching token accepted")
    check(!Route.tokenMatches(String(token.dropLast()) + "c", token), "wrong token rejected")
    check(!Route.tokenMatches(nil, token), "missing token rejected")
    check(!Route.tokenMatches("", ""), "empty token never matches")

    let home = tempHome()
    let first = try? LocalFiles.ensureToken(home: home)
    let second = try? LocalFiles.ensureToken(home: home)
    check(first != nil && first == second, "token created once and reused")
    check(first?.count == 64, "token is 256 bits of hex")
    let attrs = try? FileManager.default.attributesOfItem(atPath: home + "/.lights/auth")
    check((attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "auth file is owner-only")
    let dirAttrs = try? FileManager.default.attributesOfItem(atPath: home + "/.lights")
    check((dirAttrs?[.posixPermissions] as? NSNumber)?.intValue == 0o700, "auth folder is owner-only")
    check(LocalFiles.parseToken("X-Lights-Token: abc123") == nil, "short token rejected")
    check(LocalFiles.parseToken("X-Lights-Token: " + String(repeating: "z", count: 64)) == nil, "non-hex token rejected")
}

// MARK: - Tab activity

do {
    let ps = """
      100     1 ttys001  -zsh
      101   100 ttys001  claude
      102   101 ttys001  caffeinate -i -t 300
      200     1 ttys002  node /opt/homebrew/bin/claude --resume
      300     1 ttys003  ssh devbox
      400     1 ttys004  vim notes.txt
      401   400 ttys004  caffeinate -i
      500     1 ttys005  /Users/me/.local/bin/codex
      600     1 ??       /usr/sbin/sshd
      700     1 ??       claude bg-pty-host
      701   700 ttys009  claude bg-spare
      702   701 ttys009  caffeinate -i -t 300
    """
    let activity = TabActivity.parse(ps)
    check(activity.live == ["ttys001", "ttys002", "ttys003", "ttys005", "ttys009"], "live tabs found")
    check(activity.claude == ["ttys001", "ttys002", "ttys009"], "Claude Code tabs found, npm installs too")
    check(activity.busy == ["ttys001", "ttys009"], "busy means Claude Code's own keep-awake process")
    check(TabActivity.parse("garbage\n\n  12 x\n").live.isEmpty, "unparseable ps lines skipped")
}

// MARK: - Checking hook states against Claude Code's activity

do {
    let t0 = Date()
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    let busy = TabActivity(live: ["ttys001"], claude: ["ttys001"], busy: ["ttys001"])
    let idle = TabActivity(live: ["ttys001"], claude: ["ttys001"], busy: [])

    var store = SessionStore()
    store.apply(.set(.working), tab: "ttys001", at: t0)
    store.reconcile(with: busy, at: at(1))
    store.reconcile(with: idle, at: at(3))
    check(store.state(of: "ttys001") == .working, "a short gap in the keep-awake process is ignored")
    store.reconcile(with: busy, at: at(4))
    store.reconcile(with: idle, at: at(8))
    check(store.state(of: "ttys001") == .working, "still within the grace period")
    store.reconcile(with: idle, at: at(10))
    check(store.state(of: "ttys001") == .done, "working, then stopped without a hook (Esc) turns green")

    var unseen = SessionStore()
    unseen.apply(.set(.working), tab: "ttys001", at: t0)
    unseen.reconcile(with: idle, at: at(60))
    check(unseen.state(of: "ttys001") == .working, "never seen working: no keep-awake process to go by, state kept")

    var prompt = SessionStore()
    prompt.apply(.set(.working), tab: "ttys001", at: t0)
    prompt.reconcile(with: busy, at: at(1))
    prompt.apply(.set(.needsYou), tab: "ttys001", at: at(2))
    prompt.reconcile(with: busy, at: at(4))
    check(prompt.state(of: "ttys001") == .needsYou, "a waiting prompt stays red while the process lingers")
    prompt.reconcile(with: idle, at: at(6))
    prompt.reconcile(with: busy, at: at(7))
    check(prompt.state(of: "ttys001") == .needsYou, "the keep-awake process's restart gap doesn't count as approval")
    prompt.reconcile(with: idle, at: at(40))
    check(prompt.state(of: "ttys001") == .needsYou, "a long wait stays red")
    prompt.reconcile(with: busy, at: at(50))
    check(prompt.state(of: "ttys001") == .working, "working again after the wait means you approved it")

    var done = SessionStore()
    done.apply(.set(.done), tab: "ttys001", at: t0)
    done.reconcile(with: busy, at: at(1))
    check(done.state(of: "ttys001") == .done, "the keep-awake process lingers after a turn; green stays")

    var fresh = SessionStore()
    fresh.reconcile(with: TabActivity(live: ["ttys001", "ttys002", "ttys005"], claude: ["ttys001", "ttys002"], busy: ["ttys001"]), at: t0)
    check(fresh.state(of: "ttys001") == .working, "after a restart a working session shows yellow")
    check(fresh.state(of: "ttys002") == .done, "after a restart an idle session shows green")
    check(fresh.state(of: "ttys005") == nil, "other tools aren't guessed")

    fresh.apply(.end, tab: "ttys002", at: at(1))
    fresh.reconcile(with: TabActivity(live: ["ttys002"], claude: ["ttys002"], busy: []), at: at(2))
    check(fresh.state(of: "ttys002") == nil, "an ended session isn't brought back while its process exits")
    fresh.retain(liveTabs: [])
    fresh.reconcile(with: TabActivity(live: ["ttys002"], claude: ["ttys002"], busy: []), at: at(9))
    check(fresh.state(of: "ttys002") == .done, "a tab closed and reused starts fresh")

    var remote = SessionStore()
    remote.apply(.set(.working), tab: "ttys003", at: t0)
    remote.reconcile(with: TabActivity(live: ["ttys003"], claude: [], busy: []), at: at(60))
    check(remote.state(of: "ttys003") == .working, "tabs running ssh are left to their hooks")
}

// MARK: - Redrawing the light

do {
    var gate = DisplayGate()
    check(gate.shouldShow(nil, isReport: false), "first state is drawn")
    check(gate.shouldShow(.working, isReport: true), "a change is drawn")
    check(!gate.shouldShow(.working, isReport: true), "the same state isn't redrawn")
    gate.pickedByHand()
    check(!gate.shouldShow(.working, isReport: false), "a light picked by hand stays through a quiet check")
    check(gate.shouldShow(.working, isReport: true), "the next hook report replaces a light picked by hand")
    check(!gate.shouldShow(.working, isReport: true), "after that, the same report isn't redrawn")
    gate.pickedByHand()
    check(gate.shouldShow(.done, isReport: false), "a real change replaces a light picked by hand")
}

// MARK: - Transcripts

do {
    let home = "/Users/me"
    check(Transcript.isAllowed("/Users/me/.claude/projects/-Users-me-app/1a2b.jsonl", home: home), "transcript in home allowed")
    check(!Transcript.isAllowed("/etc/passwd.jsonl", home: home), "outside home refused")
    check(!Transcript.isAllowed("/Users/me/../other/x.jsonl", home: home), "dot-dot refused")
    check(!Transcript.isAllowed("/Users/me/.ssh/id_ed25519", home: home), "only .jsonl files")
    check(!Transcript.isAllowed("/Users/meyer/x.jsonl", home: home), "a home with a longer name isn't inside home")
    check(!Transcript.isAllowed("/Users/me/a\nb.jsonl", home: home), "control characters refused")
    check(!Transcript.isAllowed("relative/x.jsonl", home: home), "relative path refused")

    let esc = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
    let escText = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    let toolOutput = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"[Request interrupted by user]"}]}]}}"#
    let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    let prompt = #"{"type":"user","message":{"role":"user","content":"why did it stop"}}"#
    func lines(_ items: String...) -> Data { Data((items.joined(separator: "\n") + "\n").utf8) }
    check(Transcript.hasInterrupt(lines(prompt, esc)), "Esc at a prompt or tool found")
    check(Transcript.hasInterrupt(lines(escText)), "Esc while writing found")
    check(!Transcript.hasInterrupt(lines(prompt, toolOutput)), "the marker inside tool output doesn't count")
    check(!Transcript.hasInterrupt(lines(assistant)), "the marker in Claude's reply doesn't count")
    check(!Transcript.hasInterrupt(Data(#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted"#.utf8)), "a cut-off line doesn't count")

    let partial = Data("one\ntwo\nthr".utf8)
    check(Transcript.completeLength(of: partial) == 8, "only whole lines are read")
    check(Transcript.completeLength(of: Data("no newline".utf8)) == 0, "a line still being written waits")
}

// MARK: - Hook merging

do {
    let legacy = "curl -s --max-time 1 http://127.0.0.1:9876/idle >/dev/null 2>&1 || true"
    let user: [String: Any] = ["type": "command", "command": "my-own-hook.sh"]
    let settings: [String: Any] = [
        "model": "opus",
        "hooks": [
            "Stop": [["hooks": [user, ["type": "command", "command": legacy, "timeout": 2000]]]],
        ],
    ]
    let installed = JSONHookMerger.installing(JSONHookMerger.claudeHookSpecs, into: settings)
    check(JSONHookMerger.containsAll(JSONHookMerger.claudeHookSpecs, in: installed), "all hooks added")
    check(JSONHookMerger.claudeHookSpecs.contains { $0.event == "PostToolUseFailure" && $0.command.hasSuffix(" executing") },
          "a failed tool also means work resumed")
    check(!JSONHookMerger.containsAnyHook(installed, fragments: JSONHookMerger.legacyFragments), "old curl hooks removed")
    check(JSONHookMerger.containsAnyHook(installed, fragments: ["my-own-hook.sh"]), "user hooks kept")
    check(installed["model"] as? String == "opus", "other settings kept")

    let twice = JSONHookMerger.installing(JSONHookMerger.claudeHookSpecs, into: installed)
    check((try? JSONHookMerger.serialize(twice)) == (try? JSONHookMerger.serialize(installed)), "install is idempotent")

    let removed = JSONHookMerger.uninstalling(from: installed)
    check(!JSONHookMerger.containsAnyHook(removed, fragments: JSONHookMerger.currentFragments), "uninstall removes ours")
    check(JSONHookMerger.containsAnyHook(removed, fragments: ["my-own-hook.sh"]), "uninstall keeps user hooks")
}

do {
    let home = tempHome()
    let path = home + "/settings.json"
    try "{\"model\": \"opus\"}\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    let install = { JSONHookMerger.installing(JSONHookMerger.claudeHookSpecs, into: $0) }
    check((try? JSONHookMerger.update(path, install)) == true, "first install writes")
    check((try? JSONHookMerger.update(path, install)) == false, "second install is a no-op")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: home))?.filter { $0.contains("bak-lights") } ?? []
    check(backups.count == 1, "one backup, not one per click")
    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600, "settings file keeps its permissions")
}

// MARK: - Local files

do {
    let home = tempHome()
    check((try? LocalFiles.installHookScript(home: home)) == true, "hook script written")
    check((try? LocalFiles.installHookScript(home: home)) == false, "unchanged script not rewritten")
    check(FileManager.default.isExecutableFile(atPath: home + "/.lights/hook.sh"), "hook script executable")

    try "export PATH=/bin".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
    try? LocalFiles.installShellSnippet(home: home)
    try? LocalFiles.installShellSnippet(home: home)
    let rc = (try? String(contentsOfFile: home + "/.zshrc", encoding: .utf8)) ?? ""
    check(rc.components(separatedBy: HookScript.shellMarker).count == 2, "shell line added once")
    check(rc.hasPrefix("export PATH=/bin\n"), "existing shell config kept")
}

// MARK: - Remote setup

check(RemoteSetup.isValidAlias("devbox"), "plain alias")
check(RemoteSetup.isValidAlias("me@build.example.com"), "user@host")
check(!RemoteSetup.isValidAlias("-oProxyCommand=evil"), "option injection rejected")
check(!RemoteSetup.isValidAlias("-v"), "bare ssh flag rejected")
check(!RemoteSetup.isValidAlias("host; rm -rf ~"), "shell syntax rejected")
check(!RemoteSetup.isValidAlias(""), "empty rejected")
do {
    let args = RemoteSetup.tunnelArguments(for: RemoteHost(alias: "devbox", port: 21234))
    check(args.contains("127.0.0.1:21234:127.0.0.1:9876") && args.last == "devbox", "tunnel forwards the port")
    check(RemoteSetup.isTunnelCommand("/usr/bin/ssh " + args.joined(separator: " ")), "own tunnel recognized")
    check(!RemoteSetup.isTunnelCommand("ssh devbox"), "user ssh not touched")
    check(RemoteSetup.parseOutput("port=21234\nclaude=yes\n") == ["port": "21234", "claude": "yes"], "setup output parsed")
    check(RemoteSetup.isUsablePort(21234) && !RemoteSetup.isUsablePort(22) && !RemoteSetup.isUsablePort(70000), "port range checked")
    let script = RemoteSetup.installScript(authLine: "X-Lights-Token: abc\n")
    check(script.hasPrefix("set -e\numask 077"), "remote files created owner-only")
    check(script.contains("X-Lights-Token: abc\nLIGHTS_AUTH_EOF"), "token written via quoted heredoc")
    check(RemoteSetup.writeSettingsScript.contains("cp -p") && !RemoteSetup.writeSettingsScript.contains("mv "), "remote settings keep mode and symlinks")
    let ports = (0..<50).map { _ in RemoteSetup.randomTunnelPort() }
    check(ports.allSatisfy { (20000..<60000).contains($0) }, "tunnel ports stay in range")
    check(Set(ports).count > 1, "each tunnel gets a fresh port")
}

// MARK: - Hook script on an SSH machine

/// Runs `script` with sh in `home`, with a fake curl that logs its arguments
/// and prints `curlReply` (empty: fails like an unreachable port).
func runShell(_ script: String, home: String, curlReply: String = "") -> (status: Int32, curlLog: String) {
    let bin = home + "/bin"
    try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    let fake = """
    #!/bin/sh
    echo "$*" >> "\(home)/curl.log"
    [ -n "\(curlReply)" ] || exit 7
    echo "\(curlReply)"

    """
    try? fake.write(toFile: bin + "/curl", atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/curl")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", script]
    task.environment = ["HOME": home, "PATH": bin + ":/usr/bin:/bin"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    let log = (try? String(contentsOfFile: home + "/curl.log", encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(atPath: home + "/curl.log")
    return (task.terminationStatus, log)
}

/// Same name the hook scripts use for this machine.
func shortHostname() -> String {
    let task = Process(), out = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "hostname -s 2>/dev/null || hostname"]
    task.standardOutput = out
    try? task.run()
    task.waitUntilExit()
    let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return name.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
}

do {
    let home = tempHome()
    let host = shortHostname()
    let dir = home + "/.lights"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try HookScript.contents.write(toFile: dir + "/hook.sh", atomically: true, encoding: .utf8)
    try "X-Lights-Token: abc\n".write(toFile: dir + "/auth", atomically: true, encoding: .utf8)
    try "41000\n".write(toFile: dir + "/port", atomically: true, encoding: .utf8)
    let hook = "sh \"$HOME/.lights/hook.sh\" idle"

    check(runShell(hook, home: home).curlLog.contains("127.0.0.1:41000/"), "hook uses the shared port file")

    // A machine still running an older hook gets the current one when its tunnel is pointed.
    try "#!/bin/sh\necho old\n".write(toFile: dir + "/hook.sh", atomically: true, encoding: .utf8)

    // Point the hook at a working tunnel, then check the hook follows it.
    let pointed = runShell(RemoteSetup.pointHookScript(port: 42000), home: home, curlReply: "lights ok")
    check(pointed.status == 0, "pointing succeeds when the tunnel answers")
    check(pointed.curlLog.contains("127.0.0.1:42000/health"), "pointing checks the new port first")
    let portFile = (try? String(contentsOfFile: dir + "/port-\(host)", encoding: .utf8)) ?? ""
    check(portFile == "42000\n", "this machine's port file written")
    let installed = (try? String(contentsOfFile: dir + "/hook.sh", encoding: .utf8)) ?? ""
    check(installed == HookScript.contents, "pointing installs the current hook")
    check(FileManager.default.isExecutableFile(atPath: dir + "/hook.sh"), "pointed hook is executable")
    check(runShell(hook, home: home).curlLog.contains("127.0.0.1:42000/"), "hook prefers this machine's port over the shared one")

    // A tunnel that doesn't reach the Mac must not take the hook away from a working one.
    let dead = runShell(RemoteSetup.pointHookScript(port: 43000), home: home)
    check(dead.status != 0, "pointing fails when the tunnel doesn't answer")
    let kept = (try? String(contentsOfFile: dir + "/port-\(host)", encoding: .utf8)) ?? ""
    check(kept == "42000\n", "port file left alone when the new tunnel doesn't answer")

    // Two pointings at once on one machine (a reconnect while the last one is still checking).
    // Each runs in its own sh, as each ssh login does.
    try RemoteSetup.pointHookScript(port: 44000).write(toFile: home + "/a.sh", atomically: true, encoding: .utf8)
    try RemoteSetup.pointHookScript(port: 44001).write(toFile: home + "/b.sh", atomically: true, encoding: .utf8)
    let both = "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sh \"$HOME/a.sh\" & p1=$!; sh \"$HOME/b.sh\" & p2=$!; wait $p1 || exit 1; wait $p2 || exit 1; done"
    check(runShell(both, home: home, curlReply: "lights ok").status == 0, "concurrent pointings don't fail each other")
}

// MARK: - Hook script on this Mac

do {
    let home = tempHome()
    let dir = home + "/.lights"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try HookScript.contents.write(toFile: dir + "/hook.sh", atomically: true, encoding: .utf8)
    try "X-Lights-Token: abc\n".write(toFile: dir + "/auth", atomically: true, encoding: .utf8)
    let input = #"{"session_id":"s1","transcript_path":"/Users/me/.claude/projects/-Users-me-app/s1.jsonl","cwd":"/Users/me/app","tool_response":{"stdout":"\"transcript_path\":\"/evil.jsonl\""}}"#
    try input.write(toFile: home + "/input.json", atomically: true, encoding: .utf8)

    let claude = runShell("CLAUDE_PROJECT_DIR=/Users/me/app sh \"$HOME/.lights/hook.sh\" executing < \"$HOME/input.json\"", home: home)
    check(claude.status == 0, "hook exits cleanly")
    check(claude.curlLog.contains("127.0.0.1:9876/state?s=executing&tab="), "hook reports the state")
    check(claude.curlLog.contains("--data-urlencode transcript=/Users/me/.claude/projects/-Users-me-app/s1.jsonl"), "hook passes Claude Code's transcript")
    check(!claude.curlLog.contains("evil"), "a path inside tool output isn't taken for the transcript")

    let stopped = #"{"hook_event_name":"PostToolUseFailure","transcript_path":"/Users/me/.claude/projects/p/s1.jsonl","is_interrupt":true}"#
    try stopped.write(toFile: home + "/stopped.json", atomically: true, encoding: .utf8)
    let esc = runShell("CLAUDE_PROJECT_DIR=/Users/me/app sh \"$HOME/.lights/hook.sh\" executing < \"$HOME/stopped.json\"", home: home)
    check(esc.status == 0 && esc.curlLog.isEmpty, "a tool cut short by Esc isn't reported as working")

    let other = runShell("sh \"$HOME/.lights/hook.sh\" executing < \"$HOME/input.json\"", home: home)
    check(other.curlLog.contains("s=executing") && !other.curlLog.contains("transcript"), "other tools' input isn't read")
}

// MARK: - Window placement

do {
    // Laptop is primary; a 1440p monitor sits to its left, lower edge below the laptop's.
    let laptop = DisplayArea(id: "laptop", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                             visible: CGRect(x: 0, y: 57, width: 1512, height: 892))
    let monitor = DisplayArea(id: "monitor", frame: CGRect(x: -2560, y: -404, width: 2560, height: 1440),
                              visible: CGRect(x: -2560, y: -404, width: 2560, height: 1440))
    let size = CGSize(width: 58, height: 150)
    let onMonitor = CGRect(x: -400, y: 300, width: 58, height: 150)

    let saved = WindowPlacement.save(frame: onMonitor, displays: [laptop, monitor])
    check(saved?.display == "monitor", "spot is saved against the monitor")

    let back = WindowPlacement.frame(for: size, saved: saved, current: nil, displays: [laptop, monitor])
    check(back == onMonitor, "saved spot restored on the same monitor")

    // Asleep: only the laptop is left, and macOS has dropped the window in its middle.
    let dropped = CGRect(x: -20, y: 400, width: 58, height: 150)
    let alone = WindowPlacement.frame(for: size, saved: saved, current: dropped, displays: [laptop])
    check(alone.map { laptop.visible.contains($0) } == true, "while the monitor is gone the light stays fully on the laptop")

    let woke = WindowPlacement.frame(for: size, saved: saved, current: alone, displays: [laptop, monitor])
    check(woke == onMonitor, "light goes back to the monitor when it returns")

    // Monitor arrangement moved: keep the distance from the monitor's top-right corner.
    let moved = DisplayArea(id: "monitor", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                            visible: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
    let rearranged = WindowPlacement.frame(for: size, saved: saved, current: nil, displays: [laptop, moved])
    check(rearranged == CGRect(x: 1512 + 2160, y: 704, width: 58, height: 150), "spot follows the monitor when displays are rearranged")

    let straddle = CGRect(x: -30, y: 400, width: 58, height: 150)
    let fixed = WindowPlacement.frame(for: size, saved: nil, current: straddle, displays: [laptop, monitor])
    check(fixed.map { laptop.visible.contains($0) || monitor.visible.contains($0) } == true, "a light split across two displays is pulled onto one")

    let first = WindowPlacement.frame(for: size, saved: nil, current: nil, displays: [laptop, monitor])
    check(first == CGRect(x: 1512 - 58 - 24, y: 949 - 150 - 24, width: 58, height: 150), "first launch goes to the main display's top-right")

    let bigger = WindowPlacement.frame(for: CGSize(width: 80, height: 200), saved: saved, current: nil, displays: [laptop, monitor])
    check(bigger.map { $0.maxX == onMonitor.maxX && $0.maxY == onMonitor.maxY } == true, "resized light keeps its top-right corner")

    check(WindowPlacement.save(frame: CGRect(x: 9000, y: 9000, width: 58, height: 150), displays: [laptop]) == nil, "nothing saved for a window on no display")
    check(WindowPlacement.frame(for: size, saved: saved, current: nil, displays: []) == nil, "no displays, no placement")

    let encoded = try? JSONEncoder().encode(saved)
    check(encoded.flatMap { try? JSONDecoder().decode(SavedPlacement.self, from: $0) } == saved, "saved spot round-trips")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
