# boring.notch agent sneak peek — hooks

boring.notch can pop a **sneak peek** in the notch while a coding agent runs —
showing when it's working, needs your approval/input, or has finished — and where
it's running (Ghostty / VS Code / Terminal / …).

It works by watching `~/.config/boring-notch/events.jsonl`. Each line is a
normalized `AgentEvent`:

```json
{"provider":"claudeCode","kind":"needsInput","title":"Claude Code","message":"needs your approval: Bash","host":"Ghostty","project":"boring.notch","cwd":"/path","ts":1730000000}
```

- `kind`: `working` | `needsInput` | `done` | `error`

The app is provider-agnostic — any tool that appends this line format shows up.
Provider-specific mapping lives in these small scripts.

## Claude Code

1. Enable it in the app: **Settings → HUDs → Agent Activity → Show coding-agent
   sneak peek**. Enable **Include live activity** too if you want `working` peeks.
2. Install the hook (requires [`jq`](https://jqlang.github.io/jq/)):

   ```bash
   mkdir -p ~/.config/boring-notch/hooks
   cp contrib/hooks/claude-notch-hook.sh ~/.config/boring-notch/hooks/
   chmod +x ~/.config/boring-notch/hooks/claude-notch-hook.sh
   ```

3. Register it in `~/.claude/settings.json` (merge into any existing `hooks`):

   ```json
   {
     "hooks": {
       "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/claude-notch-hook.sh" }] }],
       "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/claude-notch-hook.sh" }] }],
       "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/claude-notch-hook.sh" }] }],
       "PostToolUse":      [{ "matcher": "Edit|Write|Bash", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/claude-notch-hook.sh" }] }]
     }
   }
   ```

   `Stop` and `Notification` are enough for the low-noise setup; the other two only
   matter when "Include live activity" is on (the app filters `working` otherwise).

## Codex

Codex hooks invoke a command with hook JSON on stdin. `codex-notch-notify.sh`
maps lifecycle events to the **same** line with `provider:"codex"` and appends
to the same file. The script also accepts the older `notify` JSON argument for
backwards compatibility, but hooks are required for full session/activity
coverage.

1. Enable it in the app: **Settings -> HUDs -> Agent Activity -> Show
   coding-agent sneak peek**. Enable **Include live activity** too if you want
   `working` peeks.
2. Install the hook (requires [`jq`](https://jqlang.github.io/jq/)):

   ```bash
   mkdir -p ~/.config/boring-notch/hooks
   cp contrib/hooks/codex-notch-notify.sh ~/.config/boring-notch/hooks/
   chmod +x ~/.config/boring-notch/hooks/codex-notch-notify.sh
   ```

3. Register it in `~/.codex/hooks.json` (merge into any existing `hooks`):

   ```json
   {
     "hooks": {
       "SessionStart":      [{ "matcher": "startup|resume|clear|compact", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "PreToolUse":        [{ "matcher": "Bash|apply_patch|Edit|Write|mcp__.*", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "PostToolUse":       [{ "matcher": "Bash|apply_patch|Edit|Write|mcp__.*", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "PreCompact":        [{ "matcher": "manual|auto", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "PostCompact":       [{ "matcher": "manual|auto", "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "SubagentStart":     [{ "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "SubagentStop":      [{ "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }],
       "Stop":              [{ "hooks": [{ "type": "command", "command": "~/.config/boring-notch/hooks/codex-notch-notify.sh" }] }]
     }
   }
   ```

   Codex may ask you to review and trust changed hooks. Run `/hooks` in Codex
   and approve the boring.notch hook if prompted.

## Test without an agent

```bash
echo '{"provider":"claudeCode","kind":"needsInput","title":"Claude Code","message":"needs your approval: Bash","host":"Ghostty","project":"boring.notch","ts":0}' \
  >> ~/.config/boring-notch/events.jsonl
```

The notch should pop a peek and auto-hide.
