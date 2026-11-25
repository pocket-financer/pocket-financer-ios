import Foundation
import SwiftData
import XCTest

@testable import PocketFinancer

private struct CoordinatorReviewCase {
    let label: String
    let eligible: Bool
    let extractor: any FoundationSmsExtracting
    let resolver: @MainActor @Sendable (String?) throws -> SmsAccountResolution
    let expectedReason: String
}

private actor RecordingProcessingObserver: SmsProcessingObserver {
    private(set) var events: [SmsProcessingObserverEvent] = []

    func didReceive(_ event: SmsProcessingObserverEvent) async {
        events.append(event)
    }
}

@MainActor
final class SmsProcessingCoordinatorTests: XCTestCase {
    func testAutoSavesPostedExtractionWithResolvedAccountReplaysIdempotentlyAndEmitsOrderedTrace() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "HDFC Savings",
            bank: "HDFC Bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        let alert = TestFixtures.makeAlert(body: "INR 10.00 was paid from account **1234 at CAFE")
        context.insert(alert)
        try context.save()
        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let raw = try TestFixtures.strictPostedOutput(
            for: alert.rawBody,
            amountText: "INR 10.00",
            amountValue: "10.00",
            direction: "debit",
            directionText: "paid",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "CAFE"
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let observer = RecordingProcessingObserver()
        let coordinator = SmsProcessingCoordinator(
            store: store,
            extractor: FixedSmsExtractor(rawOutput: raw),
            accountResolver: { _ in .unique(accountID: account.id) }
        )

        let source = AdmittedMessageRef(
            sourceID: alert.id,
            admissionReceiptID: alert.id,
            sourceDigest: CanonicalJSON.sha256(alert.rawBody)
        )
        let outcome = await coordinator.process(
            source: source,
            operation: snapshot,
            observer: observer
        )

        guard case .persisted(_, let transactionIDs, let alreadyCommitted) = outcome else {
            return XCTFail("Expected automatic persistence, got \(outcome)")
        }
        XCTAssertEqual(transactionIDs.count, 1)
        XCTAssertFalse(alreadyCommitted)

        let observedStages = await observer.events.map(\.stage)
        XCTAssertEqual(
            observedStages,
            [
                "claim",
                "prefilter",
                "analysis",
                "triage",
                "selector_execution",
                "selector_execution",
                "selector_validation",
                "account_resolution",
                "reconstruction",
                "persistence_gate",
                "settlement",
            ]
        )

        let replayed = await coordinator.process(source: source, operation: snapshot)
        XCTAssertEqual(
            replayed,
            .persisted(
                operationID: snapshot.operationID,
                transactionIDs: transactionIDs,
                alreadyCommitted: true
            )
        )

        let verification = ModelContext(database.container)
        let transactions = try verification.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.id, transactionIDs.first)
        XCTAssertEqual(transactions.first?.accountID, account.id)
        XCTAssertEqual(transactions.first?.amountMinorUnits, 1_000)
        XCTAssertEqual(transactions.first?.parserName, "pocketfinancer.sms-pipeline/1")
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        let decision = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsPersistenceDecision>()).first
        )
        XCTAssertEqual(decision.resultRawValue, "eligible")
        XCTAssertEqual(decision.primaryReason, "persistence_all_gates_passed")
        XCTAssertEqual(decision.rolloutModeRawValue, "automatic")
    }

    func testFiveMinuteDuplicateWindowRoutesWithinWindowToReviewAndAutoSavesOutside() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "Card 1234",
            bank: "HDFC Bank",
            kind: .card,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        let body = "INR 500.00 paid from account **1234 at Demo Store."
        let first = TestFixtures.makeAlert(body: body, receivedAt: TestFixtures.receivedAt)
        let withinWindow = TestFixtures.makeAlert(
            body: body,
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(240)
        )
        let outsideWindow = TestFixtures.makeAlert(
            body: body,
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(301)
        )
        context.insert(first)
        context.insert(withinWindow)
        context.insert(outsideWindow)
        try context.save()
        let raw = try TestFixtures.strictPostedOutput(
            for: body,
            amountText: "INR 500.00",
            amountValue: "500.00",
            direction: "debit",
            directionText: "paid",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "Demo Store"
        )
        let coordinator = SmsProcessingCoordinator(
            store: SmsProcessingStore(modelContainer: database.container),
            extractor: FixedSmsExtractor(rawOutput: raw),
            accountResolver: { _ in .unique(accountID: account.id) }
        )

        let firstOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: first.id,
                admissionReceiptID: first.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: try TestFixtures.makeSnapshot(context: context, alert: first)
        )
        guard case .persisted = firstOutcome else {
            return XCTFail("Expected first transaction to persist automatically")
        }

        let duplicateOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: withinWindow.id,
                admissionReceiptID: withinWindow.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: try TestFixtures.makeSnapshot(context: context, alert: withinWindow)
        )
        guard case .retainedForReview(_, _, let reasons) = duplicateOutcome else {
            return XCTFail("Expected 5-minute duplicate to retain for review")
        }
        XCTAssertTrue(reasons.contains("duplicate_possible"))

        let laterOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: outsideWindow.id,
                admissionReceiptID: outsideWindow.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: try TestFixtures.makeSnapshot(context: context, alert: outsideWindow)
        )
        guard case .persisted = laterOutcome else {
            return XCTFail("Expected alert outside 5-minute window to auto-save")
        }
    }

    func testBodyFreeTombstonesEraseRawEvidenceForPrefilterAndExtractorNone() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let otpAlert = TestFixtures.makeAlert(body: "Use 482910 as your OTP to log in.")
        let balanceAlert = TestFixtures.makeAlert(body: "Your HDFC card balance is INR 10,000.00.")
        context.insert(otpAlert)
        context.insert(balanceAlert)
        try context.save()

        let coordinator = SmsProcessingCoordinator(
            store: SmsProcessingStore(modelContainer: database.container),
            extractor: FixedSmsExtractor(rawOutput: #"{"decision":"none"}"#),
            accountResolver: { _ in .unresolved }
        )

        let otpSnapshot = try TestFixtures.makeSnapshot(context: context, alert: otpAlert)
        let otpOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: otpAlert.id,
                admissionReceiptID: otpAlert.id,
                sourceDigest: CanonicalJSON.sha256(otpAlert.rawBody)
            ),
            operation: otpSnapshot
        )
        XCTAssertEqual(
            otpOutcome,
            .terminallyDiscarded(
                operationID: otpSnapshot.operationID,
                reason: "prefilter_otp_verification"
            )
        )

        let balanceSnapshot = try TestFixtures.makeSnapshot(context: context, alert: balanceAlert)
        let balanceOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: balanceAlert.id,
                admissionReceiptID: balanceAlert.id,
                sourceDigest: CanonicalJSON.sha256(balanceAlert.rawBody)
            ),
            operation: balanceSnapshot
        )
        XCTAssertEqual(
            balanceOutcome,
            .terminallyDiscarded(
                operationID: balanceSnapshot.operationID,
                reason: "extractor_none"
            )
        )

        let verification = ModelContext(database.container)
        let alerts = try verification.fetch(FetchDescriptor<InboxAlert>())
        XCTAssertTrue(alerts.allSatisfy { $0.rawBody.isEmpty && $0.status == .rejected })
        XCTAssertEqual(
            alerts.first { $0.id == otpAlert.id }?.rejectionCode,
            "tombstoned_excluded"
        )
        XCTAssertEqual(
            alerts.first { $0.id == balanceAlert.id }?.rejectionCode,
            "tombstoned_none"
        )
        let operations = try verification.fetch(FetchDescriptor<SmsProcessingOperation>())
        XCTAssertEqual(
            operations.first { $0.id == otpSnapshot.operationID }?.retentionState,
            "tombstoned_excluded"
        )
        XCTAssertEqual(
            operations.first { $0.id == balanceSnapshot.operationID }?.retentionState,
            "tombstoned_none"
        )
        let attempts = try verification.fetch(FetchDescriptor<SmsSelectorAttempt>())
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.requestJSON, "{}")
        let analyses = try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>())
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.canonicalJSON, "{}")
    }

    func testAbstainIneligibleTruncatedValidationAndAccountExceptionsRouteToReview() async throws {
        let body = "INR 500.00 debited from a/c XX1234 at Demo Store."
        let validPosted = try TestFixtures.strictPostedOutput(
            for: body,
            amountText: "INR 500.00",
            amountValue: "500.00",
            directionText: "debited",
            accountReference: "XX1234",
            accountText: "XX1234",
            counterpartyText: "Demo Store"
        )

        let cases = [
            CoordinatorReviewCase(
                label: "abstain",
                eligible: true,
                extractor: FixedSmsExtractor(rawOutput: #"{"decision":"abstain"}"#),
                resolver: { _ in .unresolved },
                expectedReason: "extractor_abstained"
            ),
            CoordinatorReviewCase(
                label: "ineligible",
                eligible: false,
                extractor: FixedSmsExtractor(rawOutput: validPosted),
                resolver: { _ in .unresolved },
                expectedReason: "runtime_unavailable"
            ),
            CoordinatorReviewCase(
                label: "truncated",
                eligible: true,
                extractor: FixedSmsExtractor(rawOutput: validPosted, completion: "incomplete"),
                resolver: { _ in .unresolved },
                expectedReason: "runtime_output_truncated"
            ),
            CoordinatorReviewCase(
                label: "invalid_json",
                eligible: true,
                extractor: FixedSmsExtractor(rawOutput: "not-json"),
                resolver: { _ in .unresolved },
                expectedReason: "extractor_malformed_json"
            ),
            CoordinatorReviewCase(
                label: "parser_error",
                eligible: true,
                extractor: ThrowingSmsExtractor(error: TransactionParserError.rateLimited),
                resolver: { _ in .unresolved },
                expectedReason: "model_rate_limited"
            ),
            CoordinatorReviewCase(
                label: "unresolved_account",
                eligible: true,
                extractor: FixedSmsExtractor(rawOutput: validPosted),
                resolver: { _ in .unresolved },
                expectedReason: "account_resolution_unresolved"
            ),
            CoordinatorReviewCase(
                label: "ambiguous_account",
                eligible: true,
                extractor: FixedSmsExtractor(rawOutput: validPosted),
                resolver: { _ in .ambiguous(accountIDs: [UUID(), UUID()]) },
                expectedReason: "account_resolution_ambiguous"
            ),
        ]

        for testCase in cases {
            let database = try AppDatabase(inMemory: true)
            let context = database.container.mainContext
            let alert = TestFixtures.makeAlert(body: body)
            context.insert(alert)
            try context.save()
            let snapshot = try TestFixtures.makeSnapshot(
                context: context,
                alert: alert,
                extractorEligibilityOverride: testCase.eligible
            )
            let coordinator = SmsProcessingCoordinator(
                store: SmsProcessingStore(modelContainer: database.container),
                extractor: testCase.extractor,
                accountResolver: testCase.resolver
            )
            let outcome = await coordinator.process(
                source: AdmittedMessageRef(
                    sourceID: alert.id,
                    admissionReceiptID: alert.id,
                    sourceDigest: CanonicalJSON.sha256(body)
                ),
                operation: snapshot
            )
            guard case .retainedForReview(_, _, let reasons) = outcome else {
                XCTFail("Expected review for \(testCase.label), got \(outcome)")
                continue
            }
            XCTAssertTrue(reasons.contains(testCase.expectedReason), testCase.label)
            let verification = ModelContext(database.container)
            XCTAssertTrue(try verification.fetch(FetchDescriptor<Transaction>()).isEmpty, testCase.label)
            XCTAssertFalse(
                try XCTUnwrap(verification.fetch(FetchDescriptor<InboxAlert>()).first).rawBody.isEmpty,
                testCase.label
            )
        }
    }

    func testCancellationStopsCleanlyAndSourceDigestMismatchRetainsForReview() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert()
        context.insert(alert)
        try context.save()

        let cancelledSnapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let cancelledCoordinator = SmsProcessingCoordinator(
            store: SmsProcessingStore(modelContainer: database.container),
            extractor: ThrowingSmsExtractor(error: CancellationError()),
            accountResolver: { _ in .unresolved }
        )
        let cancelledOutcome = await cancelledCoordinator.process(
            source: AdmittedMessageRef(
                sourceID: alert.id,
                admissionReceiptID: alert.id,
                sourceDigest: CanonicalJSON.sha256(alert.rawBody)
            ),
            operation: cancelledSnapshot
        )
        guard case .stopped(_, let reviewCaseID, let reason) = cancelledOutcome else {
            return XCTFail("Expected stopped outcome, got \(cancelledOutcome)")
        }
        XCTAssertNotNil(reviewCaseID)
        XCTAssertEqual(reason, "operation_interrupted")

        let mismatchAlert = TestFixtures.makeAlert()
        context.insert(mismatchAlert)
        try context.save()
        let mismatchSnapshot = try TestFixtures.makeSnapshot(context: context, alert: mismatchAlert)
        let mismatchOutcome = await cancelledCoordinator.process(
            source: AdmittedMessageRef(
                sourceID: mismatchAlert.id,
                admissionReceiptID: mismatchAlert.id,
                sourceDigest: String(repeating: "f", count: 64)
            ),
            operation: mismatchSnapshot
        )
        guard case .retainedForReview(_, _, let reasons) = mismatchOutcome else {
            return XCTFail("Expected configuration mismatch review, got \(mismatchOutcome)")
        }
        XCTAssertEqual(reasons, ["persistence_configuration_hash_mismatch"])
    }
}
