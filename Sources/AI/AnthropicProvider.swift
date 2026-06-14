import Foundation
import os

/// Anthropic Messages API client. Reads the user's API key from
/// Keychain (item account `riff.llm.anthropic`, service `riff` — the
/// existing `Keychain` enum's per-app service is `dev.riff.app`; we
/// keep the account-side namespace `riff.llm.anthropic` distinct so
/// nothing collides with OAuth storage). The key is **never** logged
/// or surfaced in error messages.
///
/// Zero new dependencies — just `URLSession`. Strict-concurrency
/// friendly: the provider has no mutable state, is `Sendable`, and
/// every network call goes through the actor-agnostic async URLSession
/// API.
struct AnthropicProvider: LLMProvider {
    /// Keychain account used to store the user's API key. Distinct
    /// from `keychainModelAccount` so the user can rotate one without
    /// touching the other.
    static let keychainKeyAccount = "riff.llm.anthropic"
    /// Keychain account used to store the user-selected model id.
    /// Stored alongside the key for parallelism — it's not a secret,
    /// but co-locating means "AI features off" = "delete both" with
    /// no UserDefaults straggler.
    static let keychainModelAccount = "riff.llm.anthropic.model"

    /// Default model — picked for speed + cost on the queue-builder
    /// workload (a short JSON list, no reasoning). Sonnet is offered
    /// as an opt-in upgrade in Settings.
    static let defaultModel = "claude-haiku-4-5-20251001"

    /// Models surfaced in the Settings picker. New ids should be
    /// appended here, not silently swapped for an old id, so users
    /// who picked a specific model don't get migrated unexpectedly.
    static let availableModels: [String] = [
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-6",
    ]

    /// API version header — required by Anthropic. Bumped only when
    /// we adopt a new version intentionally.
    static let apiVersion = "2023-06-01"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let log = Logger(subsystem: "dev.riff.app", category: "llm")

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var displayName: String { "Anthropic" }

    // MARK: - Keychain helpers

    /// Read the stored API key. Returns nil when AI features haven't
    /// been configured — callers should surface "open Settings" UX
    /// rather than throwing.
    static func storedAPIKey() -> String? {
        Keychain.get(keychainKeyAccount)
    }

    /// Read the stored model id, falling back to the default. We
    /// never throw here; an unknown stored id (e.g. one we removed
    /// from `availableModels`) just falls back so the UI stays in a
    /// sane state.
    static func storedModel() -> String {
        let stored = Keychain.get(keychainModelAccount) ?? defaultModel
        return availableModels.contains(stored) ? stored : defaultModel
    }

    static func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(keychainKeyAccount)
            return
        }
        try Keychain.set(trimmed, for: keychainKeyAccount)
    }

    static func setModel(_ id: String) {
        // Best-effort; a Keychain miss isn't fatal (the default fills in).
        try? Keychain.set(id, for: keychainModelAccount)
    }

    static func clearAPIKey() {
        Keychain.delete(keychainKeyAccount)
        Keychain.delete(keychainModelAccount)
    }

    // MARK: - Chat

    func chat(_ messages: [LLMMessage], model: String) async throws -> String {
        guard let apiKey = Self.storedAPIKey(), !apiKey.isEmpty else {
            throw LLMError.unauthorized
        }

        // Anthropic puts the system prompt in a top-level `system`
        // field, not inline. Concatenate any leading system messages
        // and strip them from the messages array — having a `system`
        // role inside `messages` is a 400.
        let systemPrompt = messages
            .filter { $0.role == .system }
            .map { $0.content }
            .joined(separator: "\n\n")
        let chatMessages = messages.filter { $0.role != .system }.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": chatMessages,
        ]
        if !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Note: `error.localizedDescription` from URLSession
            // doesn't contain the API key (it's not part of the
            // request URL), so this is safe to surface.
            Self.log.error("anthropic transport error: \(error.localizedDescription, privacy: .public)")
            throw LLMError.network("Couldn't reach the model: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("Unexpected response type")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            Self.log.error("anthropic 401/403 — key rejected")
            throw LLMError.unauthorized
        case 429:
            Self.log.error("anthropic 429 — rate limited")
            throw LLMError.rateLimited
        default:
            // Surface the provider's error type (not the full body — it
            // can echo back the request, and even though we don't put the
            // key in the body, we keep the surface minimal).
            let safeType = Self.errorType(from: data) ?? "http_\(http.statusCode)"
            Self.log.error("anthropic http \(http.statusCode) type=\(safeType, privacy: .public)")
            throw LLMError.network("Model error (\(safeType))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String,
              !text.isEmpty
        else {
            throw LLMError.empty
        }
        return text
    }

    /// Extract Anthropic's `error.type` from a non-2xx body so we can
    /// log + surface something more useful than just the status code.
    /// Never returns the message body verbatim — only the typed slug
    /// (`invalid_request_error`, `overloaded_error`, …).
    private static func errorType(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let type = err["type"] as? String else {
            return nil
        }
        return type
    }
}
