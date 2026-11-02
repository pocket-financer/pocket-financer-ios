import XCTest

@testable import PocketFinancer

final class SmsExtractorValidatorTests: XCTestCase {
    func testSanitizedExtractorVectorsMatchFrozenExpectedSemantics() throws {
        let bundleURL = try XCTUnwrap(Bundle.main.url(forResource: "NativeSmsV4", withExtension: "bundle"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "sanitized-vectors", withExtension: "json",
                subdirectory: "tests/sms_processing/golden/extractor-v1"
            ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let validator = SmsExtractorValidator()

        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let source = try XCTUnwrap(vector["sms_body"] as? String)
            let output = try JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["model_output"]))
            let raw = String(decoding: output, as: UTF8.self)
            if let reason = vector["expected_reason"] as? String {
                XCTAssertThrowsError(try validator.validate(rawOutput: raw, source: source, primaryCurrency: "INR"), id)
                {
                    XCTAssertEqual(($0 as? SmsExtractorValidationError)?.reasonCode, reason)
                }
                continue
            }
            let result = try validator.validate(rawOutput: raw, source: source, primaryCurrency: "INR")
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
                XCTAssertEqual(transaction.accountReference, expected["account_reference"] as? String, id)
                XCTAssertEqual(transaction.counterparty, expected["counterparty"] as? String, id)
            }
        }
    }

    func testStrictOutputRejectsDuplicateKeyTrailingDocumentExponentAndDecimalNumbers() throws {
        let validator = SmsExtractorValidator()
        let source = "INR 10.00 debited from XX1234"
        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"none","decision":"abstain"}"#, source: source, primaryCurrency: "INR")
        ) {
            XCTAssertEqual(($0 as? SmsExtractorValidationError)?.reasonCode, "extractor_duplicate_json_key")
        }
        XCTAssertThrowsError(
            try validator.validate(rawOutput: #"{"decision":"none"} {}"#, source: source, primaryCurrency: "INR")
        ) {
            XCTAssertEqual(($0 as? SmsExtractorValidationError)?.reasonCode, "extractor_extra_content")
        }
        XCTAssertThrowsError(
            try validator.validate(rawOutput: #"{"decision":1e0}"#, source: source, primaryCurrency: "INR")
        ) {
            XCTAssertEqual(($0 as? SmsExtractorValidationError)?.reasonCode, "extractor_malformed_json")
        }
        let decimalScalar =
            #"{"decision":"posted","amount":{"value":"10.00","currency":"INR","evidence":{"start_scalar":0.0,"end_scalar":9,"text":"INR 10.00"}},"direction":{"value":"debit","evidence":{"start_scalar":10,"end_scalar":17,"text":"debited"}},"account":{"reference":"XX1234","evidence":{"start_scalar":23,"end_scalar":29,"text":"XX1234"}},"counterparty":null}"#
        XCTAssertThrowsError(try validator.validate(rawOutput: decimalScalar, source: source, primaryCurrency: "INR")) {
            XCTAssertEqual(($0 as? SmsExtractorValidationError)?.reasonCode, "extractor_malformed_json")
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
        XCTAssertThrowsError(try SmsExtractorNormalizer.minorUnits(decimal: "92233720368547758.08", currency: "INR"))
        XCTAssertEqual(
            try SmsExtractorNormalizer.minorUnits(
                decimal: "92233720368547758.07", currency: "INR"
            ),
            Int64.max
        )
    }

    func testCounterpartyUsesCasefoldAndScalarLengthLimit() {
        XCTAssertEqual(SmsExtractorNormalizer.normalizeCounterparty("Straße"), "strasse")
        XCTAssertEqual(SmsExtractorNormalizer.normalizeCounterparty("ΟΣ"), "οσ")
        XCTAssertNil(SmsExtractorNormalizer.normalizeCounterparty(String(repeating: "a\u{0338}", count: 129)))
    }
}
