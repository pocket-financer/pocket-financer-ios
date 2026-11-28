import Foundation
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

    func testCreditDirectionGroundingHandlesNeutralPaymentAndTxnWords() throws {
        let paymentReceived = "Payment of Rs.1,500.00 received towards your Credit Card XX1234."
        XCTAssertTrue(SmsExtractorNormalizer.directionGrounded(direction: "credit", text: paymentReceived))
        XCTAssertEqual(SmsExtractorNormalizer.inferredDirection(from: paymentReceived), "credit")
        XCTAssertEqual(SmsExtractorNormalizer.direction(paymentReceived), "credit")
        XCTAssertEqual(SmsExtractorNormalizer.supportedDirections(for: paymentReceived).first, "credit")

        let txnRefunded = "UPI txn refunded Rs.250.00 to a/c XX1234."
        XCTAssertTrue(SmsExtractorNormalizer.directionGrounded(direction: "credit", text: txnRefunded))
        XCTAssertEqual(SmsExtractorNormalizer.inferredDirection(from: txnRefunded), "credit")
        XCTAssertEqual(SmsExtractorNormalizer.supportedDirections(for: txnRefunded).first, "credit")

        let transferCredited = "Transfer of Rs.900.00 credited to a/c XX1234."
        XCTAssertEqual(SmsExtractorNormalizer.inferredDirection(from: transferCredited), "credit")

        let creditCardDebit = "Payment of Rs.500.00 on your Credit Card XX1234."
        XCTAssertTrue(SmsExtractorNormalizer.directionGrounded(direction: "debit", text: creditCardDebit))
        XCTAssertEqual(SmsExtractorNormalizer.inferredDirection(from: creditCardDebit), "debit")
        XCTAssertEqual(SmsExtractorNormalizer.supportedDirections(for: creditCardDebit).first, "debit")

        XCTAssertEqual(SmsExtractorNormalizer.inferredDirection(from: "Txn Rs.500.00"), "debit")
        XCTAssertEqual(SmsExtractorNormalizer.supportedDirections(for: "Txn Rs.500.00"), ["debit"])
        XCTAssertNil(SmsExtractorNormalizer.inferredDirection(from: "Hello world"))
        XCTAssertEqual(SmsExtractorNormalizer.supportedDirections(for: "Hello world"), [])

        let validatedCredit = try SmsExtractorValidator().validate(
            rawOutput: try TestFixtures.strictPostedOutput(
                for: paymentReceived,
                amountText: "Rs.1,500.00",
                amountValue: "1500.00",
                direction: "credit",
                directionText: "Payment of Rs.1,500.00 received",
                accountReference: "XX1234",
                accountText: "XX1234",
                counterpartyText: nil
            ),
            source: paymentReceived,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(validatedCredit.transaction?.direction, .credit)
    }

    func testCollectGroundedFieldsRetainsValidAndGroundedOnlyFieldsWithoutRepairingInvalidOutput() throws {
        let source = "INR 500.00 debited from account at Demo Store."
        let amountRange = try XCTUnwrap(source.range(of: "INR 500.00"))
        let directionRange = try XCTUnwrap(source.range(of: "debited"))
        let counterpartyRange = try XCTUnwrap(source.range(of: "Demo Store"))
        let partialOutput = try SmsProcessingJSON.canonical([
            "decision": "posted",
            "amount": [
                "value": "500.00",
                "currency": "INR",
                "evidence": [
                    "start_scalar": source[..<amountRange.lowerBound].unicodeScalars.count,
                    "end_scalar": source[..<amountRange.upperBound].unicodeScalars.count,
                    "text": "INR 500.00",
                ],
            ],
            "direction": [
                "value": "credit",
                "evidence": [
                    "start_scalar": source[..<directionRange.lowerBound].unicodeScalars.count,
                    "end_scalar": source[..<directionRange.upperBound].unicodeScalars.count,
                    "text": "debited",
                ],
            ],
            "account": [
                "reference": "",
                "evidence": ["start_scalar": 0, "end_scalar": 0, "text": ""],
            ],
            "counterparty": [
                "value": "Demo Store",
                "evidence": [
                    "start_scalar": source[..<counterpartyRange.lowerBound].unicodeScalars.count,
                    "end_scalar": source[..<counterpartyRange.upperBound].unicodeScalars.count,
                    "text": "Demo Store",
                ],
            ],
        ])

        let validator = SmsExtractorValidator()
        XCTAssertThrowsError(
            try validator.validate(rawOutput: partialOutput, source: source, primaryCurrency: "INR")
        )
        let collected = validator.collectGroundedFields(
            rawOutput: partialOutput,
            source: source,
            primaryCurrency: "INR"
        )
        let byField = Dictionary(uniqueKeysWithValues: collected.map { ($0.field, $0) })

        XCTAssertEqual(byField[.amount]?.validationState, .valid)
        XCTAssertEqual(byField[.amount]?.originatingStage, "normalization")
        XCTAssertEqual(
            byField[.amount]?.normalizedAmount,
            SmsNormalizedAmountValue(minorUnits: 50_000, currency: "INR")
        )
        XCTAssertEqual(byField[.direction]?.validationState, .groundedOnly)
        XCTAssertEqual(byField[.direction]?.originatingStage, "extractor_validation")
        XCTAssertNil(byField[.direction]?.normalizedValue)
        XCTAssertNil(byField[.account])
        XCTAssertEqual(byField[.counterparty]?.validationState, .valid)
        XCTAssertEqual(byField[.counterparty]?.normalizedCounterparty, "demo store")

        XCTAssertTrue(
            validator.collectGroundedFields(rawOutput: "not-json", source: source, primaryCurrency: "INR").isEmpty
        )
        XCTAssertTrue(
            validator.collectGroundedFields(
                rawOutput: #"{"decision":"none"}"#,
                source: source,
                primaryCurrency: "INR"
            ).isEmpty
        )
        XCTAssertTrue(
            validator.collectGroundedFields(
                rawOutput: #"{"decision":"posted","decision":"posted"}"#,
                source: source,
                primaryCurrency: "INR"
            ).isEmpty
        )
    }

    func testNfkcAmountsLeadingZerosWhitespaceCollapsingAndUnicodeScalarEdgeCases() throws {
        let fullwidthSource = "Ｒｓ．１，２５０．００ debited from XX  \t 1234 at Demo\u{00A0}\n  Store."
        let fullwidthRaw = try TestFixtures.strictPostedOutput(
            for: fullwidthSource,
            amountText: "Ｒｓ．１，２５０．００",
            amountValue: "1250.00",
            currency: "INR",
            direction: "debit",
            directionText: "debited",
            accountReference: "XX 1234",
            accountText: "XX  \t 1234",
            counterpartyText: "Demo\u{00A0}\n  Store"
        )
        let fullwidthResult = try SmsExtractorValidator().validate(
            rawOutput: fullwidthRaw,
            source: fullwidthSource,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(fullwidthResult.transaction?.minorUnits, 125_000)
        XCTAssertEqual(fullwidthResult.transaction?.accountReference, "1234")
        XCTAssertEqual(fullwidthResult.transaction?.counterparty, "demo store")

        let leadingZeroSource = "INR 0100.00 paid from card XX1234 without\n  OTP."
        let leadingZeroRaw = try TestFixtures.strictPostedOutput(
            for: leadingZeroSource,
            amountText: "INR 0100.00",
            amountValue: "100.00",
            currency: "INR",
            direction: "debit",
            directionText: "without\n  OTP",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        let leadingZeroResult = try SmsExtractorValidator().validate(
            rawOutput: leadingZeroRaw,
            source: leadingZeroSource,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(leadingZeroResult.transaction?.minorUnits, 10_000)
        XCTAssertEqual(
            try SmsExtractorNormalizer.minorUnits(evidenceText: "Rs. 00000000000000000000050.25", currency: "INR"),
            5_025
        )

        let crlfSource = "INR 500\r\nDebited"
        let beforeNewline = try UnicodeScalarSpan(source: crlfSource, startScalar: 0, endScalar: 8, text: "INR 500\r")
        XCTAssertEqual(try beforeNewline.nsRange(in: crlfSource), NSRange(location: 0, length: 8))
        let fromNewline = try UnicodeScalarSpan(source: crlfSource, startScalar: 8, endScalar: 16, text: "\nDebited")
        XCTAssertEqual(try fromNewline.nsRange(in: crlfSource), NSRange(location: 8, length: 8))
        XCTAssertEqual(
            UnicodeScalarSpan(source: crlfSource, nsRange: NSRange(location: 8, length: 8)),
            fromNewline
        )

        let combiningSource = "Cafe\u{0301} INR 42.00"
        let baseOnly = try UnicodeScalarSpan(source: combiningSource, startScalar: 0, endScalar: 4, text: "Cafe")
        XCTAssertEqual(try baseOnly.nsRange(in: combiningSource), NSRange(location: 0, length: 4))
        XCTAssertEqual(
            UnicodeScalarSpan(source: combiningSource, nsRange: NSRange(location: 0, length: 4)),
            baseOnly
        )

        let emojiSource = "A 💳 INR"
        XCTAssertEqual(
            UnicodeScalarSpan(source: emojiSource, nsRange: NSRange(location: 2, length: 2)),
            try UnicodeScalarSpan(source: emojiSource, startScalar: 2, endScalar: 3, text: "💳")
        )
        XCTAssertNil(UnicodeScalarSpan(source: emojiSource, nsRange: NSRange(location: 2, length: 1)))
        XCTAssertThrowsError(try baseOnly.nsRange(in: "Other text")) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .evidenceMismatch)
        }
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

    func testCurrencyGroundingEnforcesExplicitIsoCodesSymbolsAndEnabledProfiles() throws {
        let validator = SmsExtractorValidator()

        let usdConflictSource = "USD 25.00 debited from XX1234."
        let usdConflictRaw = try TestFixtures.strictPostedOutput(
            for: usdConflictSource,
            amountText: "USD 25.00",
            amountValue: "25.00",
            currency: "INR",
            directionText: "debited",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: usdConflictRaw,
                source: usdConflictSource,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .currencyInvalid)
        }

        let euroSource = "€25.00 paid on card XX1234."
        let euroValid = try TestFixtures.strictPostedOutput(
            for: euroSource,
            amountText: "€25.00",
            amountValue: "25.00",
            currency: "EUR",
            directionText: "paid",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        let euroResult = try validator.validate(
            rawOutput: euroValid,
            source: euroSource,
            primaryCurrency: "INR",
            enabledProfiles: ["core-en"]
        )
        XCTAssertEqual(euroResult.transaction?.currency, "EUR")

        let noMarkerSource = "Paid 25.00 from card XX1234."
        let wrongFallbackRaw = try TestFixtures.strictPostedOutput(
            for: noMarkerSource,
            amountText: "25.00",
            amountValue: "25.00",
            currency: "EUR",
            directionText: "Paid",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: wrongFallbackRaw,
                source: noMarkerSource,
                primaryCurrency: "USD",
                enabledProfiles: ["core-en"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .currencyInvalid)
        }

        let inrMarkerWithoutIndiaProfile = "Rs.25.00 paid from card XX1234."
        let rsAsUsd = try TestFixtures.strictPostedOutput(
            for: inrMarkerWithoutIndiaProfile,
            amountText: "Rs.25.00",
            amountValue: "25.00",
            currency: "USD",
            directionText: "paid",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: nil
        )
        let withoutIndia = try validator.validate(
            rawOutput: rsAsUsd,
            source: inrMarkerWithoutIndiaProfile,
            primaryCurrency: "USD",
            enabledProfiles: ["core-en"]
        )
        XCTAssertEqual(withoutIndia.transaction?.currency, "USD")

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: rsAsUsd,
                source: inrMarkerWithoutIndiaProfile,
                primaryCurrency: "USD",
                enabledProfiles: ["core-en", "india"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .currencyInvalid)
        }
    }

    func testStrictOutputRejectsEnvelopeSizeShapeAndFieldDisagreementErrors() throws {
        let validator = SmsExtractorValidator()
        let source = "INR 10.00 debited from XX1234 at Demo Store."

        let oversized = String(repeating: " ", count: SmsExtractorValidator.rawOutputByteLimit + 1)
        XCTAssertThrowsError(
            try validator.validate(rawOutput: oversized, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .outputTruncated)
        }

        XCTAssertThrowsError(
            try validator.validate(rawOutput: "[]", source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .outputNotObject)
        }

        XCTAssertThrowsError(
            try validator.validate(rawOutput: #"{"decision":1}"#, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .decisionTypeInvalid)
        }

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"none","decision":"abstain"}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .duplicateJSONKey)
        }

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"none"} {}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .extraContent)
        }

        XCTAssertThrowsError(
            try validator.validate(rawOutput: #"{"decision":1e0}"#, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .malformedJSON)
        }

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"posted","direction":null,"account":null,"counterparty":null}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .missingAmount)
        }

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"posted","amount":null,"account":null,"counterparty":null}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .missingDirection)
        }

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"posted","amount":null,"direction":null,"counterparty":null}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .missingAccount)
        }

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"posted","amount":null,"direction":null,"account":null}"#,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .postedFieldSetInvalid)
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
            XCTAssertEqual(error as? SmsExtractorValidationError, .malformedJSON)
        }

        let amountMismatch = try TestFixtures.strictPostedOutput(
            for: source,
            amountText: "INR 10.00",
            amountValue: "11.00",
            directionText: "debited",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: "Demo Store"
        )
        XCTAssertThrowsError(
            try validator.validate(rawOutput: amountMismatch, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .amountValueDisagreement)
        }

        let directionMismatch = try TestFixtures.strictPostedOutput(
            for: source,
            amountText: "INR 10.00",
            amountValue: "10.00",
            direction: "credit",
            directionText: "debited",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: "Demo Store"
        )
        XCTAssertThrowsError(
            try validator.validate(rawOutput: directionMismatch, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .directionInvalid)
        }

        let accountMismatch = try TestFixtures.strictPostedOutput(
            for: source,
            amountText: "INR 10.00",
            amountValue: "10.00",
            directionText: "debited",
            accountReference: "XX9999",
            accountText: "XX1234",
            counterpartyText: "Demo Store"
        )
        XCTAssertThrowsError(
            try validator.validate(rawOutput: accountMismatch, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .accountInvalid)
        }
    }

    func testScalarRangeConvertsEmojiToUtf16WithoutSplitting() throws {
        let source = "A 💳 INR"
        let span = try UnicodeScalarSpan(source: source, startScalar: 2, endScalar: 3, text: "💳")
        XCTAssertEqual(try span.nsRange(in: source), NSRange(location: 2, length: 2))
    }

    func testAccountNormalizationSupportsFrozenVpaGrammarAndRejectsAmbiguousMaskedRefs() throws {
        XCTAssertEqual(SmsExtractorNormalizer.normalizeAccount("ab@1x"), "ab@1x")
        XCTAssertEqual(SmsExtractorNormalizer.normalizeAccount("USER.Name@Bank"), "user.name@bank")
        XCTAssertNil(SmsExtractorNormalizer.normalizeAccount(".a@example.com"))
        XCTAssertNil(SmsExtractorNormalizer.normalizeAccount("XX1234 and XX5678"))

        let vpaSource = "INR 99.00 debited from user.name@synthbank at Cafe."
        let vpaRaw = try TestFixtures.strictPostedOutput(
            for: vpaSource,
            amountText: "INR 99.00",
            amountValue: "99.00",
            directionText: "debited",
            accountReference: "user.name@synthbank",
            accountText: "user.name@synthbank",
            counterpartyText: "Cafe"
        )
        let validated = try SmsExtractorValidator().validate(
            rawOutput: vpaRaw,
            source: vpaSource,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(validated.transaction?.accountReference, "user.name@synthbank")
    }

    func testExactMoneyRejectsCoercionAndHonorsInt64Boundary() throws {
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "01.00", currency: "INR"))
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "+1.00", currency: "INR"))
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "1.001", currency: "INR"))
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "0.00", currency: "INR"))
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
