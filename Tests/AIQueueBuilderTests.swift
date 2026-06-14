import XCTest
@testable import Riff

/// Tests for the JSON-tolerance layer in `QueueBuilder.parseSuggestions`.
///
/// The Anthropic system prompt asks for a bare JSON array, but real
/// model outputs occasionally violate it — markdown fences, leading
/// commentary, trailing commentary, partial entries. The parser is
/// the single point that has to be forgiving; once it hands back a
/// `[Suggestion]`, the rest of the flow is uniform.
///
/// We mock the LLM provider via `MockLLMProvider` rather than hitting
/// the real Anthropic API: a real-network test would be flaky, leak
/// tokens out of CI, and require a paid key.
final class AIQueueBuilderTests: XCTestCase {

    // MARK: - Happy path

    func testParsesCleanJSONArray() throws {
        let raw = """
        [
          {"title": "Skinny Love", "artist": "Bon Iver"},
          {"title": "Holocene", "artist": "Bon Iver"}
        ]
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], .init(title: "Skinny Love", artist: "Bon Iver"))
        XCTAssertEqual(result[1].title, "Holocene")
    }

    // MARK: - Tolerance: markdown fences

    func testStripsJSONFences() throws {
        let raw = """
        ```json
        [{"title": "Re: Stacks", "artist": "Bon Iver"}]
        ```
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Re: Stacks")
    }

    func testStripsBareFences() throws {
        // Fence without a language tag — chatty models love this variant.
        let raw = """
        ```
        [{"title": "Roslyn", "artist": "Bon Iver"}]
        ```
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Tolerance: surrounding commentary

    func testIgnoresLeadingCommentary() throws {
        let raw = """
        Sure! Here's a queue tailored for that vibe:

        [
          {"title": "Skinny Love", "artist": "Bon Iver"}
        ]
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 1)
    }

    func testIgnoresTrailingCommentary() throws {
        let raw = """
        [{"title": "Skinny Love", "artist": "Bon Iver"}]

        Hope this helps — let me know if you'd like more!
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 1)
    }

    func testIgnoresLeadingAndTrailingTogether() throws {
        let raw = """
        Sure thing! Here's the queue:
        ```json
        [
          {"title": "Holocene", "artist": "Bon Iver"},
          {"title": "Mykonos", "artist": "Fleet Foxes"}
        ]
        ```
        Enjoy!
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Tolerance: bracketed strings + nested arrays

    func testHandlesBracketsInsideStringFields() throws {
        // A title containing a literal `]` must not terminate parsing early.
        let raw = #"[{"title": "Square Hammer [Demo]", "artist": "Ghost"}]"#
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Square Hammer [Demo]")
    }

    // MARK: - Tolerance: malformed entries

    func testDropsEntriesMissingTitleOrArtist() throws {
        let raw = """
        [
          {"title": "Skinny Love", "artist": "Bon Iver"},
          {"title": "No Artist Here"},
          {"artist": "Orphan Artist"},
          {"title": "", "artist": "Empty Title"},
          {"title": "Holocene", "artist": "Bon Iver"}
        ]
        """
        let result = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.title), ["Skinny Love", "Holocene"])
    }

    // MARK: - Failure: no array at all

    func testThrowsWhenNoArrayPresent() {
        let raw = "I'm sorry, I can't generate that queue."
        XCTAssertThrowsError(try QueueBuilder.parseSuggestions(from: raw)) { err in
            XCTAssertEqual(err as? QueueBuilder.ParseError, .noJSONArray)
        }
    }

    func testThrowsOnUnbalancedArray() {
        let raw = "[{\"title\": \"Skinny Love\", \"artist\": \"Bon Iver\""
        XCTAssertThrowsError(try QueueBuilder.parseSuggestions(from: raw))
    }

    // MARK: - extractJSONArray primitive

    func testExtractJSONArrayPicksFirstBalancedBlock() {
        let s = "noise [\"a\", \"b\"] more [unrelated"
        XCTAssertEqual(QueueBuilder.extractJSONArray(s), "[\"a\", \"b\"]")
    }

    func testExtractJSONArrayRespectsEscapedQuotes() {
        // `\"` inside a string MUST NOT close the string and let a `]`
        // terminate the array early.
        let s = #"[{"title": "She said \"hi\"", "artist": "X"}]"#
        let extracted = QueueBuilder.extractJSONArray(s)
        XCTAssertNotNil(extracted)
        // Round-trip through JSONSerialization to confirm it's valid JSON.
        XCTAssertNotNil(extracted.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }

    // MARK: - Mock provider plumbs through end-to-end

    func testMockProviderReturnsParsedSuggestions() async throws {
        let mock = MockLLMProvider(reply: """
        ```json
        [{"title": "Skinny Love", "artist": "Bon Iver"}]
        ```
        """)
        let raw = try await mock.chat([.user("mellow folk")], model: "mock-1")
        let parsed = try QueueBuilder.parseSuggestions(from: raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].artist, "Bon Iver")
    }
}

/// In-memory `LLMProvider` used so tests don't hit the network or
/// require an API key. Lives in the test target only.
struct MockLLMProvider: LLMProvider {
    let displayName = "Mock"
    let reply: String

    func chat(_ messages: [LLMMessage], model: String) async throws -> String {
        return reply
    }
}
