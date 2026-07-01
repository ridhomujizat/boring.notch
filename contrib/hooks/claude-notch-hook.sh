#!/usr/bin/env bash
# claude-notch-hook.sh — map a Claude Code hook event (JSON on stdin) to a
# normalized AgentEvent line and append it to the file boring.notch watches.
#
# Install: copy to ~/.config/boring-notch/hooks/, chmod +x, and register it in
# ~/.claude/settings.json (see README.md). Requires: jq.
set -euo pipefail

OUT="$HOME/.config/boring-notch/events.jsonl"
mkdir -p "$(dirname "$OUT")"

# Which terminal/editor is this session running in?
case "${TERM_PROGRAM:-}" in
  ghostty)        HOST=Ghostty ;;
  vscode)         HOST="VS Code" ;;
  iTerm.app)      HOST=iTerm ;;
  Apple_Terminal) HOST=Terminal ;;
  WezTerm)        HOST=WezTerm ;;
  tmux|"")        case "${__CFBundleIdentifier:-}" in
                    com.mitchellh.ghostty) HOST=Ghostty ;;
                    com.microsoft.VSCode)  HOST="VS Code" ;;
                    com.apple.Terminal)    HOST=Terminal ;;
                    *) HOST="${TERM_PROGRAM:-unknown}" ;;
                  esac ;;
  *)              HOST="${TERM_PROGRAM}" ;;
esac

jq -c --arg host "$HOST" '
  (.hook_event_name) as $e |
  (.cwd // null) as $cwd |
  {
    provider: "claudeCode",
    title: "Claude Code",
    host: $host,
    project: (if $cwd then ($cwd | split("/") | last) else null end),
    cwd: $cwd,
    ts: (now | floor),
    kind: ( if $e == "Stop" then "done"
            elif $e == "Notification" then "needsInput"
            elif $e == "UserPromptSubmit" or $e == "PostToolUse" then "working"
            else "working" end ),
    message: ( if $e == "Notification" then (.message // "needs your input")
               elif $e == "Stop" then "finished"
               elif $e == "PostToolUse" then ("ran " + (.tool_name // "a tool"))
               elif $e == "UserPromptSubmit" then "working…"
               else $e end )
  }' >> "$OUT"
