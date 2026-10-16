import Foundation

/// An SSH machine whose AI sessions report back through a reverse tunnel.
public struct RemoteHost: Codable, Equatable, Sendable {
    public let alias: String   // as typed for `ssh <alias>`
    public let port: Int       // port on the remote machine that tunnels to 127.0.0.1:9876 here

    public init(alias: String, port: Int) {
        self.alias = alias
        self.port = port
    }
}

public enum RemoteSetup {

    /// An ssh destination such as `devbox` or `me@example.com`. Rejects anything ssh could
    /// read as an option or that holds spaces or shell syntax.
    public static func isValidAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 255, !alias.hasPrefix("-") else { return false }
        return alias.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._@-".contains($0)) }
    }

    /// Options for every non-interactive ssh call: never prompt, fail fast,
    /// and stay out of any ControlMaster the user's config sets up.
    public static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
    ]

    public static func tunnelArguments(for host: RemoteHost) -> [String] {
        sshOptions + [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-R", "127.0.0.1:\(host.port):127.0.0.1:9876",
            host.alias,
        ]
    }

    /// Tells our tunnels apart from the user's own ssh processes in `ps` output.
    public static func isTunnelCommand(_ args: String) -> Bool {
        args.contains("BatchMode=yes") && args.contains(":127.0.0.1:9876") && args.contains(" -N ")
    }

    static let portRange = 1024...65535

    /// A new port for every tunnel. A dropped connection can hold its old port on the
    /// machine for hours, so reusing it would leave the tunnel unable to start.
    public static func randomTunnelPort() -> Int {
        Int.random(in: 20000..<60000)
    }

    /// Runs on the machine once a tunnel is up: checks the port reaches this Mac, then
    /// points the hook at it through a port file of its own, so machines sharing a home
    /// don't overwrite each other. Also refreshes the hook, since an older one only reads
    /// the shared port file.
    public static func pointHookScript(port: Int) -> String {
        """
        set -e
        umask 077
        host=$(hostname -s 2>/dev/null || hostname)
        host=$(printf '%s' "$host" | tr -cd 'A-Za-z0-9.-')
        tries=0
        until curl -q -gs --noproxy '*' --max-time 2 "http://127.0.0.1:\(port)/health" | grep -q 'lights ok'; do
          tries=$((tries + 1))
          [ "$tries" -lt 5 ] || exit 3
          sleep 1
        done
        mkdir -p "$HOME/.lights"
        cat > "$HOME/.lights/hook.sh.$$" <<'LIGHTS_HOOK_EOF'
        \(HookScript.contents)LIGHTS_HOOK_EOF
        chmod 700 "$HOME/.lights/hook.sh.$$"
        mv -f "$HOME/.lights/hook.sh.$$" "$HOME/.lights/hook.sh"
        echo \(port) > "$HOME/.lights/port-$host.$$"
        mv -f "$HOME/.lights/port-$host.$$" "$HOME/.lights/port-$host"
        """
    }

    public static func isUsablePort(_ port: Int) -> Bool {
        portRange.contains(port)
    }

    /// Runs on the remote machine (`sh -s`, script on stdin so the token never shows in `ps`):
    /// installs the hook script and token, and picks a random free port.
    /// Prints `port=<n>` and `claude=yes|no`.
    public static func installScript(authLine: String) -> String {
        """
        set -e
        umask 077
        mkdir -p "$HOME/.lights"
        chmod 700 "$HOME/.lights"
        cat > "$HOME/.lights/hook.sh" <<'LIGHTS_HOOK_EOF'
        \(HookScript.contents)LIGHTS_HOOK_EOF
        chmod 700 "$HOME/.lights/hook.sh"
        cat > "$HOME/.lights/auth" <<'LIGHTS_AUTH_EOF'
        \(authLine)LIGHTS_AUTH_EOF
        if [ ! -s "$HOME/.lights/port" ]; then
          # Random, so other accounts on a shared machine can't guess and take it first.
          port=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000 + 20000 ))
          while (ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null) | grep -q "[:.]$port[[:space:]]"; do
            port=$((port + 1))
          done
          echo "$port" > "$HOME/.lights/port"
        fi
        echo "port=$(cat "$HOME/.lights/port")"
        if [ -d "$HOME/.claude" ] || command -v claude >/dev/null 2>&1; then echo claude=yes; else echo claude=no; fi
        command -v curl >/dev/null 2>&1 || echo curl=no
        """
    }

    public static let uninstallScript = """
    rm -f "$HOME/.lights/hook.sh" "$HOME/.lights/port" "$HOME/.lights/port-"* "$HOME/.lights/auth"
    rmdir "$HOME/.lights" 2>/dev/null || true
    """

    /// Reads the remote ~/.claude/settings.json (empty output when missing).
    public static let readSettingsScript = #"cat "$HOME/.claude/settings.json" 2>/dev/null || true"#

    /// Backs up ~/.claude/settings.json and replaces its contents with stdin. Writes in
    /// place so a symlinked file and its permissions (it can hold API keys) are kept.
    public static let writeSettingsScript = #"""
    set -e
    umask 077
    f="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"
    tmp=$(mktemp "$HOME/.claude/.settings.lights.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    cat > "$tmp"
    [ -s "$tmp" ]
    if [ -f "$f" ]; then
      cp -p "$f" "$f.bak-lights-$(date +%Y%m%d-%H%M%S)"
      cat "$tmp" > "$f"
    else
      cp "$tmp" "$f"
    fi
    """#

    /// Parses `key=value` lines printed by `installScript`.
    public static func parseOutput(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        return values
    }
}
