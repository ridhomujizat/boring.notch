//
//  AIUsageManager.swift
//  boringNotch
//
//  Reads live Claude Code and Codex CLI quota usage from the same local auth
//  stores used by their CLIs. This intentionally does not depend on Node, npm,
//  or local spend parsing.
//

import Defaults
import Darwin
import Foundation

struct UsageSnapshot: Equatable {
    var fiveHourPercent: Double = 0
    var sevenDayPercent: Double = 0
    var fiveHourResetAt: Date?
    var sevenDayRefillAt: Date?
    var detail: String?
    var updatedAt: Date?
    var lastError: String?
    var hasData: Bool = false
}

private struct ProviderThrottle {
    var lastAttemptAt: Date?
    var rateLimitedUntil: Date?
}

private struct ProviderLoadResult {
    let snapshot: UsageSnapshot
    let retryAfterSeconds: Double?

    init(snapshot: UsageSnapshot, retryAfterSeconds: Double? = nil) {
        self.snapshot = snapshot
        self.retryAfterSeconds = retryAfterSeconds
    }
}

final class AIUsageManager: ObservableObject {
    static let shared = AIUsageManager()

    @Published private(set) var claude: UsageSnapshot?
    @Published private(set) var codex: UsageSnapshot?
    @Published private(set) var isLoading = false

    private var refreshTask: Task<Void, Never>?
    private var claudeThrottle = ProviderThrottle()
    private var codexThrottle = ProviderThrottle()

    private static let rateLimitCooldown: TimeInterval = 5 * 60

    private init() {}

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        refreshIfNeeded()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }

    func refresh() {
        refresh(force: true)
    }

    private func refreshIfNeeded() {
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        guard !isLoading else { return }

        let now = Date()
        clearExpiredCooldowns(now: now)

        let previousClaude = claude
        let previousCodex = codex
        let shouldFetchClaude = shouldFetch(throttle: claudeThrottle, previous: previousClaude, now: now, force: force)
        let shouldFetchCodex = shouldFetch(throttle: codexThrottle, previous: previousCodex, now: now, force: force)

        if !shouldFetchClaude, let seconds = cooldownSeconds(throttle: claudeThrottle, now: now) {
            claude = Self.snapshot(previousClaude, withError: Self.rateLimitMessage(provider: "Claude", retryAfterSeconds: seconds))
        }
        if !shouldFetchCodex, let seconds = cooldownSeconds(throttle: codexThrottle, now: now) {
            codex = Self.snapshot(previousCodex, withError: Self.rateLimitMessage(provider: "Codex", retryAfterSeconds: seconds))
        }

        guard shouldFetchClaude || shouldFetchCodex else { return }

        isLoading = true
        if shouldFetchClaude {
            claudeThrottle.lastAttemptAt = now
        }
        if shouldFetchCodex {
            codexThrottle.lastAttemptAt = now
        }

        refreshTask?.cancel()
        refreshTask = Task(priority: .utility) { [weak self] in
            let claudeResult = shouldFetchClaude ? await Self.loadClaude(previous: previousClaude) : nil
            let codexResult = shouldFetchCodex ? await Self.loadCodex(previous: previousCodex) : nil

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let finishedAt = Date()
                if let claudeResult {
                    self.claude = claudeResult.snapshot
                    self.apply(claudeResult, to: &self.claudeThrottle, now: finishedAt)
                }
                if let codexResult {
                    self.codex = codexResult.snapshot
                    self.apply(codexResult, to: &self.codexThrottle, now: finishedAt)
                }
                self.isLoading = false
            }
        }
    }

    private func shouldFetch(throttle: ProviderThrottle, previous: UsageSnapshot?, now: Date, force: Bool) -> Bool {
        if let rateLimitedUntil = throttle.rateLimitedUntil,
           rateLimitedUntil > now {
            return false
        }
        if force {
            return true
        }

        let refreshInterval = max(60, Defaults[.usageRefreshInterval])
        if let updatedAt = previous?.updatedAt,
           previous?.hasData == true,
           now.timeIntervalSince(updatedAt) < refreshInterval {
            return false
        }
        if let lastAttemptAt = throttle.lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < refreshInterval {
            return false
        }
        return true
    }

    private func apply(_ result: ProviderLoadResult, to throttle: inout ProviderThrottle, now: Date) {
        if let retryAfterSeconds = result.retryAfterSeconds {
            throttle.rateLimitedUntil = now.addingTimeInterval(Self.rateLimitDelay(retryAfterSeconds))
        } else {
            throttle.rateLimitedUntil = nil
        }
    }

    private func clearExpiredCooldowns(now: Date) {
        if let until = claudeThrottle.rateLimitedUntil, until <= now {
            claudeThrottle.rateLimitedUntil = nil
        }
        if let until = codexThrottle.rateLimitedUntil, until <= now {
            codexThrottle.rateLimitedUntil = nil
        }
    }

    private func cooldownSeconds(throttle: ProviderThrottle, now: Date) -> Double? {
        guard let until = throttle.rateLimitedUntil,
              until > now else {
            return nil
        }
        return until.timeIntervalSince(now)
    }

    // MARK: - Claude

    private static func loadClaude(previous: UsageSnapshot?) async -> ProviderLoadResult {
        let candidates = ClaudeAuthStore.loadCredentialCandidates()
        guard !candidates.isEmpty else {
            return ProviderLoadResult(snapshot: snapshot(previous, withError: "Claude belum login. Jalankan Claude Code lalu login."))
        }

        var lastError: String?
        for candidate in candidates {
            do {
                return ProviderLoadResult(snapshot: try await fetchClaudeUsage(candidate: candidate))
            } catch LiveUsageError.unauthorized(let message) {
                guard let refreshToken = candidate.oauth.refreshToken else {
                    lastError = message
                    continue
                }

                do {
                    let refreshed = try await refreshClaudeToken(refreshToken: refreshToken)
                    try? ClaudeAuthStore.persist(refreshed, to: candidate.source)
                    return ProviderLoadResult(snapshot: try await fetchClaudeUsage(candidate: candidate.replacingOAuth(refreshed)))
                } catch {
                    lastError = error.liveUsageMessage
                    continue
                }
            } catch LiveUsageError.rateLimited(let retryAfterSeconds) {
                return ProviderLoadResult(
                    snapshot: snapshot(previous, withError: rateLimitMessage(provider: "Claude", retryAfterSeconds: retryAfterSeconds)),
                    retryAfterSeconds: retryAfterSeconds
                )
            } catch {
                lastError = error.liveUsageMessage
                continue
            }
        }

        return ProviderLoadResult(snapshot: snapshot(previous, withError: lastError ?? "Claude usage tidak tersedia."))
    }

    private static func fetchClaudeUsage(candidate: ClaudeCredentialCandidate) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(candidate.oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            return mapClaudeUsage(usage, now: Date())
        case 401, 403:
            throw LiveUsageError.unauthorized("Claude credential ditolak. Re-login Claude Code jika token tidak punya scope live usage.")
        case 429:
            throw LiveUsageError.rateLimited(retryAfterSeconds(from: response))
        default:
            throw LiveUsageError.httpStatus(response.statusCode, bodyPreview(data))
        }
    }

    private static func refreshClaudeToken(refreshToken: String) async throws -> ClaudeOAuth {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw LiveUsageError.httpStatus(response.statusCode, bodyPreview(data))
        }

        let token = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: data)
        guard !token.accessToken.isEmpty else {
            throw LiveUsageError.invalidResponse("Claude refresh response tidak berisi access token.")
        }

        let expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)).timeIntervalSince1970 * 1000 }
        return ClaudeOAuth(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: expiresAt
        )
    }

    private static func mapClaudeUsage(_ usage: ClaudeUsageResponse, now: Date) -> UsageSnapshot {
        let extraUsage = usage.extraUsage.flatMap { extra -> String? in
            guard extra.isEnabled == true else { return nil }
            let used = Int((extra.usedCredits ?? 0).rounded(.down))
            guard let monthlyLimit = extra.monthlyLimit else {
                return "Extra \(used) credits"
            }
            return "Extra \(used)/\(Int(monthlyLimit.rounded(.down))) credits"
        }

        let sonnet = usage.sevenDaySonnet?.utilization.map {
            "Sonnet \(Int($0.rounded()))%"
        }

        return UsageSnapshot(
            fiveHourPercent: fraction(fromPercent: usage.fiveHour?.utilization),
            sevenDayPercent: fraction(fromPercent: usage.sevenDay?.utilization),
            fiveHourResetAt: usage.fiveHour?.resetsAt,
            sevenDayRefillAt: usage.sevenDay?.resetsAt,
            detail: [extraUsage, sonnet].compactMap { $0 }.joined(separator: " / ").nilIfEmpty,
            updatedAt: now,
            lastError: nil,
            hasData: true
        )
    }

    // MARK: - Codex

    private static func loadCodex(previous: UsageSnapshot?) async -> ProviderLoadResult {
        let candidates = CodexAuthStore.loadAuthCandidates()
        guard !candidates.isEmpty else {
            return ProviderLoadResult(snapshot: snapshot(previous, withError: "Codex belum login. Jalankan Codex CLI lalu login."))
        }

        var lastError: String?
        for candidate in candidates {
            do {
                return ProviderLoadResult(snapshot: try await fetchCodexUsage(candidate: candidate))
            } catch LiveUsageError.unauthorized(let message) {
                guard let refreshToken = candidate.tokens.refreshToken else {
                    lastError = message
                    continue
                }

                do {
                    let refreshed = try await refreshCodexToken(refreshToken: refreshToken, accountID: candidate.tokens.accountID)
                    try? CodexAuthStore.persist(refreshed, to: candidate.source)
                    return ProviderLoadResult(snapshot: try await fetchCodexUsage(candidate: candidate.replacingTokens(refreshed)))
                } catch {
                    lastError = error.liveUsageMessage
                    continue
                }
            } catch LiveUsageError.rateLimited(let retryAfterSeconds) {
                return ProviderLoadResult(
                    snapshot: snapshot(previous, withError: rateLimitMessage(provider: "Codex", retryAfterSeconds: retryAfterSeconds)),
                    retryAfterSeconds: retryAfterSeconds
                )
            } catch {
                lastError = error.liveUsageMessage
                continue
            }
        }

        return ProviderLoadResult(snapshot: snapshot(previous, withError: lastError ?? "Codex usage tidak tersedia."))
    }

    private static func fetchCodexUsage(candidate: CodexCredentialCandidate) async throws -> UsageSnapshot {
        let usageRequest = codexRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            accessToken: candidate.tokens.accessToken,
            accountID: candidate.tokens.accountID,
            includeCodexBetaHeaders: false
        )

        let (data, response) = try await send(usageRequest)
        switch response.statusCode {
        case 200:
            let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let resetCredits = await fetchCodexResetCredits(candidate: candidate)
            return mapCodexUsage(usage, resetCredits: resetCredits, now: Date())
        case 401, 403:
            throw LiveUsageError.unauthorized("Codex credential ditolak. Jalankan Codex CLI untuk login ulang.")
        case 429:
            throw LiveUsageError.rateLimited(retryAfterSeconds(from: response))
        default:
            throw LiveUsageError.httpStatus(response.statusCode, bodyPreview(data))
        }
    }

    private static func fetchCodexResetCredits(candidate: CodexCredentialCandidate) async -> CodexResetCreditsResponse? {
        let request = codexRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            accessToken: candidate.tokens.accessToken,
            accountID: candidate.tokens.accountID,
            includeCodexBetaHeaders: true
        )

        guard let result = try? await send(request), result.1.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(CodexResetCreditsResponse.self, from: result.0)
    }

    private static func codexRequest(url: URL, accessToken: String, accountID: String?, includeCodexBetaHeaders: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        if includeCodexBetaHeaders {
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    private static func refreshCodexToken(refreshToken: String, accountID: String?) async throws -> CodexTokens {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if let error = try? JSONDecoder().decode(CodexRefreshErrorResponse.self, from: data),
               let code = error.error {
                throw LiveUsageError.invalidResponse(codexRefreshMessage(for: code))
            }
            throw LiveUsageError.httpStatus(response.statusCode, bodyPreview(data))
        }

        let token = try JSONDecoder().decode(CodexRefreshResponse.self, from: data)
        guard !token.accessToken.isEmpty else {
            throw LiveUsageError.invalidResponse("Codex refresh response tidak berisi access token.")
        }

        return CodexTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            idToken: token.idToken,
            accountID: accountID
        )
    }

    private static func mapCodexUsage(_ usage: CodexUsageResponse, resetCredits: CodexResetCreditsResponse?, now: Date) -> UsageSnapshot {
        let primary = usage.rateLimit?.primaryWindow
        let secondary = usage.rateLimit?.secondaryWindow
        let creditsDetail = codexCreditsDetail(usage.credits, resetCredits: resetCredits ?? usage.rateLimitResetCredits)

        return UsageSnapshot(
            fiveHourPercent: codexFraction(primary, now: now),
            sevenDayPercent: codexFraction(secondary, now: now),
            fiveHourResetAt: codexResetDate(primary, now: now),
            sevenDayRefillAt: codexResetDate(secondary, now: now),
            detail: [usage.planType?.uppercased(), creditsDetail].compactMap { $0 }.joined(separator: " / ").nilIfEmpty,
            updatedAt: now,
            lastError: nil,
            hasData: true
        )
    }

    private static func codexCreditsDetail(_ credits: CodexCredits?, resetCredits: CodexResetCreditsResponse?) -> String? {
        var parts: [String] = []

        if let balance = credits?.balance {
            let creditsCount = max(0, Int(balance.rounded(.down)))
            let usd = NumberFormatter.usd.string(from: NSNumber(value: Double(creditsCount) * 0.04)) ?? "$0.00"
            parts.append("\(usd) / \(creditsCount) credits")
        }

        if let availableCount = resetCredits?.availableCount {
            parts.append("\(availableCount) resets")
        }

        return parts.joined(separator: " / ").nilIfEmpty
    }

    // MARK: - Shared helpers

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LiveUsageError.invalidResponse("Respons HTTP tidak valid.")
            }
            return (data, httpResponse)
        } catch let error as LiveUsageError {
            throw error
        } catch {
            throw LiveUsageError.network(error.localizedDescription)
        }
    }

    private static func snapshot(_ previous: UsageSnapshot?, withError message: String) -> UsageSnapshot {
        guard var snapshot = previous, snapshot.hasData else {
            return UsageSnapshot(lastError: message, hasData: false)
        }
        snapshot.lastError = message
        return snapshot
    }

    private static func fraction(fromPercent percent: Double?) -> Double {
        guard let percent else { return 0 }
        return min(1, max(0, percent / 100))
    }

    private static func codexFraction(_ window: CodexUsageWindow?, now: Date) -> Double {
        guard let window else { return 0 }
        let fraction = fraction(fromPercent: window.usedPercent)

        if let usedPercent = window.usedPercent,
           usedPercent <= 1,
           let resetAfter = window.resetAfterSeconds,
           let windowSeconds = window.limitWindowSeconds,
           resetAfter >= windowSeconds - 60 {
            return 0
        }

        return fraction
    }

    private static func codexResetDate(_ window: CodexUsageWindow?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = window.resetAt {
            return UsageDateParser.date(fromEpoch: resetAt)
        }
        if let resetAfter = window.resetAfterSeconds {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
    }

    private static func rateLimitDelay(_ retryAfterSeconds: Double?) -> TimeInterval {
        max(60, retryAfterSeconds ?? rateLimitCooldown)
    }

    private static func rateLimitMessage(provider: String, retryAfterSeconds: Double?) -> String {
        guard let retryAfterSeconds else {
            return "\(provider) rate limited. Coba lagi nanti."
        }
        let minutes = max(1, Int((retryAfterSeconds / 60).rounded(.up)))
        return "\(provider) rate limited. Coba lagi sekitar \(minutes)m."
    }

    private static func bodyPreview(_ data: Data) -> String? {
        guard let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            return nil
        }
        return String(body.prefix(180))
    }

    private static func codexRefreshMessage(for code: String) -> String {
        switch code {
        case "refresh_token_expired":
            return "Sesi Codex expired. Login ulang lewat Codex CLI."
        case "refresh_token_reused":
            return "Token Codex konflik karena refresh lain. Coba refresh lagi."
        case "refresh_token_invalidated":
            return "Sesi Codex sudah di-revoke. Login ulang lewat Codex CLI."
        default:
            return "Gagal refresh token Codex: \(code)"
        }
    }
}

// MARK: - Auth stores

private enum AuthSource {
    case environment
    case file(URL)
    case keychain(KeychainItem)
}

private struct KeychainItem {
    let service: String
    let account: String?
    let data: Data
}

private struct ClaudeCredentialCandidate {
    let oauth: ClaudeOAuth
    let source: AuthSource

    func replacingOAuth(_ oauth: ClaudeOAuth) -> ClaudeCredentialCandidate {
        ClaudeCredentialCandidate(oauth: oauth, source: source)
    }
}

private struct CodexCredentialCandidate {
    let tokens: CodexTokens
    let source: AuthSource

    func replacingTokens(_ tokens: CodexTokens) -> CodexCredentialCandidate {
        CodexCredentialCandidate(tokens: tokens, source: source)
    }
}

private enum ClaudeAuthStore {
    static func loadCredentialCandidates() -> [ClaudeCredentialCandidate] {
        var candidates: [ClaudeCredentialCandidate] = []
        let env = ProcessInfo.processInfo.environment

        if let token = env["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmedNonEmpty {
            candidates.append(ClaudeCredentialCandidate(
                oauth: ClaudeOAuth(accessToken: token, refreshToken: nil, expiresAt: nil),
                source: .environment
            ))
        }

        for service in ["Claude Code-credentials", "Claude Code"] {
            for item in KeychainStore.items(service: service, currentUserFirst: true) {
                if let oauth = ClaudeOAuth(data: item.data) {
                    candidates.append(ClaudeCredentialCandidate(oauth: oauth, source: .keychain(item)))
                }
            }
        }

        for url in credentialFileURLs(environment: env) {
            guard let data = try? Data(contentsOf: url),
                  let oauth = ClaudeOAuth(data: data) else {
                continue
            }
            candidates.append(ClaudeCredentialCandidate(oauth: oauth, source: .file(url)))
        }

        return candidates
    }

    static func persist(_ oauth: ClaudeOAuth, to source: AuthSource) throws {
        switch source {
        case .environment:
            return
        case .file(let url):
            let data = try updatedClaudeCredentialData(currentData: try Data(contentsOf: url), oauth: oauth)
            try data.write(to: url, options: .atomic)
        case .keychain(let item):
            let data = try updatedClaudeCredentialData(currentData: item.data, oauth: oauth)
            try KeychainStore.update(item: item, data: data)
        }
    }

    private static func credentialFileURLs(environment: [String: String]) -> [URL] {
        if let custom = environment["CLAUDE_CONFIG_DIR"]?.trimmedNonEmpty {
            return [URL(fileURLWithPath: custom).appendingPathComponent(".credentials.json")]
        }
        return [UserHome.url.appendingPathComponent(".claude/.credentials.json")]
    }

    private static func updatedClaudeCredentialData(currentData: Data, oauth: ClaudeOAuth) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: currentData)) as? [String: Any] else {
            return Data(oauth.accessToken.utf8)
        }

        var nested = object["claudeAiOauth"] as? [String: Any] ?? object
        nested["accessToken"] = oauth.accessToken
        if let refreshToken = oauth.refreshToken {
            nested["refreshToken"] = refreshToken
        }
        if let expiresAt = oauth.expiresAt {
            nested["expiresAt"] = expiresAt
        }

        if object["claudeAiOauth"] != nil {
            object["claudeAiOauth"] = nested
        } else {
            object = nested
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

private enum CodexAuthStore {
    static func loadAuthCandidates() -> [CodexCredentialCandidate] {
        var candidates: [CodexCredentialCandidate] = []
        let env = ProcessInfo.processInfo.environment

        for item in KeychainStore.items(service: "Codex Auth") {
            if let tokens = CodexTokens(data: item.data) {
                candidates.append(CodexCredentialCandidate(tokens: tokens, source: .keychain(item)))
            }
        }

        for url in authFileURLs(environment: env) {
            guard let data = try? Data(contentsOf: url),
                  let tokens = CodexTokens(data: data) else {
                continue
            }
            candidates.append(CodexCredentialCandidate(tokens: tokens, source: .file(url)))
        }

        return candidates
    }

    static func persist(_ tokens: CodexTokens, to source: AuthSource) throws {
        switch source {
        case .environment:
            return
        case .file(let url):
            let data = try updatedCodexAuthData(currentData: try Data(contentsOf: url), tokens: tokens)
            try data.write(to: url, options: .atomic)
        case .keychain(let item):
            let data = try updatedCodexAuthData(currentData: item.data, tokens: tokens)
            try KeychainStore.update(item: item, data: data)
        }
    }

    private static func authFileURLs(environment: [String: String]) -> [URL] {
        if let custom = environment["CODEX_HOME"]?.trimmedNonEmpty {
            return [URL(fileURLWithPath: custom).appendingPathComponent("auth.json")]
        }
        return [
            UserHome.url.appendingPathComponent(".config/codex/auth.json"),
            UserHome.url.appendingPathComponent(".codex/auth.json")
        ]
    }

    private static func updatedCodexAuthData(currentData: Data, tokens: CodexTokens) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: currentData)) as? [String: Any] else {
            var direct: [String: Any] = ["access_token": tokens.accessToken]
            if let refreshToken = tokens.refreshToken { direct["refresh_token"] = refreshToken }
            if let idToken = tokens.idToken { direct["id_token"] = idToken }
            if let accountID = tokens.accountID { direct["account_id"] = accountID }
            return try JSONSerialization.data(withJSONObject: direct, options: [.prettyPrinted, .sortedKeys])
        }

        var nested = object["tokens"] as? [String: Any] ?? object
        nested["access_token"] = tokens.accessToken
        if let refreshToken = tokens.refreshToken {
            nested["refresh_token"] = refreshToken
        }
        if let idToken = tokens.idToken {
            nested["id_token"] = idToken
        }
        if let accountID = tokens.accountID {
            nested["account_id"] = accountID
        }

        if object["tokens"] != nil {
            object["tokens"] = nested
            object["last_refresh"] = UsageDateParser.isoString(from: Date())
        } else {
            object = nested
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

private enum KeychainStore {
    static func items(service: String, currentUserFirst: Bool = false) -> [KeychainItem] {
        var items: [KeychainItem] = []

        if currentUserFirst,
           let data = readPassword(service: service, account: currentUserAccount()) {
            items.append(KeychainItem(service: service, account: currentUserAccount(), data: data))
        }

        if let data = readPassword(service: service, account: nil) {
            items.append(KeychainItem(service: service, account: nil, data: data))
        }

        return items
    }

    static func update(item: KeychainItem, data: Data) throws {
        guard let value = String(data: data, encoding: .utf8) else {
            throw LiveUsageError.invalidResponse("Keychain data is not UTF-8.")
        }

        var arguments = ["add-generic-password", "-U"]
        if let account = item.account {
            arguments += ["-a", account]
        }
        arguments += ["-s", item.service, "-w", value]

        let result = runSecurity(arguments)
        guard result.exitCode == 0 else {
            throw LiveUsageError.invalidResponse("Gagal update Keychain item \(item.service).")
        }
    }

    private static func readPassword(service: String, account: String?) -> Data? {
        var arguments = ["find-generic-password"]
        if let account {
            arguments += ["-a", account]
        }
        arguments += ["-s", service, "-w"]

        let result = runSecurity(arguments)
        guard result.exitCode == 0 else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Data(value.utf8)
    }

    private static func runSecurity(_ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmedNonEmpty ?? NSUserName()
    }
}

// MARK: - Auth models

private struct ClaudeOAuth {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?

    init(accessToken: String, refreshToken: String?, expiresAt: Double?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init?(data: Data) {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
            guard let accessToken = oauth.stringValue(for: ["accessToken", "access_token"]) else {
                return nil
            }
            self.accessToken = accessToken
            self.refreshToken = oauth.stringValue(for: ["refreshToken", "refresh_token"])
            self.expiresAt = oauth.doubleValue(for: ["expiresAt", "expires_at"])
            return
        }

        guard let token = String(data: data, encoding: .utf8)?.trimmedNonEmpty else {
            return nil
        }
        self.accessToken = token
        self.refreshToken = nil
        self.expiresAt = nil
    }
}

private struct CodexTokens {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String?

    init(accessToken: String, refreshToken: String?, idToken: String?, accountID: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
    }

    init?(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let tokens = object["tokens"] as? [String: Any] ?? object
        guard let accessToken = tokens.stringValue(for: ["access_token", "accessToken"]) else {
            return nil
        }

        self.accessToken = accessToken
        self.refreshToken = tokens.stringValue(for: ["refresh_token", "refreshToken"])
        self.idToken = tokens.stringValue(for: ["id_token", "idToken"])
        self.accountID = tokens.stringValue(for: ["account_id", "accountID"])
    }
}

// MARK: - Response models

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: UsageAPIWindow?
    let sevenDay: UsageAPIWindow?
    let sevenDaySonnet: UsageAPIWindow?
    let extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

private struct ClaudeExtraUsage: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }
}

private struct UsageAPIWindow: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
        resetsAt = UsageDateParser.decodeDate(from: container, forKey: .resetsAt)
    }
}

private struct ClaudeRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexAdditionalRateLimit]?
    let credits: CodexCredits?
    let rateLimitResetCredits: CodexResetCreditsResponse?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case rateLimitResetCredits = "rate_limit_reset_credits"
        case planType = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try? container.decodeIfPresent([CodexAdditionalRateLimit].self, forKey: .additionalRateLimits)
        credits = try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        rateLimitResetCredits = CodexResetCreditsResponse.decodeIfPresent(from: container, forKey: .rateLimitResetCredits)
        planType = container.decodeLossyStringIfPresent(forKey: .planType)
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitName = container.decodeLossyStringIfPresent(forKey: .limitName)
        meteredFeature = container.decodeLossyStringIfPresent(forKey: .meteredFeature)
        rateLimit = try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
    }
}

private struct CodexUsageWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Double?
    let resetAfterSeconds: Double?
    let limitWindowSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
        case limitWindowSeconds = "limit_window_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.decodeLossyDoubleIfPresent(forKey: .usedPercent)
        resetAt = container.decodeLossyDoubleIfPresent(forKey: .resetAt)
        resetAfterSeconds = container.decodeLossyDoubleIfPresent(forKey: .resetAfterSeconds)
        limitWindowSeconds = container.decodeLossyDoubleIfPresent(forKey: .limitWindowSeconds)
    }
}

private struct CodexCredits: Decodable {
    let balance: Double?
    let hasCredits: Bool?

    enum CodingKeys: String, CodingKey {
        case balance
        case hasCredits = "has_credits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = container.decodeLossyDoubleIfPresent(forKey: .balance)
        hasCredits = container.decodeLossyBoolIfPresent(forKey: .hasCredits)
    }
}

private struct CodexResetCreditsResponse: Decodable {
    let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let count = Self.decodeCount(from: single) {
            availableCount = count
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = container.decodeLossyIntIfPresent(forKey: .availableCount)
    }

    static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> CodexResetCreditsResponse? {
        try? container.decodeIfPresent(CodexResetCreditsResponse.self, forKey: key)
    }

    private static func decodeCount(from container: SingleValueDecodingContainer) -> Int? {
        if let value = try? container.decode(Int.self) {
            return value
        }
        if let value = try? container.decode(Double.self) {
            return Int(value.rounded(.down))
        }
        if let value = try? container.decode(String.self),
           let number = Double(value) {
            return Int(number.rounded(.down))
        }
        return nil
    }
}

private struct CodexRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

private struct CodexRefreshErrorResponse: Decodable {
    let error: String?
}

// MARK: - Utilities

private enum UserHome {
    static var url: URL {
        if let home = currentPOSIXHome() {
            return URL(fileURLWithPath: home)
        }
        if let home = NSHomeDirectoryForUser(NSUserName()) {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func currentPOSIXHome() -> String? {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir else {
            return nil
        }
        let path = String(cString: home)
        return path.isEmpty ? nil : path
    }
}

private enum LiveUsageError: Error {
    case unauthorized(String)
    case rateLimited(Double?)
    case httpStatus(Int, String?)
    case network(String)
    case invalidResponse(String)

    var message: String {
        switch self {
        case .unauthorized(let message):
            return message
        case .rateLimited:
            return "Rate limited. Coba lagi nanti."
        case .httpStatus(let status, let body):
            if let body {
                return "HTTP \(status): \(body)"
            }
            return "HTTP \(status)"
        case .network(let message), .invalidResponse(let message):
            return message
        }
    }
}

private extension Error {
    var liveUsageMessage: String {
        if let error = self as? LiveUsageError {
            return error.message
        }
        return localizedDescription
    }
}

private enum UsageDateParser {
    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    static func date(from string: String) -> Date? {
        if let date = isoFormatterWithFractionalSeconds.date(from: string) {
            return date
        }
        if let date = isoFormatter.date(from: string) {
            return date
        }
        if let epoch = Double(string) {
            return date(fromEpoch: epoch)
        }
        return nil
    }

    static func date(fromEpoch epoch: Double) -> Date {
        Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
    }

    static func decodeDate<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> Date? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return date(from: string)
        }
        if let epoch = try? container.decodeIfPresent(Double.self, forKey: key) {
            return date(fromEpoch: epoch)
        }
        return nil
    }

    static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func stringValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key] as? String,
               let trimmed = value.trimmedNonEmpty {
                return trimmed
            }
        }
        return nil
    }

    func doubleValue(for keys: [String]) -> Double? {
        for key in keys {
            if let value = self[key] as? Double {
                return value
            }
            if let value = self[key] as? Int {
                return Double(value)
            }
            if let value = self[key] as? String {
                return Double(value)
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.trimmedNonEmpty
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded(.down))
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(value) {
            return Int(number.rounded(.down))
        }
        return nil
    }

    func decodeLossyBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmedNonEmpty {
            if ["true", "yes", "1"].contains(text) { return true }
            if ["false", "no", "0"].contains(text) { return false }
        }
        return nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension NumberFormatter {
    static let usd: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
