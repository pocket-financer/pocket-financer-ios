import Foundation
import XCTest

@testable import PocketFinancer

final class SmsPrefilterTests: XCTestCase {
    func testAllFrozenPrefilterVectorsMatchCanonicalOutcomes() throws {
        let url = try locateVectorsURL()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(SmsPrefilter.policyID, "sms-prefilter/1")
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

    func testGuardsExcludeConditionalRequestsAndPreserveCompletedTransactions() {
        let empty = SmsPrefilter.evaluate("   \n\t  ")
        XCTAssertEqual(empty, SmsPrefilter.Result(decision: .exclude, reason: .empty))

        let noDigits = SmsPrefilter.evaluate("Thank you for banking with Demo Bank.")
        XCTAssertEqual(noDigits, SmsPrefilter.Result(decision: .exclude, reason: .noDigits))

        let conditionalCollect = SmsPrefilter.evaluate(
            "Demo Merchant has requested Rs.500.00. Once approved, money will be debited."
        )
        XCTAssertEqual(
            conditionalCollect,
            SmsPrefilter.Result(decision: .exclude, reason: .collectOrMandateRequest)
        )

        let withoutOtpDebit = SmsPrefilter.evaluate(
            "Txn Rs.450.00 on Card XX1234 without OTP at Demo Coffee."
        )
        XCTAssertEqual(
            withoutOtpDebit,
            SmsPrefilter.Result(decision: .pass, reason: .eligible)
        )

        let standaloneOtp = SmsPrefilter.evaluate(
            "Your OTP for card transaction is 482910. Do not share."
        )
        XCTAssertEqual(
            standaloneOtp,
            SmsPrefilter.Result(decision: .exclude, reason: .otpVerification)
        )
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
        throw NSError(
            domain: "SmsPrefilterTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "prefilter-vectors.json is missing from test bundle resources"
            ]
        )
    }
}
