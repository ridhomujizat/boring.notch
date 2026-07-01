#!/usr/bin/env bash
# codex-notch-notify.sh - map a Codex notify payload to a normalized
# AgentEvent line and append it to the file boring.notch watches.
#
# Install: copy to ~/.config/boring-notch/hooks/, chmod +x, then point Codex's
# notify command at this script. Accepts JSON as the first argument or on stdin.
# Requires: jq.
set -euo pipefail

OUT="$HOME/.config/boring-notch/events.jsonl"
mkdir -p "$(dirname "$OUT")"

payload="${1:-}"
if [[ -z "$payload" && ! -t 0 ]]; then
  payload="$(cat)"
fi

if [[ -z "$payload" ]]; then
  payload='{}'
fi

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

printf '%s\n' "$payload" | jq -c --arg host "$HOST" '
  . as $payload |
  (($payload.type // $payload.event // $payload.kind // "") | tostring | ascii_downcase) as $event |
  ($payload.cwd // $payload.working_directory // $payload.workingDirectory // env.PWD // null) as $cwd |
  (if ($event | test("approval|input|permission|notify|notification")) then "needsInput"
   elif ($event | test("error|fail")) then "error"
   elif ($event | test("done|complete|finish|stop")) then "done"
   else "working" end) as $kind |
  {
    provider: "codex",
    title: "Codex",
    host: $host,
    project: (if $cwd then ($cwd | split("/") | last) else null end),
    cwd: $cwd,
    ts: (now | floor),
    kind: $kind,
    message: (
      $payload.message
      // $payload.summary
      // $payload.title
      // $payload.last_assistant_message
      // (if $kind == "needsInput" then "needs your input"
          elif $kind == "done" then "finished"
          elif $kind == "error" then "failed"
          else "working" end)
    )
  }' >> "$OUT"
