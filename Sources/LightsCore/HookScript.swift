import Foundation

/// The script every hook calls. Installed to ~/.lights/hook.sh on the Mac and on each SSH machine.
public enum HookScript {
    public static let relativePath = ".lights/hook.sh"

    public static func command(_ signal: String) -> String {
        "\"$HOME/\(relativePath)\" \(signal)"
    }

    /// File holding the `X-Lights-Token: <secret>` header line. Readable only by you;
    /// passing it with `-H @file` keeps the secret out of `ps`.
    public static let authRelativePath = ".lights/auth"
    public static let tokenHeader = "X-Lights-Token"

    public static let contents = #"""
    #!/bin/sh
    # Lights hook: reports this AI session's state to the Lights app.
    # Usage: hook.sh <executing|permission|idle|error|end>
    state="$1"
    dir="$HOME/.lights"
    [ -r "$dir/auth" ] || exit 0

    # tty of the nearest ancestor that has one; hooks run detached from the terminal.
    find_tty() {
      p=$$
      while [ "${p:-0}" -gt 1 ]; do
        t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
        case $t in ttys*|pts/*) echo "$t"; return ;; esac
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      done
    }

    port=9876
    [ -f "$dir/port" ] && port=$(cat "$dir/port")

    if [ "${TERM_PROGRAM:-}" = vscode ]; then
      # VS Code-style editor terminal, here or over Remote-SSH: shown while the editor is in front.
      tab="vscode$(find_tty)$(hostname -s 2>/dev/null)"
    elif [ -f "$dir/port" ]; then
      # SSH machine: the Lights app tunnels the port back to the Mac, and the
      # Mac's terminal tab comes along in LC_LIGHTS_TAB.
      tab=${LC_LIGHTS_TAB:-}
    else
      tab=$(find_tty)
    fi
    tab=$(printf '%s' "$tab" | tr -cd 'A-Za-z0-9' | cut -c1-32)
    case $state in ''|*[!a-z]*) exit 0 ;; esac

    curl -q -gs --noproxy '*' --max-time 1 -H @"$dir/auth" \
      "http://127.0.0.1:$port/state?s=$state&tab=$tab" >/dev/null 2>&1
    exit 0

    """#

    /// Line added to the user's shell startup files so `ssh` forwards the tab name
    /// (macOS ssh sends LC_* by default; most Linux servers accept it).
    public static let shellMarker = "# Lights: tells AI tools on SSH machines which terminal tab to report to"
    public static let shellSnippet = """
    \(shellMarker)
    case "$(tty 2>/dev/null)" in /dev/*) export LC_LIGHTS_TAB="$(tty | sed 's|^/dev/||')" ;; esac
    """
}
