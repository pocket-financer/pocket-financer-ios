import Foundation
import XCTest

@testable import PocketFinancer

final class FoundationSmsExtractorTests: XCTestCase {
    func testFlatExtractionEncodingMatchesRequiredAppleFlatSchemaKeys() throws {
        let flat = FlatSmsExtraction(
            decision: "posted",
            amountValue: "500.00",
            amountCurrency: "INR",
            amountStart: 0,
            amountEnd: 10,
            amountText: "INR 500.00",
            directionValue: "debit",
            directionStart: 11,
            directionEnd: 18,
            directionText: "debited",
            accountReference: "XX1234",
            accountStart: 24,
            accountEnd: 30,
            accountText: "XX1234",
            counterpartyValue: "Demo Store",
            counterpartyStart: 34,
            counterpartyEnd: 44,
            counterpartyText: "Demo Store"
        )
        let encoded = try JSONEncoder().encode(flat)
        let decoded = try JSONDecoder().decode(FlatSmsExtraction.self, from: encoded)
        XCTAssertEqual(decoded, flat)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let schema = try SmsContractAssets.appleFlatSchema()
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(Set(object.keys), Set(required))
    }

    func testInstructionsLoadVerifiedAppleFoundationModelsPrompt() throws {
        let instructions = try FoundationSmsExtractor.instructions()

        XCTAssertTrue(instructions.contains("pocketfinancer.apple-fm-extractor-prompt/1"))
        XCTAssertTrue(instructions.contains(#""posted""#))
    }

    func testNonPostedProjectionProducesCanonicalDocumentOrFailsClosedOnExtraFields() throws {
        XCTAssertEqual(
            try FoundationSmsExtractor.projectFlatExtraction(FlatSmsExtraction(decision: "none")),
            #"{"decision":"none"}"#
        )
        XCTAssertEqual(
            try FoundationSmsExtractor.projectFlatExtraction(FlatSmsExtraction(decision: "abstain")),
            #"{"decision":"abstain"}"#
        )

        XCTAssertThrowsError(
            try FoundationSmsExtractor.projectFlatExtraction(
                FlatSmsExtraction(decision: "none", amountValue: "100.00")
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .nonPostedExtraFields)
        }

        XCTAssertThrowsError(
            try FoundationSmsExtractor.projectFlatExtraction(
                FlatSmsExtraction(decision: "abstain", amountStart: 1)
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .nonPostedExtraFields)
        }

        XCTAssertThrowsError(
            try FoundationSmsExtractor.projectFlatExtraction(
                FlatSmsExtraction(decision: "posted_extra")
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .unknownDecision)
        }
    }

    func testPostedFlatProjectionMatchesValidatorWithAndWithoutCounterparty() throws {
        let source = "HDFC Bank: Rs.500.00 debited from a/c XXXXXX0000 at Demo Store."
        let withCounterparty = try TestFixtures.strictPostedOutput(for: source)
        let validated = try SmsExtractorValidator().validate(
            rawOutput: withCounterparty,
            source: source,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(validated.decision, .posted)
        XCTAssertEqual(validated.transaction?.minorUnits, 50_000)
        XCTAssertEqual(validated.transaction?.currency, "INR")
        XCTAssertEqual(validated.transaction?.direction, .debit)
        XCTAssertEqual(validated.transaction?.accountReference, "0000")
        XCTAssertEqual(validated.transaction?.counterparty, "demo store")

        let withoutCounterparty = try TestFixtures.strictPostedOutput(
            for: source,
            counterpartyText: nil
        )
        XCTAssertTrue(withoutCounterparty.contains(#""counterparty":null"#))
        let validatedNull = try SmsExtractorValidator().validate(
            rawOutput: withoutCounterparty,
            source: source,
            primaryCurrency: "INR"
        )
        XCTAssertEqual(validatedNull.decision, .posted)
        XCTAssertNil(validatedNull.transaction?.counterparty)
    }

    func testPartialCounterpartyFailsValidatorAsCounterpartyInvalid() throws {
        let source = "INR 500.00 debited from XX0000."
        func projected(counterpartyStart: Int, counterpartyEnd: Int) throws -> String {
            try FoundationSmsExtractor.projectFlatExtraction(
                FlatSmsExtraction(
                    decision: "posted",
                    amountValue: "500.00",
                    amountCurrency: "INR",
                    amountStart: 0,
                    amountEnd: 10,
                    amountText: "INR 500.00",
                    directionValue: "debit",
                    directionStart: 11,
                    directionEnd: 18,
                    directionText: "debited",
                    accountReference: "XX0000",
                    accountStart: 24,
                    accountEnd: 30,
                    accountText: "XX0000",
                    counterpartyValue: "",
                    counterpartyStart: counterpartyStart,
                    counterpartyEnd: counterpartyEnd,
                    counterpartyText: "XX0000"
                )
            )
        }

        let outOfBoundsRaw = try projected(counterpartyStart: 0, counterpartyEnd: 0)
        XCTAssertThrowsError(
            try SmsExtractorValidator().validate(
                rawOutput: outOfBoundsRaw,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .evidenceOutOfBounds)
        }

        let invalidValueRaw = try projected(counterpartyStart: 24, counterpartyEnd: 30)
        XCTAssertThrowsError(
            try SmsExtractorValidator().validate(
                rawOutput: invalidValueRaw,
                source: source,
                primaryCurrency: "INR"
            )
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .counterpartyInvalid)
        }
    }

    func testParserAndValidationErrorsExposeDistinctSafeCodesAndRetryability() {
        let retryable: [(TransactionParserError, String)] = [
            (.modelUnavailable(.appleIntelligenceNotEnabled), "model_appleIntelligenceNotEnabled"),
            (.modelUnavailable(.modelNotReady), "model_modelNotReady"),
            (.modelUnavailable(.unknown), "model_unknown"),
            (.timedOut, "model_timed_out"),
            (.cancelled, "model_cancelled"),
            (.assetsUnavailable, "model_assets_unavailable"),
            (.rateLimited, "model_rate_limited"),
            (.concurrentRequests, "model_concurrent_requests"),
        ]
        for (error, code) in retryable {
            XCTAssertTrue(error.isRetryable, code)
            XCTAssertEqual(error.safeCode, code)
        }

        let nonRetryable: [(TransactionParserError, String)] = [
            (.modelUnavailable(.deviceNotEligible), "model_deviceNotEligible"),
            (.unsupportedLanguageOrLocale, "model_unsupported_language"),
            (.guardrailViolation, "model_guardrail_violation"),
            (.unsupportedGuide, "model_unsupported_guide"),
            (.decodingFailure, "model_decoding_failed"),
            (.modelRefused, "model_refused"),
            (.contextWindowExceeded, "model_context_window_exceeded"),
            (.generationFailed, "model_generation_failed"),
        ]
        for (error, code) in nonRetryable {
            XCTAssertFalse(error.isRetryable, code)
            XCTAssertEqual(error.safeCode, code)
        }

        let allValidationErrors: [SmsExtractorValidationError] = [
            .malformedJSON,
            .duplicateJSONKey,
            .extraContent,
            .outputNotObject,
            .decisionTypeInvalid,
            .unknownDecision,
            .nonPostedExtraFields,
            .missingAmount,
            .missingDirection,
            .missingAccount,
            .postedFieldSetInvalid,
            .amountInvalid,
            .currencyInvalid,
            .directionInvalid,
            .accountInvalid,
            .counterpartyInvalid,
            .evidenceInvalid,
            .evidenceOutOfBounds,
            .evidenceMismatch,
            .amountValueDisagreement,
            .outputTruncated,
        ]
        let codes = allValidationErrors.map(\.reasonCode)
        XCTAssertEqual(Set(codes).count, allValidationErrors.count)
    }
}
