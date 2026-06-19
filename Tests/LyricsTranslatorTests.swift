import XCTest
@testable import Riff

/// Tests for `LyricsTranslator.parse` — the JSON-tolerance + right-sizing
/// layer that sits between the model's raw output and the per-line
/// renderer. Mirrors the QueueBuilder parser tests in spirit; the
/// shape is different (objects with `translated` + optional
/// `pronunciation` vs `title` + `artist`).
///
/// We exercise the parser directly rather than going through a
/// `MockLLMProvider` because the actor-isolated `LyricsTranslator`
/// MainActor-hops are awkward to drive from XCTest without committing
/// to `@MainActor` test methods everywhere; the parser is pure and
/// captures the load-bearing logic.
final class LyricsTranslatorTests: XCTestCase {

    // MARK: - Happy path

    func testParsesCleanArrayWithObjects() throws {
        let raw = """
        [
          {"translated": "Hello world", "pronunciation": null},
          {"translated": "Goodnight", "pronunciation": "ohayou"}
        ]
        """
        let lines = try LyricsTranslator.parse(raw, expectedCount: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].translated, "Hello world")
        XCTAssertNil(lines[0].pronunciation)
        XCTAssertEqual(lines[1].pronunciation, "ohayou")
    }

    func testStripsMarkdownFences() throws {
        let raw = """
        ```json
        [{"translated": "Bonjour", "pronunciation": null}]
        ```
        """
        let lines = try LyricsTranslator.parse(raw, expectedCount: 1)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].translated, "Bonjour")
    }

    func testIgnoresLeadingAndTrailingProse() throws {
        // Models occasionally narrate before / after the array even
        // when told not to. The parser locates the first balanced [..]
        // and JSON-decodes that slice.
        let raw = """
        Here's the translation you asked for:
        [{"translated": "Hola"}]
        Let me know if you want a different style.
        """
        let lines = try LyricsTranslator.parse(raw, expectedCount: 1)
        XCTAssertEqual(lines[0].translated, "Hola")
        XCTAssertNil(lines[0].pronunciation)
    }

    // MARK: - Right-sizing

    func testShorterOutputPadsToExpectedCount() throws {
        let raw = #"[{"translated":"A"},{"translated":"B"}]"#
        let lines = try LyricsTranslator.parse(raw, expectedCount: 4)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].translated, "A")
        XCTAssertEqual(lines[1].translated, "B")
        XCTAssertEqual(lines[2].translated, "")  // padded
        XCTAssertEqual(lines[3].translated, "")  // padded
    }

    func testLongerOutputTruncates() throws {
        let raw = #"[{"translated":"A"},{"translated":"B"},{"translated":"C"}]"#
        let lines = try LyricsTranslator.parse(raw, expectedCount: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last?.translated, "B")
    }

    // MARK: - Tolerance

    func testTolerantOfBareStringEntries() throws {
        // Some models collapse `{translated: "X"}` to just `"X"` when
        // no pronunciation is needed. We accept both shapes.
        let raw = #"["Hola", {"translated":"Adiós"}]"#
        let lines = try LyricsTranslator.parse(raw, expectedCount: 2)
        XCTAssertEqual(lines[0].translated, "Hola")
        XCTAssertNil(lines[0].pronunciation)
        XCTAssertEqual(lines[1].translated, "Adiós")
    }

    func testEmptyPronunciationStringTreatedAsNil() throws {
        // `""` for pronunciation must not render an empty row in the
        // UI — collapse it to nil at the parser layer so the view
        // can use `if let pron` and not need a separate emptiness check.
        let raw = #"[{"translated":"Hi","pronunciation":""}]"#
        let lines = try LyricsTranslator.parse(raw, expectedCount: 1)
        XCTAssertNil(lines[0].pronunciation)
    }

    func testDropsNonObjectNonStringEntries() throws {
        // Numbers, nulls, arrays as items would otherwise crash —
        // they become empty placeholders instead, keeping index
        // alignment with the source.
        let raw = "[null, 42, [\"nested\"], {\"translated\":\"OK\"}]"
        let lines = try LyricsTranslator.parse(raw, expectedCount: 4)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].translated, "")
        XCTAssertEqual(lines[1].translated, "")
        XCTAssertEqual(lines[2].translated, "")
        XCTAssertEqual(lines[3].translated, "OK")
    }

    // MARK: - Failure modes

    func testThrowsOnNoJSONArray() {
        XCTAssertThrowsError(try LyricsTranslator.parse("I cannot do that.", expectedCount: 3)) { err in
            XCTAssertEqual(err as? LyricsTranslator.ParseError, .noJSONArray)
        }
    }

    func testThrowsOnMalformedJSON() {
        // A bracket opens but never closes — extractJSONArray returns
        // nil, so the parser surfaces noJSONArray rather than a
        // confusing Foundation decoding error.
        XCTAssertThrowsError(try LyricsTranslator.parse("[{\"translated\":\"oops\"", expectedCount: 1))
    }

    // MARK: - extractJSONArray edge cases

    func testExtractJSONArrayRespectsEscapedQuotes() {
        // `\"` inside a string MUST NOT close the string and let a
        // `]` terminate the array early. Mirrors the QueueBuilder
        // safeguard since the two parsers share this string-aware
        // depth tracker shape.
        let s = #"[{"translated": "She said \"hi\"", "pronunciation": null}]"#
        let extracted = LyricsTranslator.extractJSONArray(s)
        XCTAssertNotNil(extracted)
        XCTAssertNotNil(extracted.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }

    func testExtractJSONArrayIgnoresBracketsInStrings() {
        // A `]` inside a string literal must not close the array early.
        let s = #"[{"translated": "list [a, b, c]"}]"#
        let extracted = LyricsTranslator.extractJSONArray(s)
        XCTAssertNotNil(extracted)
    }
}
