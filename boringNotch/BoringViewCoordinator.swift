//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

// MARK: - Agent activity (Claude Code / Codex, provider-agnostic)

enum AgentProvider: Codable, Equatable {
    case claudeCode
    case codex
    case other(String)

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue.normalizedAgentToken {
        case "claudecode", "claude":
            self = .claudeCode
        case "codex":
            self = .codex
        default:
            self = .other(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .claudeCode:
            try container.encode("claudeCode")
        case .codex:
            try container.encode("codex")
        case let .other(rawValue):
            try container.encode(rawValue)
        }
    }
}

enum AgentEventKind: Codable, Equatable {
    case working
    case needsInput
    case done
    case error

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue.normalizedAgentToken {
        case "needsinput", "needinput", "input", "approval", "needsapproval", "notification":
            self = .needsInput
        case "done", "finished", "finish", "completed", "complete", "stop", "success":
            self = .done
        case "error", "failed", "failure":
            self = .error
        default:
            self = .working
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .working:
            try container.encode("working")
        case .needsInput:
            try container.encode("needsInput")
        case .done:
            try container.encode("done")
        case .error:
            try container.encode("error")
        }
    }
}

struct AgentEvent: Codable {
    var provider: AgentProvider
    var kind: AgentEventKind
    var title: String
    var message: String
    var host: String?      // "Ghostty", "VS Code", "Terminal", …
    var project: String?   // basename(cwd)
    var cwd: String?
    var ts: Double?
    // Activity + session stats — all optional; lightweight events omit them.
    var tool: String?      // "Edit", "Write", "Bash", "WebSearch", …
    var target: String?    // basename of edited file / search query
    var tokensIn: Double?
    var tokensOut: Double?
    var filesChanged: Int?
    var linesAdded: Int?
    var linesRemoved: Int?
    var turns: Int?
    var sessionId: String?   // agent-provided session id (Claude Code)
    var lifecycle: String?   // "start" / "end" — drives add/remove in the list

    private enum CodingKeys: String, CodingKey {
        case provider
        case kind
        case title
        case message
        case host
        case project
        case cwd
        case ts
        case tool
        case target
        case tokensIn
        case tokensOut
        case filesChanged
        case linesAdded
        case linesRemoved
        case turns
        case sessionId
        case lifecycle
    }

    init(
        provider: AgentProvider,
        kind: AgentEventKind,
        title: String,
        message: String,
        host: String? = nil,
        project: String? = nil,
        cwd: String? = nil,
        ts: Double? = nil,
        tool: String? = nil,
        target: String? = nil,
        tokensIn: Double? = nil,
        tokensOut: Double? = nil,
        filesChanged: Int? = nil,
        linesAdded: Int? = nil,
        linesRemoved: Int? = nil,
        turns: Int? = nil,
        sessionId: String? = nil,
        lifecycle: String? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.title = title
        self.message = message
        self.host = host
        self.project = project
        self.cwd = cwd
        self.ts = ts
        self.tool = tool
        self.target = target
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.filesChanged = filesChanged
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.turns = turns
        self.sessionId = sessionId
        self.lifecycle = lifecycle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        provider = (try? container.decode(AgentProvider.self, forKey: .provider)) ?? .other("agent")
        kind = (try? container.decode(AgentEventKind.self, forKey: .kind)) ?? .working
        title = (try? container.decode(String.self, forKey: .title)) ?? provider.defaultTitle
        message = (try? container.decode(String.self, forKey: .message)) ?? kind.defaultMessage
        host = try? container.decode(String.self, forKey: .host)
        project = try? container.decode(String.self, forKey: .project)
        cwd = try? container.decode(String.self, forKey: .cwd)
        ts = try? container.decode(Double.self, forKey: .ts)
        tool = try? container.decode(String.self, forKey: .tool)
        target = try? container.decode(String.self, forKey: .target)
        tokensIn = try? container.decode(Double.self, forKey: .tokensIn)
        tokensOut = try? container.decode(Double.self, forKey: .tokensOut)
        filesChanged = try? container.decode(Int.self, forKey: .filesChanged)
        linesAdded = try? container.decode(Int.self, forKey: .linesAdded)
        linesRemoved = try? container.decode(Int.self, forKey: .linesRemoved)
        turns = try? container.decode(Int.self, forKey: .turns)
        sessionId = try? container.decode(String.self, forKey: .sessionId)
        lifecycle = try? container.decode(String.self, forKey: .lifecycle)
    }
}

struct AgentPeek {
    var show: Bool = false
    var event: AgentEvent? = nil
}

extension AgentEvent {
    /// SF Symbol for the current activity, derived from `tool` when known,
    /// else nil so callers can fall back to a status icon.
    var activityGlyph: String? {
        switch (tool ?? "").lowercased() {
        case "edit", "write", "multiedit", "notebookedit":
            return "doc.text"
        case "read":
            return "doc"
        case "websearch", "webfetch":
            return "globe"
        case let t where t.hasPrefix("bash") && message.lowercased().contains("git"):
            return "arrow.triangle.branch"
        case let t where t.hasPrefix("bash"):
            return "terminal"
        default:
            return nil
        }
    }
}

private extension String {
    var normalizedAgentToken: String {
        lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension AgentProvider {
    var defaultTitle: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case let .other(rawValue):
            return rawValue.isEmpty ? "Agent" : rawValue
        }
    }
}

private extension AgentEventKind {
    var defaultMessage: String {
        switch self {
        case .working:
            return "working"
        case .needsInput:
            return "needs your input"
        case .done:
            return "finished"
        case .error:
            return "failed"
        }
    }
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    // MARK: - Agent peek (same auto-hide pattern as sneakPeek, longer to read text)

    private var agentPeekTask: Task<Void, Never>?

    @Published var agentPeek: AgentPeek = .init() {
        didSet {
            agentPeekTask?.cancel()
            guard agentPeek.show else { return }
            // needsInput lingers longer since it asks the user to act.
            let duration: TimeInterval = agentPeek.event?.kind == .needsInput ? 6 : 4
            agentPeekTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation { self.agentPeek.show = false }
                }
            }
        }
    }

    func showAgentPeek(_ event: AgentEvent) {
        withAnimation(.smooth) {
            agentPeek = AgentPeek(show: true, event: event)
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}
