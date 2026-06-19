import Foundation
import os

/// Per-line lyric translation + optional romanized pronunciation
/// powered by the user's configured `LLMProvider` (B3).
///
/// Architectural notes:
///   - The translator is a `@MainActor` class so the in-memory cache,
///     the in-flight task table, and the consumed views (NowPlayingView's
///     lyrics tab) all sit on the same actor — no cross-actor hops to
///     resolve a cache hit, which is the hot path.
///   - Cache key is `(videoId, targetLanguage)`. No persistence — v1
///     keeps everything in memory; on quit, the cache resets. A cold
///     start re-asks the model, which is fine for the typical session
///     where users translate at most a handful of songs.
///   - The provider is injected, mirroring how `QueueBuilderSheet`
///     uses `AnthropicProvider()` directly today. Tests inject a mock.
///   - The output preserves input line count: missing entries fall
///     back to an empty string so the renderer can still align with the
///     original. The LLM is explicitly told to keep the order and
///     count.
@MainActor
final class LyricsTranslator {

    /// One translated line. `pronunciation` is present only when the
    /// source is non-Latin script; the LLM decides whether to emit it
    /// per-line, and the UI just renders whatever it gets.
    struct TranslatedLine: Sendable, Hashable {
        let translated: String
        let pronunciation: String?
    }

    /// Top-level result for a (videoId, language) pair.
    struct Translation: Sendable, Hashable {
        let lines: [TranslatedLine]
    }

    /// Languages we surface in the Settings picker. "Other..." is a
    /// separate free-text affordance the user can fill in for anything
    /// not in this list (the LLM will accept any reasonable language
    /// name). Order: English first for the broadest user base, then
    /// the rest grouped roughly by region for predictability.
    static let presetLanguages: [String] = [
        "English",
        "Spanish",
        "French",
        "German",
        "Japanese",
        "Korean",
        "Chinese",
        "Hindi",
        "Telugu",
    ]

    /// UserDefaults key for the user's translation target language.
    /// Defaults to "English" the first time it's read.
    static let languageKey = "lyrics.translationLanguage"
    /// UserDefaults key for whether the lyrics-translation toggle on
    /// the Now Playing lyrics tab is engaged. Persisted so the user's
    /// preference survives quit — once a user has opted in they tend
    /// to want every song translated until they explicitly opt out.
    static let enabledKey = "lyrics.translationEnabled"

    /// System prompt: instructs the model to return exactly one JSON
    /// array entry per input line, including pronunciation only when
    /// the source is non-Latin script. We pin the schema tightly so
    /// the tolerant parser can recover from the usual model-output
    /// noise (markdown fences, trailing commentary).
    static let systemPrompt: String = """
    You are translating song lyrics line by line. The user will give you a target language and a numbered list of lyric lines. \
    Translate each line into the target language. Preserve the input order and count exactly — one output object per input line, in the same order. \
    Each output is an object: {"translated": "...", "pronunciation": "..."}. \
    Include "pronunciation" ONLY when the source is non-Latin script (Japanese kanji/kana, Chinese hanzi, Korean hangul, Devanagari, Telugu, Arabic, Cyrillic, etc.); omit the field or set it to null for Latin-script sources. \
    For instrumental markers like ♪ or empty lines, return {"translated": "", "pronunciation": null}. \
    Output ONLY a JSON array. No prose, no explanation, no markdown code fences.
    """

    /// Resolve the LLM provider on each call so a key rotation in
    /// Settings takes effect without restarting Riff. Stateless apart
    /// from the cache + in-flight table.
    private let providerFactory: @MainActor () -> any LLMProvider
    private let modelProvider: @MainActor () -> String

    /// In-memory cache. Key is `"\(videoId)|\(language)"` so two
    /// distinct languages on the same track don't collide.
    private var cache: [String: Translation] = [:]

    /// Tasks already in flight for a given cache key — coalesces
    /// concurrent calls (e.g. the user toggles off + on quickly)
    /// so we never fire two requests for the same pair.
    private var inFlight: [String: Task<Translation, Error>] = [:]

    private static let log = Logger(subsystem: "dev.riff.app", category: "lyrics-translator")

    init(
        providerFactory: @escaping @MainActor () -> any LLMProvider = { AnthropicProvider() },
        modelProvider: @escaping @MainActor () -> String = { AnthropicProvider.storedModel() }
    ) {
        self.providerFactory = providerFactory
        self.modelProvider = modelProvider
    }

    private static func key(videoId: String, language: String) -> String {
        "\(videoId)|\(language.lowercased())"
    }

    /// Synchronous cache lookup. Used by the view to render an
    /// already-resolved translation without re-firing a request.
    func cached(videoId: String, language: String) -> Translation? {
        cache[Self.key(videoId: videoId, language: language)]
    }

    /// Public entry point. Returns cached translation if present;
    /// otherwise asks the LLM, caches, and returns.
    func translate(
        videoId: String,
        language: String,
        lines: [String]
    ) async throws -> Translation {
        let key = Self.key(videoId: videoId, language: language)
        if let hit = cache[key] {
            return hit
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Translation, Error> { [providerFactory, modelProvider] in
            let provider = providerFactory()
            let model = modelProvider()
            // Number the input so the model has explicit anchors to
            // keep order. We don't trust the numbering to come back —
            // we trust the array index.
            let numbered = lines.enumerated()
                .map { idx, line in "\(idx + 1). \(line.isEmpty ? "♪" : line)" }
                .joined(separator: "\n")
            let userPrompt = """
            Target language: \(language)

            Lyric lines (one per line, numbered):
            \(numbered)
            """
            let raw = try await provider.chat(
                [.system(Self.systemPrompt), .user(userPrompt)],
                model: model
            )
            let translated = try Self.parse(raw, expectedCount: lines.count)
            return Translation(lines: translated)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        cache[key] = result
        return result
    }

    /// Drop everything cached. Wired to "Clear key" in Settings so a
    /// new key doesn't inherit translations made under the old one.
    func clearCache() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Parsing

    enum ParseError: Error, Equatable {
        case noJSONArray
    }

    /// Tolerant JSON-array extraction — mirrors `QueueBuilder` but
    /// shaped for our `{translated, pronunciation}` objects. The
    /// returned array is right-sized to `expectedCount`: shorter
    /// outputs are padded with empty entries, longer outputs are
    /// truncated. This keeps the per-line renderer's index alignment
    /// stable even when the model drops or doubles up a line.
    static func parse(_ raw: String, expectedCount: Int) throws -> [TranslatedLine] {
        let stripped = stripFences(raw)
        guard let slice = extractJSONArray(stripped) else {
            throw ParseError.noJSONArray
        }
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw ParseError.noJSONArray
        }
        var out: [TranslatedLine] = []
        out.reserveCapacity(arr.count)
        for entry in arr {
            // Tolerate either an object with the expected fields or a
            // bare string (some models collapse to just the translation
            // when no pronunciation is needed). We never throw on a
            // single bad row — drop to an empty placeholder instead so
            // the index alignment with the source lines is preserved.
            if let obj = entry as? [String: Any] {
                let translated = (obj["translated"] as? String) ?? ""
                let pron: String?
                if let p = obj["pronunciation"] as? String,
                   !p.trimmingCharacters(in: .whitespaces).isEmpty {
                    pron = p
                } else {
                    pron = nil
                }
                out.append(TranslatedLine(translated: translated, pronunciation: pron))
            } else if let s = entry as? String {
                out.append(TranslatedLine(translated: s, pronunciation: nil))
            } else {
                out.append(TranslatedLine(translated: "", pronunciation: nil))
            }
        }
        // Right-size to the expected line count so the UI can index by
        // position without bounds checks.
        if out.count < expectedCount {
            out.append(contentsOf: Array(
                repeating: TranslatedLine(translated: "", pronunciation: nil),
                count: expectedCount - out.count
            ))
        } else if out.count > expectedCount {
            out = Array(out.prefix(expectedCount))
        }
        return out
    }

    /// Strip leading / trailing ``` fences (with or without a `json`
    /// language tag). Mirrors the QueueBuilder helper — duplicated
    /// rather than shared so the two AI flows can evolve their
    /// parsing independently.
    static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First balanced top-level JSON array. String-aware so brackets
    /// inside `"..."` don't fool the depth tracker.
    static func extractJSONArray(_ s: String) -> String? {
        guard let startIdx = s.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = startIdx
        while i < s.endIndex {
            let c = s[i]
            if escape {
                escape = false
            } else if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "[":  depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        return String(s[startIdx...i])
                    }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
