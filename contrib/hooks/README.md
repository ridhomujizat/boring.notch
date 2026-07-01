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

Codex's `notify` config invokes a program with a JSON argument.
`codex-notch-notify.sh` maps that to the **same** line with `provider:"codex"`
and appends to the same file.

1. Enable it in the app: **Settings -> HUDs -> Agent Activity -> Show
   coding-agent sneak peek**. Enable **Include live activity** too if you want
   `working` peeks.
2. Install the hook (requires [`jq`](https://jqlang.github.io/jq/)):

   ```bash
   mkdir -p ~/.config/boring-notch/hooks
   cp contrib/hooks/codex-notch-notify.sh ~/.config/boring-notch/hooks/
   chmod +x ~/.config/boring-notch/hooks/codex-notch-notify.sh
   ```

3. Point Codex's `notify` command to the installed script.

## Test without an agent

```bash
echo '{"provider":"claudeCode","kind":"needsInput","title":"Claude Code","message":"needs your approval: Bash","host":"Ghostty","project":"boring.notch","ts":0}' \
  >> ~/.config/boring-notch/events.jsonl
```

The notch should pop a peek and auto-hide.
