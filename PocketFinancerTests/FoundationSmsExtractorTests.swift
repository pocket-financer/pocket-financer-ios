import XCTest

@testable import PocketFinancer

final class FoundationSmsExtractorTests: XCTestCase {
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
            try SmsExtractorValidator().validate(rawOutput: outOfBoundsRaw, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .evidenceOutOfBounds)
        }

        let invalidValueRaw = try projected(counterpartyStart: 24, counterpartyEnd: 30)
        XCTAssertThrowsError(
            try SmsExtractorValidator().validate(rawOutput: invalidValueRaw, source: source, primaryCurrency: "INR")
        ) { error in
            XCTAssertEqual(error as? SmsExtractorValidationError, .counterpartyInvalid)
        }
    }
}
