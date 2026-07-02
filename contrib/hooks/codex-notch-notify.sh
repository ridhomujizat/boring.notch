#!/usr/bin/env bash
# codex-notch-notify.sh - map Codex hook/notify payloads to a normalized
# AgentEvent line and append it to the file boring.notch watches.
#
# Install: copy to ~/.config/boring-notch/hooks/, chmod +x, then register it in
# Codex hooks.json. Accepts hook JSON on stdin, and legacy notify JSON as the
# first argument or on stdin. Requires: jq.
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

if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  payload="$(jq -c -n --arg message "$payload" '{type:"notification", message:$message}')"
fi

# Which terminal/editor is this session running in? __CFBundleIdentifier is
# set by macOS for any GUI-launched app, so this resolves dynamically to
# whatever app is actually running — no per-terminal list to maintain.
HOST_BUNDLE_ID="${__CFBundleIdentifier:-}"
HOST="${TERM_PROGRAM:-unknown}"

CWD="$(printf '%s' "$payload" | jq -r '.cwd // .working_directory // .workingDirectory // ""')"
[[ -z "$CWD" ]] && CWD="${PWD:-}"
EVENT="$(printf '%s' "$payload" | jq -r '.hook_event_name // .type // .event // .kind // ""')"
TRANSCRIPT="$(printf '%s' "$payload" | jq -r '.transcript_path // ""')"
SESSION_ID="$(printf '%s' "$payload" | jq -r '.session_id // .sessionId // "unknown"')"

# Heavy stats only at turn/input boundaries, or every 5th PostToolUse in
# between — tool hooks can fire frequently, but only refreshing at the
# boundary leaves the Sessions tab looking frozen during a long turn.
COUNTER_DIR="$HOME/.config/boring-notch/.tool-counters"
event_key="$(printf '%s' "$EVENT" | tr '[:upper:]' '[:lower:]')"
REFRESH_STATS=0
if [[ "$event_key" =~ stop|done|complete|finish|permission|approval|input|notify|notification ]]; then
  REFRESH_STATS=1
elif [[ "$EVENT" == "PostToolUse" ]]; then
  mkdir -p "$COUNTER_DIR"
  COUNT_FILE="$COUNTER_DIR/$SESSION_ID"
  COUNT=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$COUNT" > "$COUNT_FILE"
  if (( COUNT % 5 == 0 )); then
    REFRESH_STATS=1
  fi
fi

STATS='{}'
if [[ "$REFRESH_STATS" == "1" ]]; then
  TOK='{}'
  if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    TOK="$(jq -s '
      def usages:
        .. | objects | .usage? // empty | objects;
      {
        tokensIn: ([usages |
          (.input_tokens // .inputTokens // .prompt_tokens // .promptTokens // 0)
          + (.cache_read_input_tokens // 0)
          + (.cache_creation_input_tokens // 0)
          + (.cached_tokens // 0)
        ] | add // 0),
        tokensOut: ([usages |
          (.output_tokens // .outputTokens // .completion_tokens // .completionTokens // 0)
        ] | add // 0),
        turns: ([.. | objects |
          select((.role? == "user") or (.type? == "user") or (.message?.role? == "user"))
        ] | length)
      } | with_entries(select(.value != 0))
    ' "$TRANSCRIPT" 2>/dev/null || echo '{}')"
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

printf '%s\n' "$payload" | jq -c --arg host "$HOST" --arg hostBundleId "$HOST_BUNDLE_ID" --argjson stats "$STATS" '
  . as $payload |
  ($payload.hook_event_name // $payload.type // $payload.event // $payload.kind // "") as $eventRaw |
  ($eventRaw | tostring | ascii_downcase) as $event |
  ($payload.cwd // $payload.working_directory // $payload.workingDirectory // env.PWD // null) as $cwd |
  ($payload.tool_name // $payload.tool // null) as $tool |
  ($payload.tool_input.file_path? // $payload.tool_input.path? // $payload.tool_input.uri? // "") as $fp |
  (if $fp == "" then null else ($fp | split("/") | last) end) as $target |
  ($payload.tool_input.description? // null) as $approvalReason |
  (if $event == "sessionstart" then "start"
   elif $event == "sessionend" then "end"
   else null end) as $lifecycle |
  (if ($event == "permissionrequest") or ($event | test("approval|input|permission|notify|notification")) then "needsInput"
   elif ($event == "stop") or ($event == "sessionend") or ($event | test("done|complete|finish")) then "done"
   elif ($event | test("error|fail")) then "error"
   else "working" end) as $kind |
  def toolMessage($prefix):
    if (($tool // "") | ascii_downcase) == "apply_patch" then "Editing files"
    elif (($tool // "") | test("^mcp__")) then "Using MCP tool"
    elif (($tool // "") | ascii_downcase) == "bash" then "Running command"
    elif ($tool // "") != "" then ($prefix + " " + $tool)
    else "working" end;
  {
    provider: "codex",
    title: "Codex",
    host: $host,
    hostBundleId: (if $hostBundleId == "" then null else $hostBundleId end),
    project: (if $cwd then ($cwd | split("/") | last) else null end),
    cwd: $cwd,
    ts: (now | floor),
    tool: $tool,
    target: $target,
    sessionId: ($payload.session_id // $payload.sessionId // null),
    lifecycle: $lifecycle,
    kind: $kind,
    message: (
      $payload.message
      // $payload.summary
      // $payload.title
      // (if $event == "sessionstart" then "started"
          elif $event == "userpromptsubmit" then "working..."
          elif $event == "permissionrequest" then ("needs approval" + (if $approvalReason then ": " + $approvalReason elif $tool then ": " + $tool else "" end))
          elif $event == "pretooluse" then toolMessage("Starting")
          elif $event == "posttooluse" then toolMessage("Ran")
          elif $event == "precompact" then "compacting context"
          elif $event == "postcompact" then "compacted context"
          elif $event == "subagentstart" then "subagent started"
          elif $event == "subagentstop" then "subagent finished"
          elif $kind == "needsInput" then "needs your input"
          elif $kind == "done" then "finished"
          elif $kind == "error" then "failed"
          else ($payload.last_assistant_message // "working") end)
    )
  } + $stats' >> "$OUT"

# Stop and SubagentStop reject plain-text/empty stdout — they require a JSON
# object on exit 0. Every other event ignores stdout, so this is safe to
# print unconditionally for just these two.
case "$EVENT" in
  Stop|SubagentStop) printf '{}\n' ;;
esac
