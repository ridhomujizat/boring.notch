//
//  AgentEventManager.swift
//  boringNotch
//
//  Watches a whitelisted JSONL file that external coding-agent hooks
//  (Claude Code, Codex, …) append normalized AgentEvents to, and pops an
//  agent sneak peek in the notch. Provider-agnostic: the app only ever sees
//  the normalized AgentEvent; all provider quirks live in the hook scripts.
//

import Combine
import Defaults
import Foundation

final class AgentEventManager {
    static let shared = AgentEventManager()

    /// ~/.config/boring-notch/events.jsonl — must match the entitlement exception.
    /// UserHome.url resolves the *real* POSIX home (not the sandbox container),
    /// which is what the home-relative-path temp-exception grants access to.
    private let eventsURL: URL = UserHome.url
        .appendingPathComponent(".config/boring-notch/events.jsonl")

    private let queue = DispatchQueue(label: "boringnotch.agentEvents")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var retryWorkItem: DispatchWorkItem?
    private var enabledCancellable: AnyCancellable?

    private init() {
        enabledCancellable = Defaults.publisher(.enableAgentPeek)
            .sink { [weak self] change in
                if change.newValue { self?.start() } else { self?.stop() }
            }
    }

    func applyEnabledState() {
        if Defaults[.enableAgentPeek] { start() } else { stop() }
    }

    func start() {
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.retryWorkItem?.cancel()
            self?.retryWorkItem = nil
            self?.disarm()
        }
    }

    // MARK: - Watch

    private func arm() {
        guard source == nil else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil

        do {
            try ensureEventFileExists()
        } catch {
            NSLog("boring.notch agent events: failed to prepare \(eventsURL.path): \(error)")
            scheduleRetry()
            return
        }

        let watchedFD = open(eventsURL.path, O_EVTONLY)
        guard watchedFD >= 0 else {
            NSLog("boring.notch agent events: failed to open \(eventsURL.path): \(Self.posixErrorMessage())")
            scheduleRetry()
            return
        }

        fd = watchedFD

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                // Hook rotated/recreated the file — reopen.
                self.disarm()
                self.arm()
            } else {
                self.drain()
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            close(watchedFD)
            if self.fd == watchedFD {
                self.fd = -1
            }
        }
        source = src
        src.resume()

        // Drain anything already sitting in the file at startup.
        drain()
    }

    private func disarm() {
        source?.cancel()
        source = nil
    }

    private func ensureEventFileExists() throws {
        let dir = eventsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard !FileManager.default.fileExists(atPath: eventsURL.path) else { return }

        if !FileManager.default.createFile(atPath: eventsURL.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func scheduleRetry() {
        guard Defaults[.enableAgentPeek] else { return }

        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.arm()
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    // MARK: - Drain

    private func drain() {
        guard let data = try? Data(contentsOf: eventsURL), !data.isEmpty else { return }

        let showLive = Defaults[.enableAgentLiveActivity]
        let decoder = JSONDecoder()
        var latest: AgentEvent?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? decoder.decode(AgentEvent.self, from: Data(line)) else { continue }
            if event.kind == .working && !showLive { continue }
            latest = event
        }

        // On a burst only the newest line is shown; add a queue if bursts matter.
        // Truncate after reading so the file stays tiny (our own write re-fires the
        // handler, but the file is then empty so drain() returns immediately — no loop).
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }

        guard let event = latest else { return }
        DispatchQueue.main.async {
            BoringViewCoordinator.shared.showAgentPeek(event)
        }
    }

    private static func posixErrorMessage() -> String {
        String(cString: strerror(errno))
    }
}
