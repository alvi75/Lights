# lights-hooks

Claude Code skill that helps connect the [Lights](https://github.com/alvi75/Lights)
macOS traffic-light app to Claude Code.

## Install

```bash
mkdir -p ~/.claude/skills && cp -r skill ~/.claude/skills/lights-hooks
```

Then in Claude Code, ask: *"set up lights hooks"*.

## Prerequisites

- macOS with Lights.app running (`curl 127.0.0.1:9876/health` answers `lights ok`)
- Claude Code installed

## What gets installed

The app's Setup panel adds these hooks to `~/.claude/settings.json`, keeping
your own hooks. Each one runs `~/.lights/hook.sh <state>`.

| Claude Code event | State | Light |
|---|---|---|
| SessionStart, Stop | `idle` | 🟢 green |
| UserPromptSubmit, PostToolUse (any tool) | `executing` | 🟡 yellow |
| Notification (permission_prompt, elicitation_dialog) | `permission` | 🔴 red |
| PreToolUse on AskUserQuestion / ExitPlanMode | `permission` | 🔴 red |
| StopFailure (usage limit, billing, auth, server errors) | `error` | 🔴 red |
| SessionEnd | `end` | off |

A backup is saved as `settings.json.bak-lights-YYYYMMDD-HHMMSS` before any change.
