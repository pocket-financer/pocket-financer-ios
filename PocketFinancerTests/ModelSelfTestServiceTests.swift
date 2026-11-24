import XCTest

@testable import PocketFinancer

@MainActor
final class ModelSelfTestServiceTests: XCTestCase {
    func testGroundedExtractorPassesThroughRealCoordinatorAndKeepsLedgerEmpty() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_785_955_200.125)

        let result = await ModelSelfTestService.run(
            extractor: GroundedSelfTestExtractor(),
            extractorEligibilityOverride: true,
            receivedAt: receivedAt
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.contractVersion, "pocketfinancer.sms-extractor-input/1")
        XCTAssertEqual(result.generationMode, "DIRECT_NON_THINKING")
        XCTAssertEqual(result.outputCompletion, "complete")
        XCTAssertEqual(result.syntheticBody, ModelSelfTestService.syntheticBody)
        XCTAssertEqual(result.syntheticSender, ModelSelfTestService.syntheticSender)
        XCTAssertEqual(result.receivedAt, receivedAt)
        XCTAssertEqual(result.settlement, "retained_for_review")
        XCTAssertNil(result.failure)
        XCTAssertNotNil(result.analysisJSON)
        XCTAssertTrue(result.exactRequest.contains("sms-extractor-input/1"))
        XCTAssertTrue(result.exactOutput?.contains(#""decision":"posted""#) == true)
        XCTAssertGreaterThanOrEqual(result.completedAt, result.startedAt)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
        XCTAssertEqual(result.apiLimitations, ModelSelfTestService.apiLimitations)
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("token") })
        XCTAssertTrue(result.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("reasoning") })
    }

    func testUnavailableExtractorFailsClosedAndKeepsLedgerEmpty() async {
        let result = await ModelSelfTestService.run(
            extractor: FailingSelfTestExtractor(),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.settlement, "retained_for_review")
        XCTAssertEqual(result.outputCompletion, "failed")
        XCTAssertNil(result.exactOutput)
        XCTAssertEqual(result.failure?.safeCode, "model_modelNotReady")
        XCTAssertEqual(result.failure?.isRetryable, true)
        XCTAssertTrue(result.summary.localizedCaseInsensitiveContains("did not produce"))
    }

    func testMismatchedEvidenceOutputFailsClosed() async {
        let mismatchedEvidence = await ModelSelfTestService.run(
            extractor: MismatchedEvidenceSelfTestExtractor(),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(mismatchedEvidence.passed)
        XCTAssertEqual(mismatchedEvidence.settlement, "retained_for_review")
        XCTAssertEqual(mismatchedEvidence.failure?.safeCode, "extractor_evidence_mismatch")
        XCTAssertEqual(mismatchedEvidence.failure?.isRetryable, false)

        let invalidReference = await ModelSelfTestService.run(
            extractor: InvalidAccountReferenceSelfTestExtractor(),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )

        XCTAssertFalse(invalidReference.passed)
        XCTAssertEqual(invalidReference.settlement, "retained_for_review")
        XCTAssertEqual(invalidReference.failure?.safeCode, "extractor_account_reference_invalid")
        XCTAssertEqual(invalidReference.failure?.isRetryable, false)
    }
}

private struct GroundedSelfTestExtractor: FoundationSmsExtracting {
    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        let rawOutput = try strictPostedOutput()
        return DirectSelectorResponse(
            rawOutput: rawOutput,
            runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
            requestJSON: requestJSON,
            completion: "complete"
        )
    }
}

private struct FailingSelfTestExtractor: FoundationSmsExtracting {
    func extract(requestJSON _: String) async throws -> DirectSelectorResponse {
        throw TransactionParserError.modelUnavailable(.modelNotReady)
    }
}

private struct MismatchedEvidenceSelfTestExtractor: FoundationSmsExtracting {
    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((try strictPostedOutput()).utf8))
                as? [String: Any]
        )
        var account = try XCTUnwrap(document["account"] as? [String: Any])
        var evidence = try XCTUnwrap(account["evidence"] as? [String: Any])
        evidence["text"] = "XX9999"
        account["evidence"] = evidence
        document["account"] = account
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return DirectSelectorResponse(
            rawOutput: String(decoding: data, as: UTF8.self),
            runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
            requestJSON: requestJSON,
            completion: "complete"
        )
    }
}

private struct InvalidAccountReferenceSelfTestExtractor: FoundationSmsExtracting {
    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((try strictPostedOutput()).utf8))
                as? [String: Any]
        )
        var account = try XCTUnwrap(document["account"] as? [String: Any])
        account["reference"] = "XX9999"
        document["account"] = account
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return DirectSelectorResponse(
            rawOutput: String(decoding: data, as: UTF8.self),
            runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
            requestJSON: requestJSON,
            completion: "complete"
        )
    }
}

private func strictPostedOutput() throws -> String {
    let source = ModelSelfTestService.syntheticBody
    func field(_ text: String, value: [String: Any]) throws -> [String: Any] {
        let range = try XCTUnwrap(source.range(of: text))
        let start = source[..<range.lowerBound].unicodeScalars.count
        let end = start + source[range].unicodeScalars.count
        return value.merging([
            "evidence": ["start_scalar": start, "end_scalar": end, "text": text]
        ]) { current, _ in current }
    }
    let document: [String: Any] = [
        "decision": "posted",
        "amount": try field("INR 500.00", value: ["value": "500.00", "currency": "INR"]),
        "direction": try field("paid", value: ["value": "debit"]),
        "account": try field("XXXXXX0000", value: ["reference": "XXXXXX0000"]),
        "counterparty": try field("Demo Store", value: ["value": "Demo Store"]),
    ]
    let data = try JSONSerialization.data(
        withJSONObject: document,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
}
