//
//  AgentSessionManager.swift
//  boringNotch
//
//  Tracks active coding-agent sessions (Claude Code, Codex) derived from
//  AgentEvents. Each session is keyed by provider + project name and
//  auto-expires after the agent finishes or errors.
//

import Combine
import Foundation

/// Represents a single active agent session.
final class AgentSession: ObservableObject, Identifiable {
    let id: String
    let provider: AgentProvider
    let projectName: String
    @Published var currentTask: String
    @Published var status: AgentEventKind
    var host: String?
    var hostBundleId: String?
    var cwd: String?
    @Published var lastActivityTime: Date
    /// Set once we've reminded the user this finished session is idle-waiting.
    var idleReminderSent = false

    // Activity + stats (latest known values; sticky — a lightweight event
    // without stats does not clear numbers a prior Stop event reported).
    @Published var tool: String?
    @Published var target: String?
    @Published var tokensIn: Double?
    @Published var tokensOut: Double?
    @Published var filesChanged: Int?
    @Published var linesAdded: Int?
    @Published var linesRemoved: Int?
    @Published var turns: Int?

    init(event: AgentEvent) {
        let project = event.project ?? "Unknown"
        self.id = Self.sessionKey(for: event)
        self.provider = event.provider
        self.projectName = project
        self.currentTask = event.message
        self.status = event.kind
        self.host = event.host
        self.hostBundleId = event.hostBundleId
        self.cwd = event.cwd
        self.lastActivityTime = event.ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.tool = event.tool
        self.target = event.target
        self.tokensIn = event.tokensIn
        self.tokensOut = event.tokensOut
        self.filesChanged = event.filesChanged
        self.linesAdded = event.linesAdded
        self.linesRemoved = event.linesRemoved
        self.turns = event.turns
    }

    func update(with event: AgentEvent) {
        currentTask = event.message
        status = event.kind
        if let h = event.host { host = h }
        if let bundleId = event.hostBundleId { hostBundleId = bundleId }
        if let c = event.cwd { cwd = c }
        lastActivityTime = event.ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        idleReminderSent = false
        // Sticky: only overwrite when the event actually carries the value.
        tool = event.tool ?? tool
        target = event.target ?? target
        if let v = event.tokensIn { tokensIn = v }
        if let v = event.tokensOut { tokensOut = v }
        if let v = event.filesChanged { filesChanged = v }
        if let v = event.linesAdded { linesAdded = v }
        if let v = event.linesRemoved { linesRemoved = v }
        if let v = event.turns { turns = v }
    }

    /// Formatted time since last activity (e.g. "2m", "15m", "1h").
    var formattedTimeSinceActivity: String {
        let seconds = Int(Date().timeIntervalSince(lastActivityTime))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }

    /// Prefer the agent-provided session id (distinguishes concurrent sessions
    /// in one project); fall back to provider+project when absent (e.g. Codex).
    static func sessionKey(for event: AgentEvent) -> String {
        if let sid = event.sessionId, !sid.isEmpty { return sid }
        let providerTag: String
        switch event.provider {
        case .claudeCode: providerTag = "claude"
        case .codex: providerTag = "codex"
        case .other(let name): providerTag = name
        }
        return "\(providerTag):\(event.project ?? "Unknown")"
    }
}

/// Singleton that maintains the list of active agent sessions.
@MainActor
final class AgentSessionManager: ObservableObject {
    static let shared = AgentSessionManager()

    @Published private(set) var sessions: [AgentSession] = []

    /// How long finished/errored sessions linger before removal (seconds).
    private let expirationInterval: TimeInterval = 300 // 5 minutes

    /// How long a silent working/needs-input session lingers before we assume
    /// the agent died without a SessionEnd (killed terminal, crash). A live
    /// session that fires any event after removal simply reappears.
    private let staleSessionInterval: TimeInterval = 2 * 60 * 60 // 2 hours

    /// How long a finished session sits idle before we remind the user it's
    /// waiting for input. ponytail: fixed threshold, make it a Defaults key if
    /// users want to tune it.
    private let idleReminderInterval: TimeInterval = 120 // 2 minutes

    private var cleanupTimer: Timer?

    private init() {
        startCleanupTimer()
    }

    // MARK: - Public

    var activeSessions: [AgentSession] {
        sessions.filter { $0.status == .working || $0.status == .needsInput }
    }

    var sessionCount: Int { sessions.count }

    /// Upsert a session from an incoming agent event.
    func handleEvent(_ event: AgentEvent) {
        let key = AgentSession.sessionKey(for: event)

        // SessionEnd removes the session from the list immediately.
        if event.lifecycle == "end" {
            sessions.removeAll { $0.id == key }
            return
        }

        if let existing = sessions.first(where: { $0.id == key }) {
            existing.update(with: event)
            // Trigger objectWillChange so SwiftUI picks up nested changes.
            objectWillChange.send()
        } else {
            let session = AgentSession(event: event)
            sessions.append(session)
        }
    }

    // MARK: - Cleanup

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.remindIdleSessions()
                self?.removeExpiredSessions()
            }
        }
    }

    /// A finished session sitting idle a while just means it's done and you
    /// haven't come back yet. Peek a gentle reminder once — kept as `.done`
    /// (not `.needsInput`) so it never masquerades as a real "Claude needs
    /// input" signal, which is a separate hook event.
    private func remindIdleSessions() {
        let now = Date()
        for session in sessions where session.status == .done && !session.idleReminderSent {
            guard now.timeIntervalSince(session.lastActivityTime) > idleReminderInterval else { continue }
            session.idleReminderSent = true
            let event = AgentEvent(
                provider: session.provider,
                kind: .done,
                title: session.projectName,
                message: "finished — waiting for you",
                host: session.host,
                hostBundleId: session.hostBundleId,
                project: session.projectName,
                cwd: session.cwd
            )
            BoringViewCoordinator.shared.showAgentPeek(event)
        }
    }

    private func removeExpiredSessions() {
        let now = Date()
        sessions.removeAll { session in
            let idle = now.timeIntervalSince(session.lastActivityTime)
            switch session.status {
            case .done, .error:
                return idle > expirationInterval
            case .working, .needsInput:
                // ponytail: no SessionEnd arrives when the terminal is killed,
                // so reap silent sessions after 2h instead of keeping them forever.
                return idle > staleSessionInterval
            }
        }
    }
}
