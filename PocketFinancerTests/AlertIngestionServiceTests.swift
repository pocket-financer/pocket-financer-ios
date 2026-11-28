import Darwin
import Foundation
import SwiftData
import XCTest

@testable import PocketFinancer

private actor IngestionSelectorProbe {
    private(set) var callCount = 0
    private(set) var started = false

    func recordCall() {
        callCount += 1
        started = true
    }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !started {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private struct GroundedIngestionExtractor: FoundationSmsExtracting {
    let probe: IngestionSelectorProbe?

    init(probe: IngestionSelectorProbe? = nil) {
        self.probe = probe
    }

    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        await probe?.recordCall()
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]
        )
        let source = try XCTUnwrap(request["message"] as? String)
        let document: [String: Any]
        if source.contains("OTP") || source.contains("statement summary") {
            document = ["decision": "none"]
        } else {
            document = [
                "decision": "posted",
                "amount": try field(
                    source: source,
                    alternatives: ["Rs.500.00", "INR 500.00"],
                    value: ["value": "500.00", "currency": "INR"]
                ),
                "direction": try field(
                    source: source,
                    alternatives: ["debited"],
                    value: ["value": "debit"]
                ),
                "account": try field(
                    source: source,
                    alternatives: ["XXXXXX0000", "**0000"],
                    value: ["reference": source.contains("XXXXXX0000") ? "XXXXXX0000" : "**0000"]
                ),
                "counterparty": try field(
                    source: source,
                    alternatives: ["Demo Store"],
                    value: ["value": "Demo Store"]
                ),
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return DirectSelectorResponse(
            rawOutput: String(decoding: data, as: UTF8.self),
            runtimeProfileJSON: #"{"generation_mode":"DIRECT_NON_THINKING"}"#,
            requestJSON: requestJSON,
            completion: "complete"
        )
    }

    private func field(
        source: String,
        alternatives: [String],
        value: [String: Any]
    ) throws -> [String: Any] {
        for text in alternatives {
            if let range = source.range(of: text) {
                let start = source[..<range.lowerBound].unicodeScalars.count
                let end = start + source[range].unicodeScalars.count
                return value.merging([
                    "evidence": [
                        "start_scalar": start,
                        "end_scalar": end,
                        "text": String(source[range]),
                    ]
                ]) { current, _ in current }
            }
        }
        throw TransactionParserError.generationFailed
    }
}

private struct CancellingIngestionExtractor: FoundationSmsExtracting {
    let probe: IngestionSelectorProbe

    func extract(requestJSON _: String) async throws -> DirectSelectorResponse {
        await probe.recordCall()
        try await Task.sleep(for: .seconds(30))
        throw TransactionParserError.generationFailed
    }
}

@MainActor
final class AlertIngestionServiceTests: XCTestCase {
    func testEnqueueDurablyAdmitsEvidenceWithoutStartingSelector() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe)
        )

        let receipt = try service.enqueue(
            body: TestFixtures.validBody,
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .queued)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.rawBody, TestFixtures.validBody)
        XCTAssertEqual(alert.status, .pending)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsSourceMetadataEvent>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testIngestAutoSavesForConfirmedAccountAndRoutesFiveMinuteDuplicateToReview() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let account = Account(
            name: "HDFC Checking",
            bank: "HDFC Bank",
            kind: .account,
            suffix: "0000",
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:0000"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        try context.save()

        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )

        let first = try await service.ingest(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(first.disposition, .imported)

        let withinFiveMinutes = try await service.ingest(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(120),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(withinFiveMinutes.disposition, .needsReview)

        let outsideFiveMinutes = try await service.ingest(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(301),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(outsideFiveMinutes.disposition, .imported)

        let verification = ModelContext(database.container)
        let transactions = try verification.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(transactions.count, 2)
        XCTAssertTrue(transactions.allSatisfy { $0.accountID == account.id })
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
    }

    func testGroundedProcessingCreatesReviewTraceAndConfirmReplaysIdempotently() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )

        let receipt = try await service.ingest(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .needsReview)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxAlert>()).first?.status, .needsReview)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsProcessingAnalysis>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsSelectorAttempt>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
        XCTAssertFalse(try context.fetch(FetchDescriptor<SmsProcessingTraceEvent>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)

        let review = try XCTUnwrap(context.fetch(FetchDescriptor<SmsReviewCase>()).first)
        let command = ReviewCommand(
            actionID: UUID(),
            reviewCaseID: review.id,
            expectedRevision: review.revision,
            kind: .confirm,
            corrections: [],
            retryConfiguration: nil
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let confirmation = try await store.resolveReview(
            command,
            now: TestFixtures.receivedAt.addingTimeInterval(1)
        )
        let replay = try await store.resolveReview(
            command,
            now: TestFixtures.receivedAt.addingTimeInterval(2)
        )

        XCTAssertFalse(confirmation.replayed)
        XCTAssertTrue(replay.replayed)
        let mismatchedReplay = ReviewCommand(
            actionID: command.actionID,
            reviewCaseID: UUID(),
            expectedRevision: command.expectedRevision,
            kind: command.kind,
            corrections: command.corrections,
            retryConfiguration: command.retryConfiguration
        )
        await TestFixtures.assertThrowsErrorAsync {
            _ = try await store.resolveReview(
                mismatchedReplay,
                now: TestFixtures.receivedAt.addingTimeInterval(3)
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .invalidCommand)
        }

        let verification = ModelContext(database.container)
        let transaction = try XCTUnwrap(verification.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(transaction.occurredAt, TestFixtures.receivedAt)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsAccountAlias>()).count, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsTransactionRevision>()).count, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsUserFeedbackEvent>()).count, 1)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsReviewCase>()).first?.state,
            .confirmed
        )
    }

    func testStandaloneOtpIsTombstonedByPrefilterWithoutInvokingExtractor() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )

        let receipt = try await service.ingest(
            body: "Your OTP is 123456. Do not share it with anyone.",
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .rejected)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .rejected)
        XCTAssertEqual(alert.rejectionCode, "tombstoned_excluded")
        XCTAssertEqual(alert.lastErrorCode, "prefilter_otp_verification")
        XCTAssertTrue(alert.rawBody.isEmpty)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsSelectorAttempt>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first)
        XCTAssertEqual(operation.retentionState, "tombstoned_excluded")

        let retryErased = try await service.retry(alertID: alert.id)
        XCTAssertEqual(retryErased.disposition, .rejected)
    }

    func testNonTransactionCardAlertIsTombstonedByExtractorNone() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )

        let receipt = try await service.ingest(
            body: "Your card statement summary for INR 100.00 is ready to view.",
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .rejected)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.status, .rejected)
        XCTAssertEqual(alert.rejectionCode, "tombstoned_none")
        XCTAssertEqual(alert.lastErrorCode, "extractor_none")
        XCTAssertTrue(alert.rawBody.isEmpty)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsSelectorAttempt>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first)
        XCTAssertEqual(operation.retentionState, "tombstoned_none")
    }

    func testExactSourceIdentityDeduplicatesIdempotentlyAndDistinctAlertsEnterPrefilterPipeline() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )

        let first = try service.enqueue(
            body: "HDFC Bank:\nRs.500.00 debited from a/c XXXXXX0000.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let exactReplay = try service.enqueue(
            body: "HDFC Bank:\nRs.500.00 debited from a/c XXXXXX0000.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(first.disposition, .queued)
        XCTAssertEqual(exactReplay.alertID, first.alertID)
        XCTAssertEqual(exactReplay.disposition, .queued)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxAlert>()).count, 1)

        // Two distinct OTP alerts 2 seconds apart must both pass through prefilter into tombstones
        // rather than getting trapped in Needs Review by a pre-prefilter heuristic (PAR-11).
        let firstOTP = try await service.ingest(
            body: "Your OTP is 123456. Do not share it.",
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let secondOTP = try await service.ingest(
            body: "Your OTP is 123456. Do not share it.",
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(2),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(firstOTP.disposition, .rejected)
        XCTAssertEqual(secondOTP.disposition, .rejected)
        XCTAssertNotEqual(firstOTP.alertID, secondOTP.alertID)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testTombstonedReplaySuppressesDuplicateAdmissionAndModelWork() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )

        let otpBody = "Your OTP is 654321. Do not share it."
        let firstOTP = try await service.ingest(
            body: otpBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let replayOTP = try await service.ingest(
            body: otpBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(firstOTP.disposition, .rejected)
        XCTAssertEqual(replayOTP.alertID, firstOTP.alertID)
        XCTAssertEqual(replayOTP.disposition, .rejected)

        let statementBody = "Your card statement summary for INR 100.00 is ready."
        let firstNone = try await service.ingest(
            body: statementBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(30),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let replayNone = try await service.ingest(
            body: statementBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(30),
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(firstNone.disposition, .rejected)
        XCTAssertEqual(replayNone.alertID, firstNone.alertID)
        XCTAssertEqual(replayNone.disposition, .rejected)

        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxAlert>()).count, 2)
    }

    func testMissingConfirmedCurrencyLeavesAlertQueuedWithoutOperation() async throws {
        let restore = TestFixtures.usePrimaryCurrency(nil)
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )

        let receipt = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        XCTAssertEqual(receipt.disposition, .queued)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alert.lastErrorCode, "configuration_primary_currency_required")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
    }

    func testCancellationCannotWriteLedgerAndRetainsDurableEvidence() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: CancellingIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        _ = try service.enqueue(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )

        let task = Task { await service.processPending() }
        let didStart = await probe.waitUntilStarted()
        XCTAssertTrue(didStart)
        task.cancel()
        _ = await task.value

        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertFalse(alert.rawBody.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
    }

    func testRetryCreatesLinkedOperationReusesReviewCaseAndValidatesInputs() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )

        await TestFixtures.assertThrowsErrorAsync {
            _ = try await service.retry(alertID: UUID())
        } verify: { error in
            XCTAssertEqual(error as? AlertIngestionError, .alertNotFound)
        }
        await TestFixtures.assertThrowsErrorAsync {
            _ = try await service.retry(alertID: UUID(), configurationMode: "unexpected")
        } verify: { error in
            XCTAssertEqual(error as? AlertIngestionError, .persistenceFailed)
        }

        let first = try await service.ingest(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let originalOperation = try XCTUnwrap(
            context.fetch(FetchDescriptor<SmsProcessingOperation>()).first
        )
        let originalReview = try XCTUnwrap(context.fetch(FetchDescriptor<SmsReviewCase>()).first)

        let retried = try await service.retry(
            alertID: first.alertID,
            parentOperationID: originalOperation.id,
            configurationMode: "original"
        )

        XCTAssertEqual(retried.disposition, .needsReview)
        let operations = try context.fetch(FetchDescriptor<SmsProcessingOperation>())
        XCTAssertEqual(operations.count, 2)
        let retryOperation = try XCTUnwrap(operations.first { $0.id != originalOperation.id })
        XCTAssertEqual(retryOperation.parentOperationID, originalOperation.id)
        let reviews = try context.fetch(FetchDescriptor<SmsReviewCase>())
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews.first?.id, originalReview.id)
        XCTAssertEqual(reviews.first?.currentOperationID, retryOperation.id)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }

    func testOriginalRetryNeverSilentlyUpgradesFrozenV1Operation() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )
        let first = try await service.ingest(
            body: TestFixtures.validBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let original = try XCTUnwrap(
            context.fetch(FetchDescriptor<SmsProcessingOperation>()).first
        )
        var configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(original.configurationJSON.utf8))
                as? [String: Any]
        )
        configuration["contract"] = "pocketfinancer.processing-config/1"
        original.configurationJSON = try SmsProcessingJSON.canonical(configuration)
        original.contractReleaseID = "frozen-v1-test"
        try context.save()

        let retried = try await service.retry(
            alertID: first.alertID,
            parentOperationID: original.id,
            configurationMode: "original"
        )

        XCTAssertEqual(retried.disposition, .needsReview)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InboxAlert>()).first?.lastErrorCode,
            "original_configuration_adapter_unavailable"
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 1)
        XCTAssertEqual(original.contractReleaseID, "frozen-v1-test")
    }

    func testAutomaticAttemptLimitStopsBeforeCreatingOperation() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )
        let receipt = try service.enqueue(
            body: TestFixtures.validBody,
            sender: "BANK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        alert.attemptCount = AlertIngestionService.automaticAttemptLimit
        try context.save()

        let processed = await service.processPending()
        XCTAssertEqual(processed, 0)
        XCTAssertEqual(alert.status, .needsReview)
        XCTAssertEqual(alert.lastErrorCode, "automatic_retry_limit_reached")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
        XCTAssertEqual(receipt.alertID, alert.id)
    }

    func testOversizedBodySenderAndSourceApplicationAreRejectedBeforeAdmission() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )

        let oversizedCases: [(body: String, sender: String?, sourceApp: String?)] = [
            (
                String(repeating: "x", count: AlertIngestionService.maximumBodyBytes + 1),
                "BANK",
                "Messages"
            ),
            (
                TestFixtures.validBody,
                String(repeating: "s", count: AlertIngestionService.maximumSenderBytes + 1),
                "Messages"
            ),
            (
                TestFixtures.validBody,
                "BANK",
                String(repeating: "a", count: AlertIngestionService.maximumSourceApplicationBytes + 1)
            ),
        ]
        for testCase in oversizedCases {
            XCTAssertThrowsError(
                try service.enqueue(
                    body: testCase.body,
                    sender: testCase.sender,
                    receivedAt: TestFixtures.receivedAt,
                    sourceApplication: testCase.sourceApp,
                    origin: .shortcut
                )
            ) { error in
                XCTAssertEqual(error as? AlertIngestionError, .inputTooLarge)
            }
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
    }

    func testPendingRecoveryReusesSettledReviewBeforeSettingsAndAttemptLimit() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        _ = await service.processPending()
        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first)
        let configuration = operation.configurationJSON
        let reviewID = try XCTUnwrap(context.fetch(FetchDescriptor<SmsReviewCase>()).first?.id)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        alert.status = .processing
        alert.attemptCount = AlertIngestionService.automaticAttemptLimit
        try context.save()
        let restoreMissingCurrency = TestFixtures.usePrimaryCurrency(nil)
        defer { restoreMissingCurrency() }

        _ = await AlertIngestionService(
            context: ModelContext(database.container),
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        ).processPending()

        let fresh = ModelContext(database.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 1)
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).first?.configurationJSON,
            configuration
        )
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).map(\.id), [reviewID])
        let recovered = try XCTUnwrap(fresh.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(recovered.id, queued.alertID)
        XCTAssertEqual(recovered.status, .needsReview)
        XCTAssertEqual(recovered.attemptCount, AlertIngestionService.automaticAttemptLimit)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
    }

    func testReadyRecoveryDefersFrozenWorkAndOnlyOwnerRetryCreatesChild() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: queued.alertID,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true
        )
        PrimaryCurrencySettings.confirm("USD")

        _ = await service.processPending()

        let parent = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first)
        XCTAssertEqual(parent.id, snapshot.operationID)
        XCTAssertEqual(parent.state, .ready)
        XCTAssertNil(parent.ownerToken)
        XCTAssertNil(parent.settledAt)
        XCTAssertEqual(parent.configurationJSON, snapshot.configurationJSON)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InboxAlert>()).first?.lastErrorCode,
            "saved_operation_requires_explicit_retry"
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        let replayCalls = await probe.callCount
        XCTAssertEqual(replayCalls, 0)

        let retried = try await service.retry(alertID: queued.alertID)

        XCTAssertEqual(retried.disposition, .needsReview)
        let fresh = ModelContext(database.container)
        let operations = try fresh.fetch(FetchDescriptor<SmsProcessingOperation>())
        XCTAssertEqual(operations.count, 2)
        let child = try XCTUnwrap(operations.first { $0.parentOperationID == parent.id })
        XCTAssertEqual(child.stableEventID, parent.stableEventID)
        XCTAssertEqual(parent.configurationJSON, snapshot.configurationJSON)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(child.configurationJSON.utf8)) as? [String: Any]
        )
        let currency = try XCTUnwrap(document["currency_context"] as? [String: Any])
        XCTAssertEqual(currency["primary_currency"] as? String, "USD")
        let store = SmsProcessingStore(modelContainer: database.container)
        _ = try await store.recoverExpiredOperations(now: .now.addingTimeInterval(300))
        XCTAssertEqual(try ModelContext(database.container).fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
    }

    func testLiveDurableClaimBlocksRecoveryAndOwnerRetryAcrossContexts() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: queued.alertID,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let claim = try await store.claim(operationID: snapshot.operationID)

        let completed = await service.processPending()
        let receipt = try await service.retry(alertID: queued.alertID)

        XCTAssertEqual(completed, 0)
        XCTAssertEqual(receipt.disposition, .alreadyProcessing)
        let fresh = ModelContext(database.container)
        let operations = try fresh.fetch(FetchDescriptor<SmsProcessingOperation>())
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?.ownerToken, claim.ownerToken)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<InboxAlert>()).first?.attemptCount, 0)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testExpiredWorkUsesExistingRecoveryWithoutAnotherExtraction() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: queued.alertID,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        _ = try await store.claim(operationID: snapshot.operationID, now: .now.addingTimeInterval(-300))

        _ = await service.processPending()
        let beforeRecovery = try await service.retry(alertID: queued.alertID)
        XCTAssertEqual(beforeRecovery.disposition, .processingIncomplete)
        let recoveredIDs = try await store.recoverExpiredOperations()
        XCTAssertEqual(recoveredIDs.count, 1)
        let automaticCount = await service.processPending()
        XCTAssertEqual(automaticCount, 0)

        let fresh = ModelContext(database.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).map(\.id), recoveredIDs)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<InboxAlert>()).first?.status, .needsReview)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<Transaction>()).isEmpty)
        let callsBeforeOwnerRetry = await probe.callCount
        XCTAssertEqual(callsBeforeOwnerRetry, 0)

        let ownerRetryCount = await service.processPending(includeNeedsReview: true)
        XCTAssertEqual(ownerRetryCount, 1)
        let callsAfterOwnerRetry = await probe.callCount
        XCTAssertEqual(callsAfterOwnerRetry, 1)
    }

    func testOwnerRetryWithoutParentLinksLatestReviewAndRetainsOneCase() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        _ = await service.processPending()
        let parent = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first)
        let reviewID = try XCTUnwrap(context.fetch(FetchDescriptor<SmsReviewCase>()).first?.id)

        let automaticDrainCount = await service.processPending()
        XCTAssertEqual(automaticDrainCount, 0)
        let receipt = try await service.retry(alertID: queued.alertID)

        XCTAssertEqual(receipt.disposition, .needsReview)
        let fresh = ModelContext(database.container)
        let child = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).first {
                $0.parentOperationID == parent.id
            }
        )
        XCTAssertEqual(child.stableEventID, parent.stableEventID)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 2)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).map(\.id), [reviewID])
        let calls = await probe.callCount
        XCTAssertEqual(calls, 2)
    }

    func testAdmissionLockIsNonblockingAndReleasedAfterFailure() throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        XCTAssertThrowsError(
            try SmsProcessingStore.withAdmissionLock(container: database.container) { _ in
                try SmsProcessingStore.withAdmissionLock(container: database.container) { _ in }
            }
        ) { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .admissionBusy)
        }
        XCTAssertNoThrow(
            try SmsProcessingStore.withAdmissionLock(container: database.container) { _ in }
        )
    }

    func testFileLockContentionReturnsBusyWithoutCreatingOperationOrReview() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("invented.store")
        let database = try AppDatabase(storeURL: storeURL)
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        let lockURL = storeURL.appendingPathExtension("admission-lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let receipt = try await service.retry(alertID: queued.alertID)

        XCTAssertEqual(receipt.disposition, .alreadyProcessing)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxAlert>()).first?.attemptCount, 0)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testUncommittedEvidenceConflictCannotOverwriteDurableAlertOrStartModel() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        context.autosaveEnabled = false
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        _ = try enqueueAdmissionFixture(service)
        let alert = try XCTUnwrap(context.fetch(FetchDescriptor<InboxAlert>()).first)
        let originalBody = alert.rawBody
        alert.rawBody = "Uncommitted, conflicting invented evidence."
        defer { context.rollback() }

        _ = await service.processPending()

        let fresh = ModelContext(database.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<InboxAlert>()).first?.rawBody, originalBody)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testUnavailableModelOutcomeIsReusedByAutomaticDrainAndRetriedBySettingsRetry() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let unavailable = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: false
        )
        _ = try enqueueAdmissionFixture(unavailable)
        _ = await unavailable.processPending()
        let parentID = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first?.id)
        let available = AlertIngestionService(
            context: ModelContext(database.container),
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )

        let automaticCount = await available.processPending()
        XCTAssertEqual(automaticCount, 0)
        let replayCalls = await probe.callCount
        XCTAssertEqual(replayCalls, 0)
        XCTAssertEqual(
            try ModelContext(database.container).fetch(FetchDescriptor<SmsProcessingOperation>()).count,
            1
        )

        let settingsRetryCount = await available.processPending(includeNeedsReview: true)
        XCTAssertEqual(settingsRetryCount, 1)
        let fresh = ModelContext(database.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 2)
        XCTAssertNotNil(
            try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).first {
                $0.parentOperationID == parentID
            }
        )
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
    }

    func testSettingsRetrySavedAlertsAutoSavesOnceAccountConfirmedAndClosesReviewCase() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(),
            extractorEligibilityOverride: true
        )
        let initial = try await service.ingest(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "AX-HDFCBK",
            receivedAt: TestFixtures.receivedAt,
            sourceApplication: "Messages",
            origin: .shortcut
        )
        XCTAssertEqual(initial.disposition, .needsReview)

        let account = Account(name: "HDFC Checking", bank: "HDFC Bank", kind: .account, suffix: "0000")
        context.insert(account)
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:0000"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        try context.save()

        let retried = await service.processPending(limit: 20, includeNeedsReview: true)
        XCTAssertEqual(retried, 1)
        let secondPass = await service.processPending(limit: 20, includeNeedsReview: true)
        XCTAssertEqual(secondPass, 0)

        let verification = ModelContext(database.container)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Transaction>()).count, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<InboxAlert>()).first?.status, .imported)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsReviewCase>()).first?.state, .confirmed)
    }

    func testProcessingSaveFailureKeepsEvidenceAndCanRecoverWithoutDuplicateOperation() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        var saves = 0
        let service = AlertIngestionService(
            context: context,
            contextSaver: { context in
                saves += 1
                if saves == 2 { throw AlertIngestionError.persistenceFailed }
                try context.save()
            },
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)

        _ = await service.processPending()

        let failed = ModelContext(database.container)
        XCTAssertEqual(try failed.fetch(FetchDescriptor<InboxAlert>()).first?.id, queued.alertID)
        XCTAssertFalse(try XCTUnwrap(failed.fetch(FetchDescriptor<InboxAlert>()).first?.rawBody).isEmpty)
        XCTAssertTrue(try failed.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
        let failedCalls = await probe.callCount
        XCTAssertEqual(failedCalls, 0)
        _ = await service.processPending()
        let fresh = ModelContext(database.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
        let recoveredCalls = await probe.callCount
        XCTAssertEqual(recoveredCalls, 1)
    }

    func testOwnerRetryOfInterruptedUnownedWorkCreatesLinkedChild() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let queued = try enqueueAdmissionFixture(service)
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: queued.alertID,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true
        )
        let parent = try XCTUnwrap(context.fetch(FetchDescriptor<SmsProcessingOperation>()).first)
        parent.state = .interrupted
        try context.save()

        _ = await service.processPending()
        let replayCalls = await probe.callCount
        XCTAssertEqual(replayCalls, 0)
        let receipt = try await service.retry(alertID: queued.alertID)

        XCTAssertEqual(receipt.disposition, .needsReview)
        let fresh = ModelContext(database.container)
        let child = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<SmsProcessingOperation>()).first {
                $0.parentOperationID == snapshot.operationID
            }
        )
        XCTAssertEqual(child.stableEventID, snapshot.stableEventID)
        let store = SmsProcessingStore(modelContainer: database.container)
        _ = try await store.recoverExpiredOperations(now: .now.addingTimeInterval(300))
        XCTAssertEqual(try ModelContext(database.container).fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
    }

    func testOwnerRetryCannotLinkOperationFromAnotherSource() async throws {
        let restore = TestFixtures.usePrimaryCurrency("INR")
        defer { restore() }
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let probe = IngestionSelectorProbe()
        let service = AlertIngestionService(
            context: context,
            smsExtractor: GroundedIngestionExtractor(probe: probe),
            extractorEligibilityOverride: true
        )
        let first = try enqueueAdmissionFixture(service, receivedAt: TestFixtures.receivedAt)
        let second = try enqueueAdmissionFixture(
            service,
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(60)
        )
        XCTAssertNotEqual(first.alertID, second.alertID)
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: first.alertID,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true
        )

        let receipt = try await service.retry(
            alertID: second.alertID,
            parentOperationID: snapshot.operationID
        )

        XCTAssertEqual(receipt.disposition, .processingIncomplete)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InboxAlert>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 0)
    }

    func testIngestionReceiptSafeDialogCoversEveryDispositionWithoutLeakingEvidence() {
        let dispositions: [IngestionDisposition] = [
            .imported,
            .queued,
            .alreadyProcessing,
            .processingIncomplete,
            .needsReview,
            .rejected,
            .duplicate,
        ]
        for disposition in dispositions {
            let dialog = IngestionReceipt(alertID: UUID(), disposition: disposition).safeDialog
            XCTAssertFalse(dialog.isEmpty, disposition.rawValue)
            XCTAssertFalse(dialog.contains("Rs.500"))
        }
    }

    private func enqueueAdmissionFixture(
        _ service: AlertIngestionService,
        receivedAt: Date = TestFixtures.receivedAt
    ) throws -> IngestionReceipt {
        try service.enqueue(
            body: "INR 500.00 was debited from account **0000 at Demo Store.",
            sender: "INVENTED",
            receivedAt: receivedAt,
            sourceApplication: "Invented connector",
            origin: .manual
        )
    }
}
