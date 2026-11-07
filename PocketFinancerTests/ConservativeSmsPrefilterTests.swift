import CryptoKit
import Foundation
import XCTest

@testable import PocketFinancer

final class ConservativeSmsPrefilterTests: XCTestCase {
    func testSharedInventedVectorsPreserveSourceAndDeterministicDecisions() throws {
        // Canonical source: intelligence tests/sms_processing/golden/prefilter-v1.json.
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "prefilter-v1", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "373337f584cd70d4d165e7ff557fb45ece8967f3795d0d2d05a02f61db5053c9")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document = try decoder.decode(PrefilterDocument.self, from: data)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.policyId, ConservativeSmsPrefilter.policyID)
        XCTAssertTrue(document.provenance.hasPrefix("Invented for the prefilter pilot;"))
        XCTAssertEqual(document.vectors.count, 38)
        XCTAssertEqual(Set(document.vectors.map(\.id)).count, document.vectors.count)
        for vector in document.vectors {
            let body = vector.body
            let original = Data(body.utf8)
            let result = ConservativeSmsPrefilter.evaluate(body)
            XCTAssertEqual(result.decision.rawValue, vector.decision, vector.id)
            XCTAssertEqual(result.reason.rawValue, vector.reason, vector.id)
            XCTAssertEqual(result, ConservativeSmsPrefilter.evaluate(body), vector.id)
            XCTAssertEqual(Data(body.utf8), original, vector.id)
            // Sender is decoded as metadata, never supplied to the body-only policy.
            XCTAssertFalse(vector.id.isEmpty)
        }
    }
}

private struct PrefilterDocument: Decodable {
    let schemaVersion: Int
    let policyId: String
    let provenance: String
    let vectors: [PrefilterVector]
}

private struct PrefilterVector: Decodable {
    let id: String
    let sender: String
    let body: String
    let decision: String
    let reason: String
}
