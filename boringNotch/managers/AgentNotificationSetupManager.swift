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
            let configURL = try updateCodexConfig(hookURL: hookURL)
            return AgentNotificationSetupResult(message: "Codex setup saved to \(displayPath(configURL)).")
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

    private static func updateCodexConfig(hookURL: URL) throws -> URL {
        let configURL = codexConfigURL
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let current = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let notifyLine = "notify = [\"\(tomlEscaped(hookURL.path))\"]"
        let updated = upsertTopLevelTomlLine(key: "notify", line: notifyLine, in: current)

        if updated != current {
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
        }

        return configURL
    }

    private static func updateClaudeSettings(hookURL: URL) throws -> URL {
        let settingsURL = claudeSettingsURL
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root = try readJSONObject(at: settingsURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        appendClaudeHook(
            to: &hooks,
            event: "Stop",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        appendClaudeHook(
            to: &hooks,
            event: "Notification",
            matcher: "",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        appendClaudeHook(
            to: &hooks,
            event: "UserPromptSubmit",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        appendClaudeHook(
            to: &hooks,
            event: "PostToolUse",
            matcher: "Edit|Write|Bash",
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        appendClaudeHook(
            to: &hooks,
            event: "SessionStart",
            matcher: nil,
            command: hookURL.path,
            scriptName: hookURL.lastPathComponent
        )
        appendClaudeHook(
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

    private static func appendClaudeHook(
        to hooks: inout [String: Any],
        event: String,
        matcher: String?,
        command: String,
        scriptName: String
    ) {
        var entries = hookEntries(from: hooks[event])
        guard !entries.contains(where: { containsCommand($0, command: command, scriptName: scriptName) }) else {
            hooks[event] = entries
            return
        }

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

    private static func upsertTopLevelTomlLine(key: String, line: String, in contents: String) -> String {
        guard !contents.isEmpty else {
            return line + "\n"
        }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstSectionIndex = lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        } ?? lines.count

        if let existingIndex = lines[..<firstSectionIndex].firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=")
        }) {
            lines[existingIndex] = line
        } else {
            lines.insert(line, at: firstSectionIndex)
            if firstSectionIndex < lines.count, lines[safe: firstSectionIndex + 1] != "" {
                lines.insert("", at: firstSectionIndex + 1)
            }
        }

        let joined = lines.joined(separator: "\n")
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

CWD="$(printf '%s' "$payload" | jq -r '.cwd // .working_directory // .workingDirectory // ""')"
[[ -z "$CWD" ]] && CWD="${PWD:-}"
STATS='{}'
if [[ -n "$CWD" ]] && git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  read -r A D F < <(git -C "$CWD" diff HEAD --numstat 2>/dev/null | awk '
    { if ($1 ~ /^[0-9]+$/) a += $1; if ($2 ~ /^[0-9]+$/) d += $2; f++ }
    END { print a+0, d+0, f+0 }')
  STATS="$(jq -c -n --argjson a "${A:-0}" --argjson d "${D:-0}" --argjson f "${F:-0}" \
    '{linesAdded:$a, linesRemoved:$d, filesChanged:$f}')"
fi

printf '%s\n' "$payload" | jq -c --arg host "$HOST" --argjson stats "$STATS" '
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
  } + $stats' >> "$OUT"
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
