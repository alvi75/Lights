---
name: lights-hooks
description: |
  Connect the Lights traffic-light app to Claude Code. Lights is a macOS
  menu-bar app that shows the AI session in the focused terminal tab as a
  floating traffic light (red = needs you, yellow = working, green = done).
  Use this skill when the user mentions Lights, asks how to connect Lights
  to Claude Code, says "set up lights hooks", or installed Lights and the
  light doesn't change.
---

# Connect Lights to Claude Code

Lights installs its own hooks from its Setup panel. This skill checks that
the app is running and walks the user through that panel. Do not write
hooks by hand: the server rejects requests without the token that the app
creates in `~/.lights/auth`.

## Step 1 — Check that Lights is running

```bash
curl -s --max-time 1 http://127.0.0.1:9876/health
```

The expected output is `lights ok`. If nothing answers, tell the user to open
`/Applications/Lights.app` (or build it from the repo with `./build-app.sh`),
then run this skill again. Stop here until it answers.

## Step 2 — Install from the Setup panel

Tell the user to right-click the floating light, choose **Setup Hooks…** and
click **Install** next to Claude Code (**Update** if it says older hooks).

## Step 3 — Verify

```bash
grep -c '.lights/hook.sh' ~/.claude/settings.json
test -x ~/.lights/hook.sh && test -r ~/.lights/auth && echo ready
curl -s -H @$HOME/.lights/auth http://127.0.0.1:9876/status
```

The first command should print 8, the second `ready`. The status shows the
followed tab: `working` while Claude is busy, `done` after a reply,
`needs-you` at a permission prompt.

If the status stays `off` in the tab the user is working in, check System
Settings → Privacy & Security → Automation → Lights → Terminal (or iTerm2).
Lights needs that permission to see which tab is in front.

## SSH machines

For Claude Code running on a server, the user adds the server in the Setup
panel under **SSH machines**. Key-based login must work first
(`ssh <name> true` without a prompt). They should open a new terminal tab
afterwards so the `LC_LIGHTS_TAB` line in `~/.zshrc` takes effect.

## Uninstall

Click **Uninstall** in the Setup panel. It removes only the Lights hooks
and backs up the file first.
