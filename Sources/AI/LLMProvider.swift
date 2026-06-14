import Foundation

/// Shared LLM provider abstraction. Riff ships with one concrete
/// implementation today (`AnthropicProvider`) and the protocol exists
/// so a future provider (local llama, OpenAI, etc.) can drop in without
/// rewriting `QueueBuilderSheet`. The user supplies their own API key
/// via Settings — Riff itself never proxies LLM traffic.
protocol LLMProvider: Sendable {
    /// Human-readable label rendered next to the API key field
    /// ("Anthropic", "OpenAI", …).
    var displayName: String { get }

    /// Send a chat completion and return the assistant's reply as a
    /// plain string. `model` is the provider-specific model id
    /// (`claude-haiku-4-5-20251001`, etc.) — providers MUST NOT
    /// silently substitute another model.
    func chat(_ messages: [LLMMessage], model: String) async throws -> String
}

/// A single turn in an LLM chat. `system` messages are conventionally
/// the first entry; `AnthropicProvider` lifts them into the top-level
/// `system` field of the request body.
struct LLMMessage: Sendable, Hashable {
    enum Role: String, Sendable {
        case system, user, assistant
    }

    let role: Role
    let content: String

    static func system(_ content: String) -> LLMMessage { .init(role: .system, content: content) }
    static func user(_ content: String) -> LLMMessage { .init(role: .user, content: content) }
    static func assistant(_ content: String) -> LLMMessage { .init(role: .assistant, content: content) }
}

/// Typed errors so callers can render specific UX for each failure
/// mode (sign-in prompt for 401, throttle message for 429, generic
/// "couldn't reach the model" for everything else). The associated
/// `String` on `.network` is the safe-to-show message — provider
/// implementations MUST NOT include the API key or full response
/// body in this field.
enum LLMError: Error, LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case network(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Invalid API key. Open Settings → AI features to update it."
        case .rateLimited:  return "Rate limit hit. Wait a few seconds and try again."
        case .network(let m): return m
        case .empty:        return "The model returned an empty response."
        }
    }
}
