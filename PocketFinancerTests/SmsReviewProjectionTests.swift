import Foundation
import XCTest

@testable import PocketFinancer

@MainActor
final class SmsReviewProjectionTests: XCTestCase {
    private let source = "🔔 INR 1,250.00 debited from XX1234 at Café"

    func testGroundedProposalPreservesScalarSpansReceiptTimeAndAccountStatuses() throws {
        let unresolved = try XCTUnwrap(
            SmsReviewProjection.parse(resultJSON: try resultJSON(), source: source)
        )
        XCTAssertEqual(unresolved.amountMinorUnits, 125_000)
        XCTAssertEqual(unresolved.amountSpan.text, "INR 1,250.00")
        XCTAssertEqual(unresolved.accountSpan.text, "XX1234")
        XCTAssertEqual(unresolved.counterpartySpan?.text, "Café")
        XCTAssertEqual(unresolved.duplicateIdempotencyKey, "source-v4")
        XCTAssertEqual(unresolved.duplicateSourceEventKey, "event-v4")
        XCTAssertEqual(
            Int64(unresolved.receiptTimestamp.timeIntervalSince1970 * 1_000),
            123_456_789
        )

        let resolvedAccountID = UUID()
        let unique = try XCTUnwrap(
            SmsReviewProjection.parse(
                resultJSON: try resultJSON(
                    accountStatus: "uniquely_resolved",
                    matchCount: 1,
                    accountID: resolvedAccountID.uuidString.lowercased(),
                    matchedAliasHash: CanonicalJSON.sha256("suffix:1234")
                ),
                source: source
            )
        )
        XCTAssertEqual(unique.accountStatus, "uniquely_resolved")
        XCTAssertEqual(unique.resolvedAccountID, resolvedAccountID)

        let ambiguous = try XCTUnwrap(
            SmsReviewProjection.parse(
                resultJSON: try resultJSON(accountStatus: "ambiguous", matchCount: 2),
                source: source
            )
        )
        XCTAssertEqual(ambiguous.accountStatus, "ambiguous")
        XCTAssertNil(ambiguous.resolvedAccountID)
    }

    func testApplyingCorrectionsUpdatesFieldsResetsAccountResolutionAndRevalidatesSpans() throws {
        let multiSource = "INR 1,250.00 debited or INR 50.00 credited on XX1234 or XX5678 at Café"
        let base = try XCTUnwrap(
            SmsReviewProjection.parse(
                resultJSON: try resultJSON(
                    amountSpan: span(0, 12, "INR 1,250.00"),
                    directionSpan: span(13, 20, "debited"),
                    accountSpan: span(46, 52, "XX1234"),
                    counterpartySpan: span(66, 70, "Café"),
                    accountStatus: "uniquely_resolved",
                    matchCount: 1,
                    accountID: UUID().uuidString.lowercased(),
                    matchedAliasHash: CanonicalJSON.sha256("suffix:1234")
                ),
                source: multiSource
            )
        )
        let amountSpan = try UnicodeScalarSpan(source: multiSource, startScalar: 24, endScalar: 33, text: "INR 50.00")
        let directionSpan = try UnicodeScalarSpan(source: multiSource, startScalar: 34, endScalar: 42, text: "credited")
        let accountSpan = try UnicodeScalarSpan(source: multiSource, startScalar: 56, endScalar: 62, text: "XX5678")

        let updated = try SmsReviewProjection.applying(
            [
                SmsFieldCorrection(
                    field: "amount",
                    classification: .changedInterpretationAmongCandidates,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: amountSpan,
                    newValue: "5000"
                ),
                SmsFieldCorrection(
                    field: "direction",
                    classification: .changedInterpretationAmongCandidates,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: directionSpan,
                    newValue: "credit"
                ),
                SmsFieldCorrection(
                    field: "account",
                    classification: .changedInterpretationAmongCandidates,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: accountSpan,
                    newValue: "5678"
                ),
                SmsFieldCorrection(
                    field: "counterparty",
                    classification: .suppliedSourceSupportedCandidateMiss,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: nil,
                    newValue: ""
                ),
            ],
            to: base,
            source: multiSource
        )
        XCTAssertEqual(updated.amountMinorUnits, 5000)
        XCTAssertEqual(updated.direction, "credit")
        XCTAssertEqual(updated.accountReference, "5678")
        XCTAssertEqual(updated.accountStatus, "unresolved")
        XCTAssertNil(updated.resolvedAccountID)
        XCTAssertNil(updated.counterparty)
        XCTAssertNil(updated.counterpartySpan)

        let cafeSpan = try UnicodeScalarSpan(source: source, startScalar: 38, endScalar: 42, text: "Café")
        let cafeCorrection = SmsFieldCorrection(
            field: "counterparty",
            classification: .suppliedSourceSupportedCandidateMiss,
            previousRevisionID: nil,
            candidateID: nil,
            evidence: nil,
            scalarEvidence: cafeSpan,
            newValue: "café"
        )
        let original = try XCTUnwrap(
            SmsReviewProjection.parse(resultJSON: try resultJSON(), source: source)
        )
        XCTAssertEqual(
            try SmsReviewProjection.applying([cafeCorrection], to: original, source: source).counterparty,
            "café"
        )
        XCTAssertThrowsError(
            try SmsReviewProjection.applying(
                [cafeCorrection],
                to: original,
                source: source.replacingOccurrences(of: "Café", with: "Cafe")
            )
        )
    }

    func testProposalRejectsFloatingPointContractIntegersAndSemanticDisagreements() throws {
        let valid = try resultJSON()
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"minor_units\":125000",
                    with: "\"minor_units\":125000.0"
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"epoch_ms\":123456789",
                    with: "\"epoch_ms\":123456789.0"
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: try resultJSON(amount: 125_001),
                source: source
            )
        )
    }

    func testProposalRejectsUnknownStatusesInvalidAliasesAndBrokenFingerprints() throws {
        let valid = try resultJSON()
        let validFingerprint = CanonicalJSON.sha256("125000\0INR\0debit\0\0123456789")

        let invalidMutations: [(String, String)] = [
            ("\"status\":\"blocked\"", "\"status\":\"eligible\""),
            ("\"status\":\"unresolved\"", "\"status\":\"guessed\""),
            ("\"status\":\"clear\"", "\"status\":\"unknown\""),
            ("\"provenance\":\"platform_received\"", "\"provenance\":\"inferred\""),
            ("\"match_count\":0", "\"match_count\":1"),
            ("\"transaction_fingerprint\":\"\(validFingerprint)\"", "\"transaction_fingerprint\":\"bad\""),
            ("\"normalized_reference\":\"suffix:1234\"", "\"normalized_reference\":\"1234\""),
            ("\"matched_alias_hash\":null", "\"matched_alias_hash\":\"\(CanonicalJSON.sha256("suffix:1234"))\""),
        ]
        for (target, replacement) in invalidMutations {
            XCTAssertNil(
                SmsReviewProjection.parse(
                    resultJSON: valid.replacingOccurrences(of: target, with: replacement),
                    source: source
                ),
                "Expected rejection for replacement \(replacement)"
            )
        }

        var missingAssessment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any]
        )
        missingAssessment["duplicate_assessment"] = NSNull()
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: String(
                    decoding: try JSONSerialization.data(withJSONObject: missingAssessment),
                    as: UTF8.self
                ),
                source: source
            )
        )
    }

    private func resultJSON(
        amount: Any = 125_000,
        epochMilliseconds: Any = 123_456_789,
        amountSpan: [String: Any]? = nil,
        directionSpan: [String: Any]? = nil,
        accountSpan: [String: Any]? = nil,
        counterpartySpan: [String: Any]? = nil,
        accountStatus: String = "unresolved",
        matchCount: Int = 0,
        accountID: String? = nil,
        matchedAliasHash: String? = nil
    ) throws -> String {
        let fingerprint = CanonicalJSON.sha256(
            "\(amount)\0INR\0debit\0\(accountID ?? "")\0\(epochMilliseconds)"
        )
        let object: [String: Any] = [
            "contract": "pocketfinancer.processing-result/3",
            "status": "blocked",
            "recognition_decision": "posted",
            "semantic_result": [
                "money": ["minor_units": amount, "currency": "INR"],
                "direction": "debit",
                "account_reference": "1234",
                "counterparty": "café",
                "evidence": [
                    "amount": amountSpan ?? span(2, 14, "INR 1,250.00"),
                    "direction": directionSpan ?? span(15, 22, "debited"),
                    "account": accountSpan ?? span(28, 34, "XX1234"),
                    "counterparty": counterpartySpan ?? span(38, 42, "Café"),
                ],
            ],
            "receipt_timestamp": [
                "epoch_ms": epochMilliseconds,
                "provenance": "platform_received",
                "read_only": true,
            ],
            "account_resolution": [
                "status": accountStatus,
                "match_count": matchCount,
                "account_id": (accountID as Any?) ?? NSNull(),
                "normalized_reference": "suffix:1234",
                "matched_alias_hash": (matchedAliasHash as Any?) ?? NSNull(),
                "provenance": "pocketfinancer.account-resolution-profile/1",
            ],
            "duplicate_assessment": [
                "status": "clear",
                "idempotency_key": "source-v4",
                "source_event_key": "event-v4",
                "transaction_fingerprint": fingerprint,
            ],
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func span(_ start: Int, _ end: Int, _ text: String) -> [String: Any] {
        ["start_scalar": start, "end_scalar": end, "text": text]
    }
}
