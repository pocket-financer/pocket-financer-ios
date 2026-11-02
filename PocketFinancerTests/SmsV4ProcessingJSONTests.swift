import XCTest

@testable import PocketFinancer

final class SmsV4ProcessingJSONTests: XCTestCase {
    func testNoneGateUsesSharedPersistenceOrdering() throws {
        let gate = SmsV4ProcessingJSON.gate(
            posted: false,
            accountReason: "account_resolution_unresolved",
            duplicateStatus: "clear"
        )

        XCTAssertEqual(gate["result"] as? String, "not_posted")
        XCTAssertEqual(gate["primary_reason"] as? String, "persistence_not_posted")
        let checks = try XCTUnwrap(gate["checks"] as? [[String: Any]])
        XCTAssertEqual(checks[4]["reason_code"] as? String, "persistence_not_posted")
        XCTAssertEqual(
            checks[5]["reason_code"] as? String,
            "persistence_grounded_fields_missing"
        )
        XCTAssertEqual(checks[6]["reason_code"] as? String, "persistence_invalid_money")
    }

    func testAccountAndDuplicateFailuresPrecedeReviewOnlyRollout() {
        let account = SmsV4ProcessingJSON.gate(
            posted: true,
            accountReason: "account_resolution_ambiguous",
            duplicateStatus: "clear"
        )
        XCTAssertEqual(account["result"] as? String, "review_required")
        XCTAssertEqual(account["primary_reason"] as? String, "account_resolution_ambiguous")

        let duplicate = SmsV4ProcessingJSON.gate(
            posted: true,
            accountReason: nil,
            duplicateStatus: "already_persisted"
        )
        XCTAssertEqual(duplicate["result"] as? String, "review_required")
        XCTAssertEqual(duplicate["primary_reason"] as? String, "duplicate_already_persisted")

        let reviewOnly = SmsV4ProcessingJSON.gate(
            posted: true,
            accountReason: nil,
            duplicateStatus: "clear"
        )
        XCTAssertEqual(reviewOnly["result"] as? String, "blocked_by_mode")
        XCTAssertEqual(
            reviewOnly["primary_reason"] as? String,
            "persistence_blocked_by_rollout_mode"
        )
    }

    func testAccountResultSerializesCanonicalAliasKey() {
        let unresolved = SmsV4ProcessingJSON.account(.unresolved, reference: "1234")
        XCTAssertEqual(unresolved["normalized_reference"] as? String, "suffix:1234")

        let unique = SmsV4ProcessingJSON.account(
            .unique(accountID: UUID()),
            reference: "name@bank"
        )
        XCTAssertEqual(unique["normalized_reference"] as? String, "vpa:name@bank")
        XCTAssertEqual(
            unique["matched_alias_hash"] as? String,
            CanonicalJSON.sha256("vpa:name@bank")
        )
    }
}
