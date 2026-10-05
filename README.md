<div align="center">

<img src="docs/icon.png" width="140" alt="Lights icon">

# Lights

**A floating traffic light for your AI coding assistant.**
**给 AI 编程助手的浮动交通灯。**

<img src="docs/demo.gif" width="100" alt="Lights demo">

[English](#english) · [中文](#中文)

*macOS 14+ · build from source*

</div>

> This is a fork of [fengyiqicoder/Lights](https://github.com/fengyiqicoder/Lights). It adds per-tab tracking, SSH machines, a token on the local server, and fixes to the Setup panel. The colors mean something different from upstream: red is "needs you", yellow is "working".

---

## English

Lights is a small macOS menu-bar app that shows a floating traffic light for the AI session in the terminal tab you're working in:

| Light | Meaning |
|---|---|
| 🔴 Red | Needs you: a permission prompt, a question, plan approval, or the turn stopped on an error (usage limit, out of credit, auth failure, server overloaded) |
| 🟡 Yellow | Working |
| 🟢 Green | Done |
| ⚫ Off | No AI session in the tab you're following |

The light follows the Terminal.app or iTerm2 tab you last clicked into. Send a prompt, minimize the window or switch to your browser, and the light keeps showing that tab. Click into another tab and it switches. With other terminals (Ghostty, VS Code, Warp) it can't tell tabs apart, so it shows the most urgent session.

### Supported tools

| Tool | Status | How |
|---|---|---|
| Claude Code | ✅ Full event hooks | `~/.claude/settings.json` |
| Codex CLI | ✅ Full event hooks | `~/.codex/hooks.json` + `features.hooks = true` in `config.toml` |
| Claude Code over SSH | ✅ | Setup panel → *SSH machines* |
| Goose | ⏳ Placeholder | — |
| OpenCode | ❌ No event hooks | — |

### Install

Requires macOS 14+ and Swift 5.9+ (Xcode Command Line Tools is enough).

```bash
git clone https://github.com/alvi75/Lights.git
cd Lights
./build-app.sh
mv Lights.app /Applications/
open /Applications/Lights.app
```

On first launch the Setup panel opens. Click **Install** next to each tool. Lights backs up the config file, then adds its hooks and leaves your own hooks alone. If you used an older Lights, the button says **Update**.

The first time the light tries to follow a tab, macOS asks whether Lights may control Terminal (or iTerm2). Click **OK**. If you said no, turn it back on under System Settings → Privacy & Security → Automation → Lights.

### SSH machines

To have Claude Code running on a server light up the tab you ssh'd from:

1. You need key-based login: `ssh <name> true` must work without a password prompt.
2. In the Setup panel, type the name you use after `ssh` (an alias from `~/.ssh/config` works) and click **Add**.
3. Open a new terminal tab, `ssh` in, and run `claude` as usual.

**Add** does three things:
- **On the server:** installs `~/.lights/hook.sh` and the Claude Code hooks, and saves a backup of `~/.claude/settings.json` first.
- **On your Mac:** adds one line to `~/.zshrc` (and to `~/.bashrc` / `~/.bash_profile` if they exist). That line exports `LC_LIGHTS_TAB` with your tab's tty name.
- **Tunnel:** keeps a background `ssh -N -R` tunnel to the server. It reconnects after sleep or network loss.

macOS `ssh` forwards `LC_*` variables by default, and most Linux servers accept them (`AcceptEnv LANG LC_*`). If a server doesn't accept them, the light still works, but it can't tell that server's sessions apart by tab.

### Usage

| Action | How |
|---|---|
| Show / hide the floating window | Menu-bar icon → *Show / Hide Window* |
| Open Setup | Menu-bar icon → *Setup Hooks…*, or right-click the floating window |
| Change size | Right-click the floating window → *Size ▸* |
| Manual override | Click a light to lock it on until the next change |
| Move the window | Drag the dark housing |
| Quit | Menu-bar icon → *Quit Lights* |

### HTTP control

The server listens on `127.0.0.1:9876`. Every route except `/health` needs the token in `~/.lights/auth`. That file is readable only by you, and Lights creates it on first launch.

```bash
curl -H @$HOME/.lights/auth localhost:9876/status                       # needs-you | working | done | off
curl -H @$HOME/.lights/auth "localhost:9876/state?s=executing&tab=ttys002" # set a tab's state
curl -H @$HOME/.lights/auth localhost:9876/permission                   # old style, no tab
curl localhost:9876/health                                                 # no token needed
```

States: `executing` (working), `permission` and `error` (needs you), `idle` (done), `end` (forget the session).

### How it works

```
  Claude Code / Codex hook ──▶ ~/.lights/hook.sh <state>
        │  finds the tab's tty (or LC_LIGHTS_TAB on a server)
        ▼
  curl 127.0.0.1:9876/state?s=<state>&tab=<tty>   (+ token header)
        │  on a server, 127.0.0.1:<port> tunnels back to the Mac
        ▼
  Lights: state per tab ──▶ tab you're following ──▶ light
```

The token stops other accounts on a shared server, and web pages in your browser, from changing your light. It is sent from a file with `curl -H @file`, so it never appears in `ps`.

### Known limitations

- Pressing Esc doesn't fire a hook, so the light stays yellow until your next prompt in that tab.
- tmux: hooks report the pane's tty, not the Terminal tab's, so tabs running tmux aren't followed.
- One Mac per server account: adding the same server from a second Mac replaces the first Mac's token there.
- The menu-bar icon doesn't show the color yet.
- On a MacBook with a notch and a full menu bar, the menu-bar icon can be hidden. Right-click the floating window for the same menu.

### Project layout

```
Sources/LightsCore/                session states, routes, hook script, JSON merge, remote setup
Sources/Lights/
  main.swift                       app delegate, content view, lights window
  StatusServer.swift               HTTP listener on 9876
  LightsModel.swift                per-tab state → what the light shows
  FocusTracker.swift               follows the focused Terminal / iTerm2 tab
  RemoteMachines.swift             SSH install + background tunnels
  RemoteSection.swift              "SSH machines" part of Setup
  MenuBarController.swift          NSStatusItem + menu
  ClaudeCodeIntegration.swift      ~/.claude/settings.json driver
  CodexIntegration.swift           ~/.codex/ driver (hooks.json + config.toml)
  SetupView.swift, SetupManager.swift
Sources/LightsSelfTest/            checks for LightsCore
tools/render-icon.swift            Core Graphics icon generator
skill/SKILL.md                     skills.sh distributable skill
build-app.sh                       build → .app bundle
```

### Development

```bash
swift build                     # everything
swift run lights-selftest       # checks (works without Xcode)
./build-app.sh                  # .app bundle (re-renders icon)
```

### License

MIT. See [LICENSE](LICENSE). Original work © its author; changes in this fork are under the same license.

---

## 中文

> 中文部分描述的是上游 v0.1 的行为。本 fork 的颜色含义不同（红 = 需要你，黄 = 运行中，绿 = 完成），并新增了按标签页跟随和 SSH 支持，详见上方英文说明。

Lights 是一个 macOS 菜单栏小工具：屏幕角落悬浮一盏交通灯，实时显示 AI 编程助手的状态。

| 灯色 | 含义 |
|---|---|
| 🔴 红 | AI 正在执行 —— 模型在生成、工具在运行 |
| 🟡 黄 | AI 等你回应 —— 权限弹窗、AskUserQuestion、ExitPlanMode |
| 🟢 绿 | 空闲 / 回复完成 |

工作机制：Lights 在 `http://127.0.0.1:9876` 监听，AI 工具的 lifecycle hook 用 `curl` 通知它。一眼看完，不需要切窗口。

### 支持的工具

| 工具 | 状态 | 配置位置 |
|---|---|---|
| Claude Code | ✅ 完整事件 hook | `~/.claude/settings.json` |
| Codex CLI | ✅ 完整事件 hook | `~/.codex/hooks.json` + `config.toml` 加 `features.hooks = true` |
| Goose | ⏳ 占位中 —— 文档调研中 | — |
| OpenCode | ❌ 没有事件 hook | — |

### 安装

需要 macOS 14+ 和 Swift 5.9+（装了 Xcode Command Line Tools 就够）。

```bash
git clone https://github.com/fengyiqicoder/Lights.git
cd Lights
./build-app.sh
open Lights.app
```

第一次启动会自动弹 Setup 面板，列出系统上检测到的所有工具。点对应工具的 **[Install]** —— Lights 会直接改对应配置文件（写之前自动备份）。

不想用 GUI 的人可以走 [skills.sh](https://skills.sh) 渠道：

```bash
npx skillsadd fengyiqicoder/lights-hooks
```

然后在 Claude Code 里说"装一下 lights hooks"。

### 用法

| 操作 | 怎么做 |
|---|---|
| 显示 / 隐藏浮窗 | 菜单栏图标 → *Show / Hide Window* |
| 打开 Setup | 菜单栏图标 → *Setup Hooks…*，或右键浮动灯窗口 |
| 切换尺寸 | 右键浮窗 → *Size ▸*（Small / Medium / Large） |
| 手动控制 | 点任意一盏灯锁定颜色，或用下面的 HTTP 接口 |
| 移动位置 | 拖住灯窗口深色背景 |
| 退出 | 菜单栏图标 → *Quit Lights* |

### HTTP 控制

```bash
curl localhost:9876/executing   # → 红
curl localhost:9876/permission  # → 黄
curl localhost:9876/idle        # → 绿
curl localhost:9876/off         # → 全灭
curl localhost:9876/status      # → 查询当前状态
curl localhost:9876/snapshot    # → 把当前窗口画面存成 PNG 到 /tmp，返回路径
```

### 工作原理

```
  Claude Code / Codex CLI
        │ (lifecycle 事件)
        ▼
  hook 命令:  curl http://127.0.0.1:9876/<state>
        │
        ▼
  Lights HTTP server  ──▶  SwiftUI 状态  ──▶  浮窗变色
```

Setup 面板会读每个工具的配置，判断 Lights 的 hook 是否已经装好，通过一个幂等的 JSON merge 引擎写入或移除 —— 保留你已有的其它所有 hook。每次写入前会在配置文件旁边留一份带时间戳的备份。

### 已知限制

- 带刘海的 MacBook Pro + 菜单栏已经塞了很多图标时，新加的 status item 可能被挤到刘海后面看不见。右键浮窗有等价的菜单 —— 功能不丢，只是图标隐藏。
- 菜单栏图标目前是中性的三点 template，还没做实时状态色镜像。

### 项目结构

```
Sources/Lights/
  main.swift                       AppDelegate / ContentView / 浮动窗口
  StatusServer.swift               9876 端口 HTTP 监听
  MenuBarController.swift          NSStatusItem + 菜单
  ToolIntegration.swift            协议 + 类型
  JSONHookMerger.swift             共享的幂等 JSON merge 引擎
  ClaudeCodeIntegration.swift      操作 ~/.claude/settings.json
  CodexIntegration.swift           操作 ~/.codex/（hooks.json + config.toml）
  PlaceholderIntegrations.swift    Goose、OpenCode 占位
  SetupView.swift                  SwiftUI 设置面板
  SetupManager.swift               可观察状态 + 首次启动标记
tools/render-icon.swift            Core Graphics 图标生成
skill/SKILL.md                     给 skills.sh 用的 skill 包
docs/superpowers/specs/            设计文档
build-app.sh                       构建 .app
```

### 开发

```bash
swift build                                     # 只编译命令行二进制
./build-app.sh                                  # 打包 .app（顺便重新渲染图标）
swift tools/render-icon.swift                   # 单独重新生成图标 PNG
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

### 许可

MIT，见 [LICENSE](LICENSE)。

---

<div align="center">

🤖 Built with [Claude Code](https://claude.com/claude-code)

</div>
