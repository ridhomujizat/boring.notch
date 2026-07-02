#!/usr/bin/env bash
# claude-notch-hook.sh — map a Claude Code hook event (JSON on stdin) to a
# normalized AgentEvent line and append it to the file boring.notch watches.
#
# Install: copy to ~/.config/boring-notch/hooks/, chmod +x, and register it in
# ~/.claude/settings.json (see README.md). Requires: jq, git (optional).
set -euo pipefail

OUT="$HOME/.config/boring-notch/events.jsonl"
mkdir -p "$(dirname "$OUT")"

INPUT="$(cat)"

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

EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')"

# Heavy stats only at turn boundaries (Stop / Notification) — parsing the
# transcript and shelling out to git on every PostToolUse would be too costly.
STATS='{}'
if [[ "$EVENT" == "Stop" || "$EVENT" == "Notification" ]]; then
  TOK='{}'
  if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    TOK="$(jq -s '{
      tokensIn:  ([.[] | .message?.usage? | select(. != null)
                   | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)] | add // 0),
      tokensOut: ([.[] | .message?.usage?.output_tokens? | select(. != null)] | add // 0),
      turns:     ([.[] | select(.type == "user")] | length)
    }' "$TRANSCRIPT" 2>/dev/null || echo '{}')"
  fi

  DIFF='{}'
  if [[ -n "$CWD" ]] && git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    read -r A D F < <(git -C "$CWD" diff HEAD --numstat 2>/dev/null | awk '
      { if ($1 ~ /^[0-9]+$/) a += $1; if ($2 ~ /^[0-9]+$/) d += $2; f++ }
      END { print a+0, d+0, f+0 }')
    DIFF="$(jq -c -n --argjson a "${A:-0}" --argjson d "${D:-0}" --argjson f "${F:-0}" \
      '{linesAdded:$a, linesRemoved:$d, filesChanged:$f}')"
  fi

  STATS="$(jq -c -n --argjson t "$TOK" --argjson d "$DIFF" '$t + $d')"
fi

printf '%s' "$INPUT" | jq -c \
  --arg host "$HOST" --arg tool "$TOOL" --argjson stats "$STATS" '
  (.hook_event_name) as $e |
  (.cwd // null) as $cwd |
  (.tool_input.file_path // .tool_input.path // "") as $fp |
  (if $fp == "" then null else ($fp | split("/") | last) end) as $target |
  {
    provider: "claudeCode",
    title: "Claude Code",
    host: $host,
    project: (if $cwd then ($cwd | split("/") | last) else null end),
    cwd: $cwd,
    ts: (now | floor),
    tool: (if $tool == "" then null else $tool end),
    target: $target,
    sessionId: (.session_id // null),
    lifecycle: ( if $e == "SessionStart" then "start"
                 elif $e == "SessionEnd" then "end"
                 else null end ),
    kind: ( if $e == "Stop" then "done"
            elif $e == "Notification" then "needsInput"
            elif $e == "SessionEnd" then "done"
            else "working" end ),
    message: ( if $e == "Notification" then (.message // "needs your input")
               elif $e == "Stop" then "finished"
               elif $e == "SessionStart" then "started"
               elif $e == "SessionEnd" then "ended"
               elif $e == "PostToolUse" then (
                 if $tool == "Edit" or $tool == "MultiEdit" then ("Editing " + ($target // "a file"))
                 elif $tool == "Write" then ("Writing " + ($target // "a file"))
                 elif $tool == "Bash" then "Running command"
                 elif $tool == "WebSearch" or $tool == "WebFetch" then "Searching web"
                 else ("ran " + (if $tool == "" then "a tool" else $tool end)) end)
               elif $e == "UserPromptSubmit" then "working…"
               else $e end )
  } + $stats' >> "$OUT"
