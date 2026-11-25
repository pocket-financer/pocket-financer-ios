import Foundation
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
        let alert = TestFixtures.makeAlert(body: "INR 10 was paid from account **1234.")
        context.insert(alert)
        try context.save()

        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert, trigger: "manual")
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
            reasons: ["account_resolution_unresolved"],
            now: TestFixtures.receivedAt
        )
        let command = ReviewCommand(
            actionID: UUID(),
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

        let verification = ModelContext(database.container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsProcessingOperation>()).first?.state,
            .retainedReview
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsReviewCase>()).first?.state,
            .draft
        )
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsUserFeedbackEvent>()).count, 1)
    }

    @MainActor
    func testExpiredOperationIsFencedAndRecoveredIntoReviewWithTrace() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert(body: "INR 10 was debited from account **1234.")
        context.insert(alert)
        try context.save()
        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert, trigger: "manual")
        let store = SmsProcessingStore(modelContainer: database.container)
        let abandonedClaim = try await store.claim(
            operationID: snapshot.operationID,
            now: TestFixtures.receivedAt
        )

        let expiredNow = TestFixtures.receivedAt.addingTimeInterval(SmsProcessingStore.claimLease + 1)
        let recovered = try await store.recoverExpiredOperations(now: expiredNow)
        XCTAssertEqual(recovered.count, 1)

        await TestFixtures.assertThrowsErrorAsync {
            try await store.transition(abandonedClaim, expected: .claimed, to: .analyzed, now: expiredNow)
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordGateDecision(
                PersistenceGateDecision(
                    result: .reviewRequired,
                    primaryReason: "persistence_claim_ownership_invalid",
                    checks: []
                ),
                accountResolution: .missing,
                claim: abandonedClaim,
                rolloutMode: "automatic",
                now: expiredNow
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
        let review = try XCTUnwrap(verification.fetch(FetchDescriptor<SmsReviewCase>()).first)
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
        let alert = TestFixtures.makeAlert(body: "INR 10 was debited from account **1234.")
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
        let retry = try factory.create(
            sourceAlertID: alert.id,
            parentOperationID: original.operationID,
            trigger: "retry",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt.addingTimeInterval(1)
        )

        XCTAssertNotEqual(original.operationID, retry.operationID)
        XCTAssertEqual(original.stableEventID, retry.stableEventID)
        Self.retainedSynchronousStores.append(database)
    }

    @MainActor
    func testLegacyBackfillIsIdempotentAndPreservesExactStoredValues() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
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
            sourceAlertID: UUID(),
            amountEvidenceText: "JPY 99",
            dateEvidenceText: nil
        )
        context.insert(transaction)
        try context.save()

        let store = SmsProcessingStore(modelContainer: database.container)
        try await store.backfillLegacyTransactions(now: TestFixtures.receivedAt)
        try await store.backfillLegacyTransactions(now: TestFixtures.receivedAt)

        let verification = ModelContext(database.container)
        let snapshots = try verification.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>())
        let revisions = try verification.fetch(FetchDescriptor<SmsTransactionRevision>())
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.amountMinorUnits, 99)
        XCTAssertFalse(snapshots.first?.originalEditHistoryKnown ?? true)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.currencyScale, 0)
    }

    @MainActor
    func testGroundedReviewConfirmCreatesDeterministicAccountAndVpaAliasAtomically() async throws {
        let database = try AppDatabase(inMemory: true)
        let body = "INR 250.00 debited from user.name@synthbank at Demo Cafe."
        let reviewID = try await seedGroundedReview(
            database: database,
            body: body,
            amountText: "INR 250.00",
            amountValue: "250.00",
            directionText: "debited",
            accountReference: "user.name@synthbank",
            accountText: "user.name@synthbank",
            counterpartyText: "Demo Cafe"
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let receipt = try await store.resolveReview(
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
        XCTAssertEqual(receipt.resultingRevision, 1)

        let verification = ModelContext(database.container)
        let account = try XCTUnwrap(verification.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(account.name, "UPI account user.name@synthbank")
        XCTAssertNil(account.suffix)
        let alias = try XCTUnwrap(verification.fetch(FetchDescriptor<SmsAccountAlias>()).first)
        XCTAssertEqual(alias.accountID, account.id)
        XCTAssertEqual(alias.aliasKindRawValue, "vpa")
        XCTAssertEqual(alias.normalizedAliasHash, CanonicalJSON.sha256("vpa:user.name@synthbank"))
        XCTAssertTrue(alias.confirmedByUser)
        let transaction = try XCTUnwrap(verification.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(transaction.amountMinorUnits, 25_000)
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsTransactionRevision>()).first?.provenanceRawValue,
            "user_confirmed_grounded_proposal"
        )
    }

    @MainActor
    func testGroundedReviewCorrectionAtomicallyProjectsLedgerRevisionAndReplaysIdempotently() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let rawBody = "INR 10 was debited from account **1234 at SYNTH SHOP or INR 12.50."
        let account = Account(
            name: "Synthetic account",
            bank: "Synthetic bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        try context.save()
        let reviewID = try await seedGroundedReview(
            database: database,
            body: rawBody,
            amountText: "INR 10",
            amountValue: "10",
            directionText: "debited",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "SYNTH SHOP"
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
        let correction = ReviewCommand(
            actionID: UUID(),
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

        let store = SmsProcessingStore(modelContainer: database.container)
        let receipt = try await store.resolveReview(correction, now: TestFixtures.receivedAt)
        let replay = try await store.resolveReview(correction, now: TestFixtures.receivedAt)

        XCTAssertEqual(receipt.resultingRevision, 1)
        XCTAssertFalse(receipt.replayed)
        XCTAssertTrue(replay.replayed)
        let verification = ModelContext(database.container)
        let transaction = try XCTUnwrap(verification.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(transaction.amountMinorUnits, 1_250)
        XCTAssertEqual(transaction.currencyCode, "INR")
        XCTAssertEqual(transaction.merchant, "Unspecified counterparty")
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.reviewState, .confirmed)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsAccountAlias>()).count, 1)
        let revisions = try verification.fetch(FetchDescriptor<SmsTransactionRevision>())
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.provenanceRawValue, "user_confirmed_source_span_revision")
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsUserFeedbackEvent>()).count, 1)

        await TestFixtures.assertThrowsErrorAsync {
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
    func testManualReviewCreatesTransactionAndAccountAndRejectsInvalidCommands() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert(
            body: "INR 100 was credited to account **1234 from SYNTH PAYER."
        )
        context.insert(alert)
        try context.save()
        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let store = SmsProcessingStore(modelContainer: database.container)
        let claim = try await store.claim(operationID: snapshot.operationID, now: TestFixtures.receivedAt)
        let reviewID = try await store.retainForReview(
            claim,
            reasons: ["extractor_abstained"],
            now: TestFixtures.receivedAt
        )

        await TestFixtures.assertThrowsErrorAsync {
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

        await TestFixtures.assertThrowsErrorAsync {
            _ = try await store.resolveReview(
                ReviewCommand(
                    actionID: UUID(),
                    reviewCaseID: reviewID,
                    expectedRevision: 0,
                    kind: .retry,
                    corrections: [],
                    retryConfiguration: "invalid_mode"
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
        let transaction = try XCTUnwrap(verification.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(transaction.amountMinorUnits, 10_000)
        XCTAssertEqual(transaction.direction, .credit)
        XCTAssertEqual(transaction.merchant, "Synthetic payer")
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.parserName, "manual-review-entry")
        XCTAssertEqual(transaction.amountEvidenceText, "")
        XCTAssertEqual(try verification.fetch(FetchDescriptor<InboxAlert>()).first?.status, .imported)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsTransactionRevision>()).first?.provenanceRawValue,
            "user_supplied_review_transaction"
        )
    }

    @MainActor
    func testStopAndSettleDiscardedEnforceTombstoneRedactionAndIdempotency() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let stopAlert = TestFixtures.makeAlert(body: "INR 50 debited from XX1234.")
        let discardAlert = TestFixtures.makeAlert(body: "Card statement INR 50.00 ready.")
        context.insert(stopAlert)
        context.insert(discardAlert)
        try context.save()

        let stopSnapshot = try TestFixtures.makeSnapshot(context: context, alert: stopAlert)
        let discardSnapshot = try TestFixtures.makeSnapshot(context: context, alert: discardAlert)
        let store = SmsProcessingStore(modelContainer: database.container)

        _ = try await store.claim(operationID: stopSnapshot.operationID, now: TestFixtures.receivedAt)
        let firstStop = try await store.stop(
            operationID: stopSnapshot.operationID,
            now: TestFixtures.receivedAt
        )
        let secondStop = try await store.stop(
            operationID: stopSnapshot.operationID,
            now: TestFixtures.receivedAt
        )
        XCTAssertEqual(firstStop.state, .retainedReview)
        XCTAssertEqual(firstStop.reviewCaseID, secondStop.reviewCaseID)
        XCTAssertFalse(firstStop.committed)

        let discardClaim = try await store.claim(
            operationID: discardSnapshot.operationID,
            now: TestFixtures.receivedAt
        )
        let analysis = try StructuralSmsAnalyzer().analyze(
            source: discardAlert.rawBody,
            operation: discardSnapshot
        )
        try await store.recordAnalysis(
            analysis,
            operationID: discardSnapshot.operationID,
            now: TestFixtures.receivedAt
        )
        try await store.recordSelectorResponse(
            operationID: discardSnapshot.operationID,
            response: DirectSelectorResponse(
                rawOutput: #"{"decision":"none"}"#,
                runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                requestJSON: #"{"message":"sensitive"}"#,
                completion: "complete"
            ),
            startedAt: TestFixtures.receivedAt,
            now: TestFixtures.receivedAt
        )
        try await store.settleDiscarded(
            discardClaim,
            retentionState: "tombstoned_none",
            reason: "extractor_none",
            now: TestFixtures.receivedAt
        )

        let verification = ModelContext(database.container)
        let discardID = discardAlert.id
        let persistedDiscard = try XCTUnwrap(
            verification.fetch(FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == discardID })).first
        )
        XCTAssertTrue(persistedDiscard.rawBody.isEmpty)
        XCTAssertEqual(persistedDiscard.status, .rejected)
        XCTAssertEqual(persistedDiscard.rejectionCode, "tombstoned_none")
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>()).first?.canonicalJSON,
            "{}"
        )
        let attempt = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsSelectorAttempt>()).first
        )
        XCTAssertEqual(attempt.requestJSON, "{}")
        XCTAssertEqual(attempt.rawOutput, #"{"decision":"none"}"#)
    }

    @MainActor
    func testLaterLedgerEditAppendsLegacyBaselineFeedbackRevisionAndValidatesConflicts() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert(body: "INR 10 debited from account **1234.")
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

        let command = TransactionProjectionEditCommand(
            actionID: UUID(),
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
            command,
            now: TestFixtures.receivedAt.addingTimeInterval(1)
        )
        let replay = try await store.editTransactionProjection(
            command,
            now: TestFixtures.receivedAt.addingTimeInterval(2)
        )

        XCTAssertEqual(receipt.resultingRevision, 1)
        XCTAssertFalse(receipt.replayed)
        XCTAssertTrue(replay.replayed)

        let confirmUnchanged = try await store.editTransactionProjection(
            TransactionProjectionEditCommand(
                actionID: UUID(),
                transactionID: transaction.id,
                expectedRevision: 1,
                amountMinorUnits: 1_250,
                currencyCode: "INR",
                direction: .debit,
                merchant: "Corrected merchant",
                accountID: account.id,
                occurredAt: TestFixtures.receivedAt,
                corrections: []
            ),
            now: TestFixtures.receivedAt.addingTimeInterval(3)
        )
        XCTAssertEqual(confirmUnchanged.resultingRevision, 2)

        await TestFixtures.assertThrowsErrorAsync {
            _ = try await store.editTransactionProjection(
                TransactionProjectionEditCommand(
                    actionID: UUID(),
                    transactionID: transaction.id,
                    expectedRevision: 0,
                    amountMinorUnits: 1_250,
                    currencyCode: "INR",
                    direction: .debit,
                    merchant: "Stale revision",
                    accountID: account.id,
                    occurredAt: TestFixtures.receivedAt,
                    corrections: []
                )
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .revisionConflict)
        }

        let verification = ModelContext(database.container)
        let updated = try XCTUnwrap(verification.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(updated.amountMinorUnits, 1_250)
        XCTAssertEqual(updated.merchant, "Corrected merchant")
        XCTAssertTrue(updated.isEdited)
        let revisions = try verification.fetch(
            FetchDescriptor<SmsTransactionRevision>(sortBy: [SortDescriptor(\.revision)])
        )
        XCTAssertEqual(revisions.map(\.revision), [0, 1, 2])
        XCTAssertEqual(
            revisions.map(\.provenanceRawValue),
            [
                "legacy_current_state_original_history_unknown",
                "user_corrected_projection",
                "user_confirmed_unchanged_projection",
            ]
        )
        let feedback = try verification.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(sortBy: [SortDescriptor(\.createdAt)])
        )
        XCTAssertEqual(feedback.map(\.actionRawValue), ["correct", "confirmed_unchanged"])
        XCTAssertTrue(feedback.allSatisfy { $0.reviewCaseID == nil && $0.transactionID == transaction.id })
    }

    @MainActor
    func testFiveMinuteDuplicateWindowChecksBoundarySourceAndMatchDimensions() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "Main Checking",
            bank: "HDFC Bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        let otherAccount = Account(
            name: "Second Checking",
            bank: "Axis Bank",
            kind: .account,
            suffix: "5678",
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
        context.insert(otherAccount)
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

        let differentAccount = try await store.duplicateStatus(
            operationID: UUID(),
            sourceID: otherSourceID,
            stableEventID: UUID(),
            accountID: otherAccount.id,
            direction: "debit",
            minorUnits: 50_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt
        )
        XCTAssertEqual(differentAccount, "clear")

        let differentDirection = try await store.duplicateStatus(
            operationID: UUID(),
            sourceID: otherSourceID,
            stableEventID: UUID(),
            accountID: account.id,
            direction: "credit",
            minorUnits: 50_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt
        )
        XCTAssertEqual(differentDirection, "clear")

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

    @MainActor
    private func seedGroundedReview(
        database: AppDatabase,
        body: String,
        amountText: String,
        amountValue: String,
        directionText: String,
        accountReference: String,
        accountText: String,
        counterpartyText: String?
    ) async throws -> UUID {
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert(body: body)
        context.insert(alert)
        try context.save()
        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert, trigger: "manual")
        let analysis = try StructuralSmsAnalyzer().analyze(source: body, operation: snapshot)
        let output = try TestFixtures.strictPostedOutput(
            for: body,
            amountText: amountText,
            amountValue: amountValue,
            directionText: directionText,
            accountReference: accountReference,
            accountText: accountText,
            counterpartyText: counterpartyText
        )
        let extraction = try SmsExtractorValidator().validate(
            rawOutput: output,
            source: body,
            primaryCurrency: "INR"
        )
        let extracted = try XCTUnwrap(extraction.transaction)
        let fingerprint = CanonicalJSON.sha256(
            "\(extracted.minorUnits)\0\(extracted.currency)\0"
                + "\(extracted.direction.rawValue)\0\0\(snapshot.configuration.receivedTimestamp.epochMs)"
        )
        let resultJSON = try SmsProcessingJSON.result(
            status: "review",
            extraction: extraction,
            operation: snapshot,
            account: SmsProcessingJSON.account(.unresolved, reference: extracted.accountReference),
            duplicate: SmsProcessingJSON.duplicate(
                status: "clear",
                operation: snapshot,
                fingerprint: fingerprint
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
        let claim = try await store.claim(operationID: snapshot.operationID, now: TestFixtures.receivedAt)
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
                SmsProcessingJSON.account(.unresolved, reference: extracted.accountReference)
            ),
            rolloutMode: "automatic",
            now: TestFixtures.receivedAt
        )
        return try await store.retainForReview(
            claim,
            reasons: ["account_resolution_unresolved"],
            now: TestFixtures.receivedAt
        )
    }
}
