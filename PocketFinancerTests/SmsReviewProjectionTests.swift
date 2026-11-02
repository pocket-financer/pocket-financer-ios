import XCTest

@testable import PocketFinancer

final class SmsReviewProjectionTests: XCTestCase {
    private let source = "🔔 INR 1,250.00 debited from XX1234 at Café"

    func testV4ProposalPreservesScalarSpansAndReceiptTime() throws {
        let proposal = try XCTUnwrap(
            SmsReviewProjection.parse(resultJSON: try resultJSON(), source: source)
        )

        XCTAssertEqual(proposal.amountMinorUnits, 125_000)
        XCTAssertEqual(proposal.amountSpan.text, "INR 1,250.00")
        XCTAssertEqual(proposal.accountSpan.text, "XX1234")
        XCTAssertEqual(proposal.counterpartySpan?.text, "Café")
        XCTAssertEqual(proposal.duplicateIdempotencyKey, "source-v4")
        XCTAssertEqual(proposal.duplicateSourceEventKey, "event-v4")
        XCTAssertEqual(
            Int64(proposal.receiptTimestamp.timeIntervalSince1970 * 1_000),
            123_456_789
        )
    }

    @MainActor
    func testDraftCorrectionRevalidatesExactSourceSpan() throws {
        let proposal = try XCTUnwrap(
            SmsReviewProjection.parse(resultJSON: try resultJSON(), source: source)
        )
        let span = try UnicodeScalarSpan(
            source: source,
            startScalar: 38,
            endScalar: 42,
            text: "Café"
        )
        let correction = SmsFieldCorrection(
            field: "counterparty",
            classification: .suppliedSourceSupportedCandidateMiss,
            previousRevisionID: nil,
            candidateID: nil,
            evidence: nil,
            scalarEvidence: span,
            newValue: "café"
        )

        XCTAssertEqual(
            try SmsReviewProjection.applying([correction], to: proposal, source: source)
                .counterparty,
            "café"
        )
        XCTAssertThrowsError(
            try SmsReviewProjection.applying(
                [correction],
                to: proposal,
                source: source.replacingOccurrences(of: "Café", with: "Cafe")
            )
        )
    }

    func testProposalRejectsFloatingPointContractIntegers() throws {
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
    }

    func testProposalRejectsSemanticValueThatDoesNotMatchEvidence() throws {
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: try resultJSON(amount: 125_001),
                source: source
            )
        )
    }

    func testProposalRejectsUnknownStatusesAndReceiptProvenance() throws {
        let valid = try resultJSON()
        let validFingerprint = CanonicalJSON.sha256(
            "125000\0INR\0debit\0\0123456789"
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"status\":\"blocked\"",
                    with: "\"status\":\"eligible\""
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"status\":\"unresolved\"",
                    with: "\"status\":\"guessed\""
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"status\":\"clear\"",
                    with: "\"status\":\"unknown\""
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"provenance\":\"platform_received\"",
                    with: "\"provenance\":\"inferred\""
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"match_count\":0",
                    with: "\"match_count\":1"
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"transaction_fingerprint\":\"\(validFingerprint)\"",
                    with: "\"transaction_fingerprint\":\"bad\""
                ),
                source: source
            )
        )
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

    func testAccountResolutionRequiresCanonicalAliasKey() throws {
        let valid = try resultJSON()
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"normalized_reference\":\"suffix:1234\"",
                    with: "\"normalized_reference\":\"1234\""
                ),
                source: source
            )
        )
        XCTAssertNil(
            SmsReviewProjection.parse(
                resultJSON: valid.replacingOccurrences(
                    of: "\"matched_alias_hash\":null",
                    with: "\"matched_alias_hash\":\"\(CanonicalJSON.sha256("suffix:1234"))\""
                ),
                source: source
            )
        )
    }

    private func resultJSON(
        amount: Any = 125_000,
        epochMilliseconds: Any = 123_456_789
    ) throws -> String {
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
                    "amount": span(2, 14, "INR 1,250.00"),
                    "direction": span(15, 22, "debited"),
                    "account": span(28, 34, "XX1234"),
                    "counterparty": span(38, 42, "Café"),
                ],
            ],
            "receipt_timestamp": [
                "epoch_ms": epochMilliseconds,
                "provenance": "platform_received",
                "read_only": true,
            ],
            "account_resolution": [
                "status": "unresolved",
                "match_count": 0,
                "account_id": NSNull(),
                "normalized_reference": "suffix:1234",
                "matched_alias_hash": NSNull(),
                "provenance": "pocketfinancer.account-resolution-profile/1",
            ],
            "duplicate_assessment": [
                "status": "clear",
                "idempotency_key": "source-v4",
                "source_event_key": "event-v4",
                "transaction_fingerprint": CanonicalJSON.sha256(
                    "125000\0INR\0debit\0\0123456789"
                ),
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
