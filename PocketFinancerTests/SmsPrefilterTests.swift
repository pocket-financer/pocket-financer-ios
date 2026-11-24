import XCTest

@testable import PocketFinancer

final class SmsPrefilterTests: XCTestCase {
    func testAllFrozenPrefilterVectorsMatchCanonicalOutcomes() throws {
        let url = try locateVectorsURL()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 54)

        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let body = try XCTUnwrap(vector["body"] as? String)
            let expectedDecision = try XCTUnwrap(vector["decision"] as? String)
            let expectedReason = try XCTUnwrap(vector["reason"] as? String)

            let result = SmsPrefilter.evaluate(body)
            XCTAssertEqual(result.decision.rawValue, expectedDecision, id)
            XCTAssertEqual(result.reason.rawValue, expectedReason, id)
        }
    }

    private func locateVectorsURL() throws -> URL {
        let bundles = [Bundle(for: SmsPrefilterTests.self), Bundle.main]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "prefilter-vectors",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) {
                return url
            }
            if let url = bundle.url(forResource: "prefilter-vectors", withExtension: "json") {
                return url
            }
        }
        throw XCTSkip("prefilter-vectors.json was not copied into test bundle resources")
    }
}
