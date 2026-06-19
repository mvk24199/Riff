import XCTest
@testable import Riff

/// Tests for `XRayCardsService.parse` — the JSON-tolerance layer that
/// sits between the model's raw output and the magazine-style card
/// renderer. Mirrors `LyricsTranslatorTests` in spirit; the shape is
/// different (cards with title / body / kind vs translated lines).
///
/// We exercise the parser directly rather than going through a
/// `MockLLMProvider`. The actor-isolated `XRayCardsService` is awkward
/// to drive from XCTest without committing to `@MainActor` everywhere,
/// and the parser is pure and captures the load-bearing logic.
final class XRayCardsServiceTests: XCTestCase {

    // MARK: - Happy path

    func testParsesCleanArrayWithObjects() throws {
        let raw = """
        [
          {"title": "Hometown", "body": "The song name-drops the artist's birth city.", "kind": "place"},
          {"title": "1979", "body": "Year of the original recording session.", "kind": "event"}
        ]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].title, "Hometown")
        XCTAssertEqual(cards[0].kind, .place)
        XCTAssertEqual(cards[1].kind, .event)
    }

    func testStripsMarkdownFences() throws {
        let raw = """
        ```json
        [{"title": "Trivia", "body": "Charted at #3.", "kind": "trivia"}]
        ```
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].kind, .trivia)
    }

    func testIgnoresLeadingAndTrailingProse() throws {
        // Models occasionally narrate before / after the array even
        // when told not to. The parser locates the first balanced [..]
        // and JSON-decodes that slice.
        let raw = """
        Here are the cards you asked for:
        [{"title": "Sampled break", "body": "The drums come from a 1972 record.", "kind": "sample"}]
        Let me know if you want more.
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].kind, .sample)
    }

    // MARK: - Tolerance

    func testUnknownKindFallsBackToTrivia() throws {
        // Model invents a kind value the renderer doesn't know about.
        // We fall back to .trivia rather than dropping the card so the
        // user still sees the content.
        let raw = """
        [{"title": "Mystery", "body": "Some interesting fact.", "kind": "miscellaneous"}]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].kind, .trivia)
    }

    func testMissingKindFallsBackToTrivia() throws {
        // Model forgets the `kind` field entirely. We default to trivia
        // rather than throwing — the card is still useful.
        let raw = """
        [{"title": "Anecdote", "body": "Some interesting fact."}]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].kind, .trivia)
        XCTAssertEqual(cards[0].title, "Anecdote")
    }

    func testEmptyTitleAndBodyAreDropped() throws {
        // A card with neither title nor body is renderable as a blank
        // gap — drop it instead of showing a void with just a kind tag.
        let raw = """
        [
          {"title": "", "body": "", "kind": "trivia"},
          {"title": "Real card", "body": "Real body.", "kind": "trivia"}
        ]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].title, "Real card")
    }

    func testTitleOnlyCardSurvives() throws {
        // Title-only cards are valid — the body row just hides. The
        // renderer treats both fields as optional-with-content-check.
        let raw = """
        [{"title": "Just a headline", "kind": "trivia"}]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].title, "Just a headline")
        XCTAssertEqual(cards[0].body, "")
    }

    func testNonObjectEntriesAreSkipped() throws {
        // A model might double up and include a bare string between
        // proper card objects. Skip the malformed entry, keep the
        // good ones.
        let raw = """
        ["bogus", {"title": "Good", "body": "Good body.", "kind": "people"}, 42]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].kind, .people)
    }

    func testKindIsCaseInsensitive() throws {
        // Model uppercases the kind value. We lowercase before lookup
        // so the renderer still picks the right icon.
        let raw = """
        [{"title": "Place", "body": "Body.", "kind": "PLACE"}]
        """
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards[0].kind, .place)
    }

    // MARK: - Error paths

    func testThrowsOnMissingArray() {
        let raw = "no JSON here, just prose"
        XCTAssertThrowsError(try XRayCardsService.parse(raw)) { err in
            XCTAssertEqual(err as? XRayCardsService.ParseError, .noJSONArray)
        }
    }

    func testThrowsOnUnclosedBracket() {
        let raw = "["
        XCTAssertThrowsError(try XRayCardsService.parse(raw)) { err in
            XCTAssertEqual(err as? XRayCardsService.ParseError, .noJSONArray)
        }
    }

    func testEscapedQuoteInsideStringDoesNotTerminateEarly() throws {
        // An escaped quote inside a JSON string used to be enough to
        // confuse a naive depth tracker. Verify the slice extends to
        // the real closing bracket.
        let raw = #"""
        [{"title": "He said \"hi\"", "body": "And waved.", "kind": "people"}]
        """#
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].title, "He said \"hi\"")
    }

    func testBracketsInsideStringDoNotConfuseSlicer() throws {
        // A `]` literal inside a string must not close the array early.
        let raw = #"""
        [{"title": "Brackets [literal]", "body": "Test.", "kind": "trivia"}]
        """#
        let cards = try XRayCardsService.parse(raw)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].title, "Brackets [literal]")
    }
}
