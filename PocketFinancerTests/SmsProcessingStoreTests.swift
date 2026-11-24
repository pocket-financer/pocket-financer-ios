import SwiftData
import XCTest

@testable import PocketFinancer

final class SmsProcessingStoreTests: XCTestCase {
    /// The production container lives for the app process. Retain the synchronous retry
    /// fixture as well because iOS 26 SwiftData can still be draining save notifications
    /// when the test method returns, and immediate container teardown aborts in the Swift
    /// concurrency runtime after the assertions have completed.
    @MainActor private static var retainedSynchronousStores: [AppDatabase] = []

    @MainActor
    func testOperationClaimTraceReviewAndFeedbackAreDurableAndIdempotent() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "synthetic-source",
            contentDigest: "synthetic-digest",
            origin: .manual,
            sourceApplication: "Messages",
            sender: "SYNTH",
            rawBody: "INR 10 was paid from account **1234.",
            receivedAt: TestFixtures.receivedAt
        )
        context.insert(alert)
        try context.save()

        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        XCTAssertEqual(snapshot.configuration.persistencePolicy.rolloutMode, "automatic")
        XCTAssertEqual(snapshot.configuration.extractor.generationMode, "DIRECT_NON_THINKING")

        let store = SmsProcessingStore(modelContainer: database.container)
        let claim = try await store.claim(
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )
        let trace = try await store.appendTrace(
            claim,
            stage: "analysis",
            status: "completed",
            reasonCodes: ["amount_candidate_present"],
            now: TestFixtures.receivedAt
        )
        XCTAssertEqual(trace.sequence, 0)
        XCTAssertEqual(trace.eventHash.count, 64)

        let reviewID = try await store.retainForReview(
            claim,
            reasons: ["persistence_blocked_by_rollout_mode"],
            now: TestFixtures.receivedAt
        )
        let actionID = UUID()
        let command = ReviewCommand(
            actionID: actionID,
            reviewCaseID: reviewID,
            expectedRevision: 0,
            kind: .saveDraft,
            corrections: [],
            retryConfiguration: nil
        )
        let first = try await store.resolveReview(command, now: TestFixtures.receivedAt)
        let replay = try await store.resolveReview(command, now: TestFixtures.receivedAt)
        XCTAssertEqual(first.resultingRevision, 1)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)

        let verificationContext = ModelContext(database.container)
        let operations = try verificationContext.fetch(FetchDescriptor<SmsProcessingOperation>())
        let reviews = try verificationContext.fetch(FetchDescriptor<SmsReviewCase>())
        let feedback = try verificationContext.fetch(FetchDescriptor<SmsUserFeedbackEvent>())
        XCTAssertEqual(operations.first?.state, .retainedReview)
        XCTAssertEqual(reviews.first?.state, .draft)
        XCTAssertEqual(feedback.count, 1)
    }

    @MainActor
    func testExpiredOperationIsFencedAndRecoveredIntoReviewWithTrace() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "recovery-source",
            contentDigest: "recovery-digest",
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: "INR 10 was debited from account **1234.",
            receivedAt: TestFixtures.receivedAt
        )
        context.insert(alert)
        try context.save()
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let abandonedClaim = try await store.claim(
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )

        let recovered = try await store.recoverExpiredOperations(
            now: TestFixtures.receivedAt.addingTimeInterval(
                SmsProcessingStore.claimLease + 1
            )
        )

        XCTAssertEqual(recovered.count, 1)
        await xctAssertThrowsErrorAsync {
            try await store.transition(
                abandonedClaim,
                expected: .claimed,
                to: .analyzed,
                now: TestFixtures.receivedAt.addingTimeInterval(
                    SmsProcessingStore.claimLease + 1
                )
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await xctAssertThrowsErrorAsync {
            try await store.recordGateDecision(
                PersistenceGateDecision(
                    result: .reviewRequired,
                    primaryReason: "persistence_claim_ownership_invalid",
                    checks: []
                ),
                accountResolution: .missing,
                claim: abandonedClaim,
                rolloutMode: "shadow",
                now: TestFixtures.receivedAt.addingTimeInterval(
                    SmsProcessingStore.claimLease + 1
                )
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        let verification = ModelContext(database.container)
        let operation = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsProcessingOperation>()).first
        )
        XCTAssertEqual(operation.state, .retainedReview)
        XCTAssertNotNil(operation.settledAt)
        let review = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsReviewCase>()).first
        )
        XCTAssertEqual(review.id, recovered.first)
        XCTAssertTrue(review.reasonCodesRawValue.contains("operation_interrupted"))
        let trace = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsProcessingTraceEvent>()).first
        )
        XCTAssertEqual(trace.stageRawValue, "recovery")
        XCTAssertEqual(trace.reasonCodes, ["operation_interrupted"])
    }

    @MainActor
    func testRetrySnapshotReusesStableEventIdentity() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "retry-source",
            contentDigest: "retry-digest",
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: "INR 10 was debited from account **1234.",
            receivedAt: TestFixtures.receivedAt
        )
        context.insert(alert)
        try context.save()
        let factory = SmsOperationSnapshotFactory(context: context)
        let original = try factory.create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        let originalOperationID = original.operationID
        let originalStableEventID = original.stableEventID
        let retry = try factory.create(
            sourceAlertID: alert.id,
            parentOperationID: originalOperationID,
            trigger: "retry",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt.addingTimeInterval(1)
        )

        XCTAssertNotEqual(originalOperationID, retry.operationID)
        XCTAssertEqual(originalStableEventID, retry.stableEventID)
        Self.retainedSynchronousStores.append(database)
    }

    @MainActor
    func testLegacyBackfillIsIdempotentAndPreservesExactStoredValues() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alertID = UUID()
        let transaction = Transaction(
            amountMinorUnits: 99,
            currencyCode: "JPY",
            merchant: "SYNTH STORE",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: nil,
            accountLabel: nil,
            isEdited: true,
            parserName: "Legacy",
            reviewState: .needsReview,
            sourceAlertID: alertID,
            amountEvidenceText: "JPY 99",
            dateEvidenceText: nil
        )
        context.insert(transaction)
        try context.save()

        let store = SmsProcessingStore(modelContainer: database.container)
        try await store.backfillLegacyTransactions(now: TestFixtures.receivedAt)
        try await store.backfillLegacyTransactions(now: TestFixtures.receivedAt)

        let verificationContext = ModelContext(database.container)
        let snapshots = try verificationContext.fetch(
            FetchDescriptor<SmsLegacyTransactionSnapshot>()
        )
        let revisions = try verificationContext.fetch(FetchDescriptor<SmsTransactionRevision>())
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.amountMinorUnits, 99)
        XCTAssertFalse(snapshots.first?.originalEditHistoryKnown ?? true)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.currencyScale, 0)
    }

    @MainActor
    func testCorrectionAtomicallyProjectsLedgerRevisionAndReplaysIdempotently() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let rawBody = "INR 10 was debited from account **1234 at SYNTH SHOP or INR 12.50."
        let alert = InboxAlert(
            sourceIdentity: "synthetic-review-source",
            contentDigest: CanonicalJSON.sha256(rawBody),
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: rawBody,
            receivedAt: TestFixtures.receivedAt
        )
        let account = Account(
            name: "Synthetic account",
            bank: "Synthetic bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        context.insert(alert)
        context.insert(account)
        try context.save()
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        let analysis = try StructuralSmsAnalyzer().analyze(
            source: alert.rawBody,
            operation: snapshot
        )
        let initialOutput = try TestFixtures.strictPostedOutput(
            for: rawBody,
            amountText: "INR 10",
            amountValue: "10",
            direction: "debit",
            directionText: "debited",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "SYNTH SHOP"
        )
        let extraction = try SmsExtractorValidator().validate(
            rawOutput: initialOutput,
            source: rawBody,
            primaryCurrency: "INR"
        )
        let resultJSON = try SmsProcessingJSON.result(
            status: "review",
            extraction: extraction,
            operation: snapshot,
            account: SmsProcessingJSON.account(.unresolved, reference: "1234"),
            duplicate: SmsProcessingJSON.duplicate(
                status: "clear",
                operation: snapshot,
                fingerprint: CanonicalJSON.sha256("fp")
            ),
            gate: SmsProcessingJSON.gate(
                posted: true,
                accountReason: "account_resolution_unresolved",
                duplicateStatus: "clear",
                rolloutMode: "automatic"
            ),
            reasons: ["account_resolution_unresolved"]
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let claim = try await store.claim(
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )
        try await store.recordAnalysis(
            analysis,
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )
        try await store.recordNormalizedResult(
            operationID: snapshot.operationID,
            semanticResultJSON: resultJSON,
            decision: "posted"
        )
        try await store.recordGateDecision(
            claim,
            result: "review_required",
            primaryReason: "account_resolution_unresolved",
            checksJSON: try SmsProcessingJSON.checksJSON(
                posted: true,
                accountReason: "account_resolution_unresolved",
                duplicateStatus: "clear",
                rolloutMode: "automatic"
            ),
            accountResolutionJSON: try SmsProcessingJSON.canonical(
                SmsProcessingJSON.account(.unresolved, reference: "1234")
            ),
            rolloutMode: "automatic",
            now: TestFixtures.receivedAt
        )
        let reviewID = try await store.retainForReview(
            claim,
            reasons: ["account_resolution_unresolved"],
            now: TestFixtures.receivedAt
        )
        let correctedAmountRange = try XCTUnwrap(rawBody.range(of: "INR 12.50"))
        let correctedAmountStart = rawBody[..<correctedAmountRange.lowerBound].unicodeScalars.count
        let correctedAmountEnd =
            correctedAmountStart + rawBody[correctedAmountRange].unicodeScalars.count
        let correctedSpan = try UnicodeScalarSpan(
            source: rawBody,
            startScalar: correctedAmountStart,
            endScalar: correctedAmountEnd,
            text: "INR 12.50"
        )
        let actionID = UUID()
        let correction = ReviewCommand(
            actionID: actionID,
            reviewCaseID: reviewID,
            expectedRevision: 0,
            kind: .correct,
            corrections: [
                SmsFieldCorrection(
                    field: "amount",
                    classification: .changedInterpretationAmongCandidates,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: correctedSpan,
                    newValue: "1250"
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
                SmsFieldCorrection(
                    field: "account_id",
                    classification: .selectedExistingCandidate,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: account.id.uuidString.lowercased()
                ),
            ],
            retryConfiguration: nil
        )

        let receipt = try await store.resolveReview(
            correction,
            now: TestFixtures.receivedAt
        )
        let replay = try await store.resolveReview(
            correction,
            now: TestFixtures.receivedAt
        )

        XCTAssertEqual(receipt.resultingRevision, 1)
        XCTAssertFalse(receipt.replayed)
        XCTAssertTrue(replay.replayed)
        let verification = ModelContext(database.container)
        let transaction = try XCTUnwrap(
            verification.fetch(FetchDescriptor<Transaction>()).first
        )
        XCTAssertEqual(transaction.amountMinorUnits, 1_250)
        XCTAssertEqual(transaction.currencyCode, "INR")
        XCTAssertEqual(transaction.merchant, "Unspecified counterparty")
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.reviewState, .confirmed)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsAccountAlias>()).count, 1)
        let revisions = try verification.fetch(FetchDescriptor<SmsTransactionRevision>())
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(
            revisions.first?.provenanceRawValue,
            "user_confirmed_source_span_revision"
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsUserFeedbackEvent>()).count,
            1
        )
        await xctAssertThrowsErrorAsync {
            _ = try await store.resolveReview(
                ReviewCommand(
                    actionID: UUID(),
                    reviewCaseID: reviewID,
                    expectedRevision: 0,
                    kind: .reject,
                    corrections: [],
                    retryConfiguration: nil
                )
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .revisionConflict)
        }
    }

    @MainActor
    func testManualReviewCreatesTransactionAndAccountWithoutModelResult() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "manual-review-source",
            contentDigest: "manual-review-digest",
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: "INR 100 was credited to account **1234 from SYNTH PAYER.",
            receivedAt: TestFixtures.receivedAt
        )
        context.insert(alert)
        try context.save()
        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let claim = try await store.claim(
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )
        let reviewID = try await store.retainForReview(
            claim,
            reasons: ["selector_unknown_or_cross_message_candidate"],
            now: TestFixtures.receivedAt
        )

        await xctAssertThrowsErrorAsync {
            _ = try await store.resolveReview(
                ReviewCommand(
                    actionID: UUID(),
                    reviewCaseID: reviewID,
                    expectedRevision: 0,
                    kind: .confirm,
                    corrections: [],
                    retryConfiguration: nil
                ),
                now: TestFixtures.receivedAt
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .invalidCommand)
        }

        let manualCorrection: (String, String) -> SmsFieldCorrection = { field, value in
            SmsFieldCorrection(
                field: field,
                classification: .suppliedManualUngroundedValue,
                previousRevisionID: nil,
                candidateID: nil,
                evidence: nil,
                newValue: value
            )
        }
        let command = ReviewCommand(
            actionID: UUID(),
            reviewCaseID: reviewID,
            expectedRevision: 0,
            kind: .correct,
            corrections: [
                manualCorrection("amount_minor_units", "10000"),
                manualCorrection("currency", "INR"),
                manualCorrection("direction", "credit"),
                manualCorrection("counterparty", "Synthetic payer"),
                manualCorrection(
                    "occurred_at_epoch_ms",
                    String(Int64(TestFixtures.receivedAt.timeIntervalSince1970 * 1_000))
                ),
                manualCorrection("new_account_name", "Synthetic account"),
                manualCorrection("new_account_bank", "Synthetic bank"),
                manualCorrection("new_account_kind", "account"),
                manualCorrection("new_account_suffix", "1234"),
            ],
            retryConfiguration: nil
        )

        let receipt = try await store.resolveReview(command, now: TestFixtures.receivedAt)

        XCTAssertEqual(receipt.resultingRevision, 1)
        let verification = ModelContext(database.container)
        let account = try XCTUnwrap(verification.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(account.name, "Synthetic account")
        XCTAssertEqual(account.bank, "Synthetic bank")
        XCTAssertEqual(account.kind, .account)
        XCTAssertEqual(account.suffix, "1234")
        let alias = try XCTUnwrap(verification.fetch(FetchDescriptor<SmsAccountAlias>()).first)
        XCTAssertEqual(alias.accountID, account.id)
        XCTAssertTrue(alias.confirmedByUser)
        let transaction = try XCTUnwrap(
            verification.fetch(FetchDescriptor<Transaction>()).first
        )
        XCTAssertEqual(transaction.amountMinorUnits, 10_000)
        XCTAssertEqual(transaction.direction, .credit)
        XCTAssertEqual(transaction.merchant, "Synthetic payer")
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.parserName, "manual-review-entry")
        XCTAssertEqual(transaction.amountEvidenceText, "")
        let updatedAlert = try XCTUnwrap(
            verification.fetch(FetchDescriptor<InboxAlert>()).first
        )
        XCTAssertEqual(updatedAlert.status, .imported)
        let revision = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsTransactionRevision>()).first
        )
        XCTAssertEqual(revision.provenanceRawValue, "user_supplied_review_transaction")
    }

    @MainActor
    func testLaterLedgerEditAppendsLegacyBaselineFeedbackAndRevision() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "legacy-source",
            contentDigest: "legacy-digest",
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: "INR 10 debited from account **1234.",
            receivedAt: TestFixtures.receivedAt
        )
        let account = Account(
            name: "Synthetic account",
            bank: "Synthetic bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        let transaction = Transaction(
            amountMinorUnits: 1_000,
            currencyCode: "INR",
            merchant: "Original merchant",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: account.id,
            accountLabel: account.name,
            parserName: "legacy",
            reviewState: .confirmed,
            sourceAlertID: alert.id,
            amountEvidenceText: "INR 10",
            dateEvidenceText: nil
        )
        alert.transactionID = transaction.id
        alert.status = .imported
        context.insert(alert)
        context.insert(account)
        context.insert(transaction)
        try context.save()

        let actionID = UUID()
        let command = TransactionProjectionEditCommand(
            actionID: actionID,
            transactionID: transaction.id,
            expectedRevision: -1,
            amountMinorUnits: 1_250,
            currencyCode: "INR",
            direction: .debit,
            merchant: "Corrected merchant",
            accountID: account.id,
            occurredAt: TestFixtures.receivedAt,
            corrections: [
                SmsFieldCorrection(
                    field: "amount_minor_units",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: "1250"
                )
            ]
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let receipt = try await store.editTransactionProjection(
            command, now: TestFixtures.receivedAt.addingTimeInterval(1)
        )
        let replay = try await store.editTransactionProjection(
            command, now: TestFixtures.receivedAt.addingTimeInterval(2)
        )

        XCTAssertEqual(receipt.resultingRevision, 1)
        XCTAssertFalse(receipt.replayed)
        XCTAssertTrue(replay.replayed)
        let verification = ModelContext(database.container)
        let updated = try XCTUnwrap(
            verification.fetch(FetchDescriptor<Transaction>()).first
        )
        XCTAssertEqual(updated.amountMinorUnits, 1_250)
        XCTAssertEqual(updated.merchant, "Corrected merchant")
        XCTAssertTrue(updated.isEdited)
        let revisions = try verification.fetch(
            FetchDescriptor<SmsTransactionRevision>(sortBy: [SortDescriptor(\.revision)])
        )
        XCTAssertEqual(revisions.map(\.revision), [0, 1])
        XCTAssertEqual(
            revisions.map(\.provenanceRawValue),
            [
                "legacy_current_state_original_history_unknown",
                "user_corrected_projection",
            ]
        )
        let feedback = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsUserFeedbackEvent>()).first
        )
        XCTAssertNil(feedback.reviewCaseID)
        XCTAssertEqual(feedback.transactionID, transaction.id)
        XCTAssertEqual(feedback.actionRawValue, "correct")
    }

    @MainActor
    func testFiveMinuteDuplicateWindowExcludesCurrentSourceAndChecksWindowBoundary() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "Main Checking",
            bank: "HDFC Bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        let existingSourceID = UUID()
        let persisted = Transaction(
            amountMinorUnits: 50_000,
            currencyCode: "INR",
            merchant: "Demo Store",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: account.id,
            accountLabel: account.name,
            parserName: SmsContractAssets.releaseID,
            reviewState: .confirmed,
            sourceAlertID: existingSourceID,
            amountEvidenceText: "INR 500.00",
            dateEvidenceText: nil,
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        context.insert(persisted)
        try context.save()

        let store = SmsProcessingStore(modelContainer: database.container)
        let otherSourceID = UUID()
        let atBoundary = try await store.duplicateStatus(
            operationID: UUID(),
            sourceID: otherSourceID,
            stableEventID: UUID(),
            accountID: account.id,
            direction: "debit",
            minorUnits: 50_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt.addingTimeInterval(300)
        )
        XCTAssertEqual(atBoundary, "possible_duplicate")

        let outsideBoundary = try await store.duplicateStatus(
            operationID: UUID(),
            sourceID: otherSourceID,
            stableEventID: UUID(),
            accountID: account.id,
            direction: "debit",
            minorUnits: 50_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt.addingTimeInterval(301)
        )
        XCTAssertEqual(outsideBoundary, "clear")

        let sameSource = try await store.duplicateStatus(
            operationID: UUID(),
            sourceID: existingSourceID,
            stableEventID: UUID(),
            accountID: account.id,
            direction: "debit",
            minorUnits: 50_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt
        )
        XCTAssertEqual(sameSource, "already_persisted")
    }
}

@MainActor
private func xctAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw")
    } catch {
        verify(error)
    }
}
