//
//  SessionsView.swift
//  boringNotch
//
//  Sessions tab: live list of running Claude Code and Codex agent sessions.
//

import AppKit
import SwiftUI

struct SessionsView: View {
    @ObservedObject private var sessionManager = AgentSessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SessionsHeader(count: sessionManager.sessionCount)

            if sessionManager.sessions.isEmpty {
                SessionsEmptyState()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(sessionManager.sessions) { session in
                            SessionRowView(session: session)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Header

private struct SessionsHeader: View {
    let count: Int

    var body: some View {
        HStack {
            Text("\(count) Session\(count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - Empty State

private struct SessionsEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No active sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    @ObservedObject var session: AgentSession

    @State private var isHovering = false

    var body: some View {
        Button {
            openSession()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                // Provider icon
                providerIcon
                    .frame(width: 26, height: 26)

                // Activity line + stats line
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(session.projectName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Image(systemName: activityGlyph)
                            .font(.system(size: 10))
                            .foregroundStyle(activityColor)

                        Text(activityText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(activityColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if hasStats {
                        statsLine
                    }
                }

                Spacer(minLength: 4)

                // Time + host icon
                HStack(spacing: 6) {
                    Text(session.formattedTimeSinceActivity)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    hostIcon
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Activity glyph / text / color

    /// SF Symbol representing what the session is doing, derived from the tool
    /// when known, otherwise from status.
    private var activityGlyph: String {
        switch (session.tool ?? "").lowercased() {
        case "edit", "write", "multiedit", "notebookedit", "apply_patch":
            return "doc.text"
        case "read":
            return "doc"
        case "websearch", "webfetch":
            return "globe"
        case let t where t.hasPrefix("bash") && isGitTask:
            return "arrow.triangle.branch"
        case let t where t.hasPrefix("bash"):
            return "terminal"
        default:
            break
        }
        switch session.status {
        case .working:    return "pencil"
        case .needsInput: return "exclamationmark.circle.fill"
        case .done:       return "checkmark.circle.fill"
        case .error:      return "xmark.octagon.fill"
        }
    }

    private var isGitTask: Bool {
        session.currentTask.lowercased().contains("git")
    }

    /// Prefer a verb+target phrasing; fall back to the raw message.
    private var activityText: String {
        guard let tool = session.tool?.lowercased() else { return session.currentTask }
        let target = session.target
        switch tool {
        case "edit", "multiedit", "apply_patch": return target.map { "Editing \($0)" } ?? session.currentTask
        case "write":              return target.map { "Writing \($0)" } ?? session.currentTask
        case "read":               return target.map { "Reading \($0)" } ?? session.currentTask
        case "websearch", "webfetch": return "Searching web"
        default:                   return session.currentTask
        }
    }

    private var activityColor: Color {
        switch session.status {
        case .working:    return .green
        case .needsInput: return .yellow
        case .done:       return .secondary
        case .error:      return .red
        }
    }

    // MARK: - Stats line

    private var hasStats: Bool {
        session.tokensIn != nil || session.tokensOut != nil
            || session.filesChanged != nil || session.linesAdded != nil
    }

    @ViewBuilder
    private var statsLine: some View {
        HStack(spacing: 8) {
            if session.tokensIn != nil || session.tokensOut != nil {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                    Text("\(compactNumber(session.tokensIn ?? 0)) / \(compactNumber(session.tokensOut ?? 0))")
                }
            }
            if let files = session.filesChanged {
                Label("\(files)", systemImage: "doc.on.doc")
                    .labelStyle(.compactStat)
            }
            if let turns = session.turns {
                Label("\(turns)", systemImage: "bubble.left")
                    .labelStyle(.compactStat)
            }
            if session.linesAdded != nil || session.linesRemoved != nil {
                HStack(spacing: 4) {
                    Text("+\(session.linesAdded ?? 0)")
                        .foregroundStyle(.green)
                    Text("−\(session.linesRemoved ?? 0)")
                        .foregroundStyle(.red)
                }
                .fontWeight(.semibold)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    // MARK: - Provider Icon

    @ViewBuilder
    private var providerIcon: some View {
        switch session.provider {
        case .claudeCode:
            Image("claudeUsageIcon")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5))
        case .codex:
            Image("codexUsageIcon")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5))
        case .other:
            Image(systemName: "cpu")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Host Icon

    @ViewBuilder
    private var hostIcon: some View {
        if let image = AgentHostAppResolver.image(host: session.host, bundleIdentifier: session.hostBundleId) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func openSession() {
        if let appURL = AgentHostAppResolver.applicationURL(host: session.host, bundleIdentifier: session.hostBundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
            return
        }

        // Fallback: open cwd in Terminal
        if let cwd = session.cwd {
            let url = URL(fileURLWithPath: cwd)
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Helpers

/// Compact human number: 2_100_000 -> "2.1M", 180_000 -> "180.0k".
private func compactNumber(_ value: Double) -> String {
    switch abs(value) {
    case 1_000_000...:
        return String(format: "%.1fM", value / 1_000_000)
    case 1_000...:
        return String(format: "%.1fk", value / 1_000)
    default:
        return String(Int(value))
    }
}

/// Tight icon+value pairing for the stats line.
private struct CompactStatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactStatLabelStyle {
    static var compactStat: CompactStatLabelStyle { CompactStatLabelStyle() }
}

#Preview {
    SessionsView()
        .frame(width: 640, height: 260)
        .background(.black)
}
