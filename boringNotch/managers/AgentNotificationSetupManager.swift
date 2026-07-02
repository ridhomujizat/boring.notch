//
//  AgentNotificationSetupManager.swift
//  boringNotch
//
//  Installs local Claude Code / Codex hooks for agent activity peeks.
//

import Foundation

enum AgentNotificationSetupTarget {
    case codex
    case claudeCode
}

struct AgentNotificationSetupResult {
    let message: String
}

enum AgentNotificationSetupManager {
    static func install(_ target: AgentNotificationSetupTarget) throws -> AgentNotificationSetupResult {
        try ensureEventsFile()

        switch target {
        case .codex:
            let hookURL = try installScript(named: "codex-notch-notify.sh", contents: codexHookScript)
            let hooksURL = try updateCodexHooks(hookURL: hookURL)
            try removeManagedCodexNotify(hookURL: hookURL)
            return AgentNotificationSetupResult(message: "Codex hooks saved to \(displayPath(hooksURL)). Review with /hooks if Codex prompts.")
        case .claudeCode:
            let hookURL = try installScript(named: "claude-notch-hook.sh", contents: claudeHookScript)
            let settingsURL = try updateClaudeSettings(hookURL: hookURL)
            return AgentNotificationSetupResult(message: "Claude Code setup saved to \(displayPath(settingsURL)).")
        }
    }

    private static var boringNotchConfigURL: URL {
        UserHome.url.appendingPathComponent(".config/boring-notch", isDirectory: true)
    }

    private static var hooksDirectoryURL: URL {
        boringNotchConfigURL.appendingPathComponent("hooks", isDirectory: true)
    }

    private static var eventsURL: URL {
        boringNotchConfigURL.appendingPathComponent("events.jsonl")
    }

    private static var codexConfigURL: URL {
        UserHome.url.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    private static var codexHooksURL: URL {
        UserHome.url.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    private static var claudeSettingsURL: URL {
        UserHome.url.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private static func ensureEventsFile() throws {
        try FileManager.default.createDirectory(at: boringNotchConfigURL, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: eventsURL.path) else { return }
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    }

    private static func installScript(named fileName: String, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: hooksDirectoryURL, withIntermediateDirectories: true)

        let scriptURL = hooksDirectoryURL.appendingPathComponent(fileName)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func updateCodexHooks(hookURL: URL) throws -> URL {
        let hooksURL = codexHooksURL
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root = try readJSONObject(at: hooksURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        upsertCommandHook(
            to: &hooks,
            event: "SessionStart",
            matcher: "startup|resume|clear|compact",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "UserPromptSubmit",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "PermissionRequest",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "PreToolUse",
            matcher: "Bash|apply_patch|Edit|Write|mcp__.*",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "PostToolUse",
            matcher: "Bash|apply_patch|Edit|Write|mcp__.*",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "PreCompact",
            matcher: "manual|auto",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "PostCompact",
            matcher: "manual|auto",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "SubagentStart",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "SubagentStop",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "Stop",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )

        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: [.atomic])
        return hooksURL
    }

    private static func removeManagedCodexNotify(hookURL: URL) throws {
        let configURL = codexConfigURL
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }

        let current = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = removeTopLevelTomlLine(
            key: "notify",
            containingAny: [hookURL.path, hookURL.lastPathComponent],
            in: current
        )

        if updated != current {
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private static func updateClaudeSettings(hookURL: URL) throws -> URL {
        let settingsURL = claudeSettingsURL
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root = try readJSONObject(at: settingsURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        upsertCommandHook(
            to: &hooks,
            event: "Stop",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "Notification",
            matcher: "",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "UserPromptSubmit",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "PostToolUse",
            matcher: "Edit|Write|Bash",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "SessionStart",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        upsertCommandHook(
            to: &hooks,
            event: "SessionEnd",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )

        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: [.atomic])
        return settingsURL
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw AgentNotificationSetupError.invalidSettings(url.lastPathComponent)
        }

        return dictionary
    }

    private static func upsertCommandHook(
        to hooks: inout [String: Any],
        event: String,
        matcher: String?,
        command: String,
        scriptName: String
    ) {
        var entries = hookEntries(from: hooks[event])
        entries.removeAll { containsCommand($0, command: command, scriptName: scriptName) }

        var entry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]
        if let matcher {
            entry["matcher"] = matcher
        }
        entries.append(entry)
        hooks[event] = entries
    }

    private static func hookEntries(from value: Any?) -> [[String: Any]] {
        if let entries = value as? [[String: Any]] {
            return entries
        }

        if let entries = value as? [Any] {
            return entries.compactMap { $0 as? [String: Any] }
        }

        return []
    }

    private static func containsCommand(_ entry: [String: Any], command: String, scriptName: String) -> Bool {
        let hookList = hookEntries(from: entry["hooks"])
        return hookList.contains { hook in
            guard let existingCommand = hook["command"] as? String else { return false }
            return existingCommand == command || existingCommand.contains(scriptName)
        }
    }

    private static func removeTopLevelTomlLine(key: String, containingAny needles: [String], in contents: String) -> String {
        guard !contents.isEmpty else { return contents }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstSectionIndex = lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        } ?? lines.count

        let indexesToRemove = lines[..<firstSectionIndex].indices.filter { index in
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let matchesKey = trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=")
            return matchesKey && needles.contains { line.contains($0) }
        }
        guard !indexesToRemove.isEmpty else { return contents }

        for index in indexesToRemove.reversed() {
            lines.remove(at: index)
        }

        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return "" }
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    private static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: UserHome.url.path, with: "~")
    }

    private static let claudeHookScript = """
#!/usr/bin/env bash
set -euo pipefail

OUT="$HOME/.config/boring-notch/events.jsonl"
mkdir -p "$(dirname "$OUT")"

INPUT="$(cat)"

HOST_BUNDLE_ID="${__CFBundleIdentifier:-}"
HOST="${TERM_PROGRAM:-unknown}"

EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')"

COUNTER_DIR="$HOME/.config/boring-notch/.tool-counters"
REFRESH_STATS=0
if [[ "$EVENT" == "Stop" || "$EVENT" == "Notification" ]]; then
  REFRESH_STATS=1
elif [[ "$EVENT" == "SessionEnd" ]]; then
  rm -f "$COUNTER_DIR/$SESSION_ID" 2>/dev/null || true
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
  --arg host "$HOST" --arg hostBundleId "$HOST_BUNDLE_ID" --arg tool "$TOOL" --argjson stats "$STATS" '
  (.hook_event_name) as $e |
  (.cwd // null) as $cwd |
  (.tool_input.file_path // .tool_input.path // "") as $fp |
  (if $fp == "" then null else ($fp | split("/") | last) end) as $target |
  {
    provider: "claudeCode",
    title: "Claude Code",
    host: $host,
    hostBundleId: (if $hostBundleId == "" then null else $hostBundleId end),
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
               elif $e == "UserPromptSubmit" then "working..."
               else $e end )
  } + $stats' >> "$OUT"
"""

    private static let codexHookScript = """
#!/usr/bin/env bash
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

HOST_BUNDLE_ID="${__CFBundleIdentifier:-}"
HOST="${TERM_PROGRAM:-unknown}"

CWD="$(printf '%s' "$payload" | jq -r '.cwd // .working_directory // .workingDirectory // ""')"
[[ -z "$CWD" ]] && CWD="${PWD:-}"
EVENT="$(printf '%s' "$payload" | jq -r '.hook_event_name // .type // .event // .kind // ""')"
TRANSCRIPT="$(printf '%s' "$payload" | jq -r '.transcript_path // ""')"
SESSION_ID="$(printf '%s' "$payload" | jq -r '.session_id // .sessionId // "unknown"')"

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
   elif ($event | test("error|fail")) then "error"
   elif ($event == "stop") or ($event == "sessionend") or ($event | test("done|complete|finish")) then "done"
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

case "$EVENT" in
  Stop|SubagentStop) printf '{}\n' ;;
esac
"""
}

enum AgentNotificationSetupError: LocalizedError {
    case invalidSettings(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSettings(fileName):
            return "\(fileName) must contain a JSON object."
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
