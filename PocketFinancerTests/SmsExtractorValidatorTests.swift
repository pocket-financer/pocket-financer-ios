import XCTest

@testable import PocketFinancer

final class SmsExtractorValidatorTests: XCTestCase {
    func testSanitizedExtractorVectorsMatchFrozenExpectedSemantics() throws {
        let vectors = try Self.sanitizedVectors()
        XCTAssertEqual(vectors.count, 5)
        let validator = SmsExtractorValidator()

        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let source = try XCTUnwrap(vector["sms_body"] as? String)
            let output = try JSONSerialization.data(
                withJSONObject: try XCTUnwrap(vector["model_output"])
            )
            let raw = String(decoding: output, as: UTF8.self)
            if let reason = vector["expected_reason"] as? String {
                XCTAssertThrowsError(
                    try validator.validate(rawOutput: raw, source: source, primaryCurrency: "INR"),
                    id
                ) { error in
                    XCTAssertEqual((error as? SmsExtractorValidationError)?.reasonCode, reason, id)
                }
                continue
            }
            let result = try validator.validate(
                rawOutput: raw,
                source: source,
                primaryCurrency: "INR"
            )
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            XCTAssertEqual(result.decision.rawValue, expected["decision"] as? String, id)
            if result.decision == .posted {
                let transaction = try XCTUnwrap(result.transaction)
                XCTAssertEqual(
                    transaction.minorUnits,
                    (expected["amount_minor_units"] as? NSNumber)?.int64Value,
                    id
                )
                XCTAssertEqual(transaction.currency, expected["amount_currency"] as? String, id)
                XCTAssertEqual(transaction.direction.rawValue, expected["direction"] as? String, id)
                XCTAssertEqual(
                    transaction.accountReference,
                    expected["account_reference"] as? String,
                    id
                )
                XCTAssertEqual(transaction.counterparty, expected["counterparty"] as? String, id)
            }
        }
    }

    func testExpandedDirectionCuesGroundRealAlertPhrasings() throws {
        let debitSource = "Txn Rs.450.00 on Card XX1234 without OTP at Coffee."
        let debitOutput = try TestFixtures.strictPostedOutput(
            for: debitSource,
            amountText: "Rs.450.00",
            amountValue: "450.00",
            direction: "debit",
            directionText: "without OTP",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: "Coffee"
        )
        let debit = try SmsExtractorValidator().validate(
            rawOutput: debitOutput,
            source: debitSource,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(debit.transaction?.direction, .debit)

        let creditSource = "Refund Rs.200.00 cashback adjusted to Card XX1234."
        let creditOutput = try TestFixtures.strictPostedOutput(
            for: creditSource,
            amountText: "Rs.200.00",
            amountValue: "200.00",
            direction: "credit",
            directionText: "adjusted",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        let credit = try SmsExtractorValidator().validate(
            rawOutput: creditOutput,
            source: creditSource,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(credit.transaction?.direction, .credit)
    }

    func testNonCurrencyWordsWithRsDoNotTriggerInrMarkerConflict() throws {
        let source = "Paid orders 25.00 from card XX1234."
        let raw = try TestFixtures.strictPostedOutput(
            for: source,
            amountText: "orders 25.00",
            amountValue: "25.00",
            currency: "USD",
            direction: "debit",
            directionText: "Paid",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        let result = try SmsExtractorValidator().validate(
            rawOutput: raw,
            source: source,
            primaryCurrency: "USD"
        )
        XCTAssertEqual(result.transaction?.currency, "USD")
    }

    func testStrictOutputRejectsDuplicateKeyTrailingDocumentExponentAndDecimalNumbers() throws {
        let validator = SmsExtractorValidator()
        let source = "INR 10.00 debited from XX1234"
        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"none","decision":"abstain"}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(
                (error as? SmsExtractorValidationError)?.reasonCode,
                "extractor_duplicate_json_key"
            )
        }
        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"none"} {}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(
                (error as? SmsExtractorValidationError)?.reasonCode,
                "extractor_extra_content"
            )
        }
        XCTAssertThrowsError(
            try validator.validate(rawOutput: #"{"decision":1e0}"#, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(
                (error as? SmsExtractorValidationError)?.reasonCode,
                "extractor_malformed_json"
            )
        }
        let decimalScalar =
            #"{"decision":"posted","amount":{"value":"10.00","currency":"INR","#
            + #""evidence":{"start_scalar":0.0,"end_scalar":9,"text":"INR 10.00"}},"#
            + #""direction":{"value":"debit","evidence":{"start_scalar":10,"end_scalar":17,"text":"debited"}},"#
            + #""account":{"reference":"XX1234","evidence":{"start_scalar":23,"end_scalar":29,"text":"XX1234"}},"#
            + #""counterparty":null}"#
        XCTAssertThrowsError(
            try validator.validate(rawOutput: decimalScalar, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(
                (error as? SmsExtractorValidationError)?.reasonCode,
                "extractor_malformed_json"
            )
        }
    }

    func testScalarRangeConvertsEmojiToUtf16WithoutSplitting() throws {
        let source = "A 💳 INR"
        let span = try UnicodeScalarSpan(source: source, startScalar: 2, endScalar: 3, text: "💳")
        XCTAssertEqual(try span.nsRange(in: source), NSRange(location: 2, length: 2))
    }

    func testAccountNormalizationUsesFrozenVpaGrammar() {
        XCTAssertEqual(SmsExtractorNormalizer.normalizeAccount("ab@1x"), "ab@1x")
        XCTAssertNil(SmsExtractorNormalizer.normalizeAccount(".a@example.com"))
    }

    func testExactMoneyRejectsCoercionAndHonorsInt64Boundary() throws {
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "01.00", currency: "INR"))
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "+1.00", currency: "INR"))
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "1.001", currency: "INR"))
        XCTAssertThrowsError(
            try SmsExtractorNormalizer.minorUnits(decimal: "92233720368547758.08", currency: "INR")
        )
        XCTAssertEqual(
            try SmsExtractorNormalizer.minorUnits(
                decimal: "92233720368547758.07",
                currency: "INR"
            ),
            Int64.max
        )
    }

    func testCounterpartyUsesCasefoldAndScalarLengthLimit() {
        XCTAssertEqual(SmsExtractorNormalizer.normalizeCounterparty("Straße"), "strasse")
        XCTAssertEqual(SmsExtractorNormalizer.normalizeCounterparty("ΟΣ"), "οσ")
        XCTAssertNil(
            SmsExtractorNormalizer.normalizeCounterparty(String(repeating: "a\u{0338}", count: 129))
        )
    }

    private static func scalarSpan(start: Int, end: Int, text: String) -> [String: Any] {
        ["start_scalar": start, "end_scalar": end, "text": text]
    }

    private static func postedModelOutput(
        amountValue: String,
        amountSpan: [String: Any],
        directionValue: String,
        directionSpan: [String: Any],
        accountReference: String,
        accountSpan: [String: Any],
        counterpartyValue: String? = nil,
        counterpartySpan: [String: Any]? = nil
    ) -> [String: Any] {
        let amount: [String: Any] = ["value": amountValue, "currency": "INR", "evidence": amountSpan]
        let direction: [String: Any] = ["value": directionValue, "evidence": directionSpan]
        let account: [String: Any] = ["reference": accountReference, "evidence": accountSpan]
        var counterparty: Any = NSNull()
        if let counterpartyValue, let counterpartySpan {
            let entry: [String: Any] = ["value": counterpartyValue, "evidence": counterpartySpan]
            counterparty = entry
        }
        return [
            "decision": "posted",
            "amount": amount,
            "direction": direction,
            "account": account,
            "counterparty": counterparty,
        ]
    }

    private static func expectedPosted(
        minorUnits: Int,
        direction: String,
        accountReference: String,
        counterparty: String? = nil
    ) -> [String: Any] {
        var counterpartyEntry: Any = NSNull()
        if let counterparty {
            counterpartyEntry = counterparty
        }
        return [
            "decision": "posted",
            "amount_minor_units": minorUnits,
            "amount_currency": "INR",
            "direction": direction,
            "account_reference": accountReference,
            "counterparty": counterpartyEntry,
        ]
    }

    private static func sanitizedVectors() throws -> [[String: Any]] {
        let emojiBody = "Alert \u{1F4B3}: INR 1,250.00 debited from a/c XX1234 at Caf\u{00E9}."
        let emojiOutput = postedModelOutput(
            amountValue: "1250.00",
            amountSpan: scalarSpan(start: 9, end: 21, text: "INR 1,250.00"),
            directionValue: "debit",
            directionSpan: scalarSpan(start: 22, end: 29, text: "debited"),
            accountReference: "XX1234",
            accountSpan: scalarSpan(start: 39, end: 45, text: "XX1234"),
            counterpartyValue: "Caf\u{00E9}",
            counterpartySpan: scalarSpan(start: 49, end: 53, text: "Caf\u{00E9}")
        )
        let emojiExpected = expectedPosted(
            minorUnits: 125_000,
            direction: "debit",
            accountReference: "1234",
            counterparty: "caf\u{00E9}"
        )

        let combiningBody = "Cafe\u{0301} INR 42.00 credited to account XX4321."
        let combiningOutput = postedModelOutput(
            amountValue: "42.00",
            amountSpan: scalarSpan(start: 6, end: 15, text: "INR 42.00"),
            directionValue: "credit",
            directionSpan: scalarSpan(start: 16, end: 24, text: "credited"),
            accountReference: "XX4321",
            accountSpan: scalarSpan(start: 36, end: 42, text: "XX4321")
        )
        let combiningExpected = expectedPosted(minorUnits: 4200, direction: "credit", accountReference: "4321")

        let mismatchedOutput = postedModelOutput(
            amountValue: "1250.00",
            amountSpan: scalarSpan(start: 0, end: 12, text: "INR 1,250.00"),
            directionValue: "debit",
            directionSpan: scalarSpan(start: 13, end: 20, text: "debited"),
            accountReference: "XX0000",
            accountSpan: scalarSpan(start: 34, end: 40, text: "XX0000")
        )

        return [
            [
                "id": "unicode_emoji_zero_evidence",
                "sms_body": emojiBody,
                "model_output": emojiOutput,
                "expected": emojiExpected,
            ],
            [
                "id": "combining_mark_conflicting_advice",
                "sms_body": combiningBody,
                "model_output": combiningOutput,
                "expected": combiningExpected,
            ],
            [
                "id": "sanitized_negative",
                "sms_body": "Your statement is ready to view in the app.",
                "model_output": ["decision": "none"],
                "expected": ["decision": "none"],
            ],
            [
                "id": "mandatory_account_missing",
                "sms_body": "INR 75.00 was debited.",
                "model_output": ["decision": "abstain"],
                "expected": ["decision": "abstain"],
            ],
            [
                "id": "adversarial_mismatched_span",
                "sms_body": "INR 1,250.00 debited from account XX9999.",
                "model_output": mismatchedOutput,
                "expected_reason": "extractor_evidence_mismatch",
            ],
        ]
    }
}
