import XCTest
@testable import Riff

final class InnerTubeClientTests: XCTestCase {
    func testClientVersionMatchesExpectedFormat() {
        // Sanity: clientVersion is the only knob we touch when Google rotates it.
        let v = InnerTubeClient.clientVersion
        XCTAssertTrue(v.contains("."), "clientVersion should be dotted: \(v)")
    }

    // TODO: snapshot-fixture tests against captured /search and /browse responses.
}
