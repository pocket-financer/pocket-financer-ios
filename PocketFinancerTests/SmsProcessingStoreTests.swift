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
        let database = try TestFixtures.makeInMemoryDatabase()
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
        let database = try TestFixtures.makeInMemoryDatabase()
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
                abandonedClaim,
                result: "review_required",
                primaryReason: "persistence_claim_ownership_invalid",
                checksJSON: "[]",
                accountResolutionJSON: #"{"result":"missing"}"#,
                rolloutMode: "automatic",
                now: expiredNow
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordAnalysis(abandonedClaim, analysis: analysis, now: expiredNow)
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordSelectorResponse(
                abandonedClaim,
                response: DirectSelectorResponse(
                    rawOutput: #"{"decision":"none"}"#,
                    runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                    requestJSON: #"{"message":"sensitive"}"#,
                    completion: "complete"
                ),
                startedAt: TestFixtures.receivedAt,
                now: expiredNow
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordSelectorFailure(
                abandonedClaim,
                runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                requestJSON: #"{"message":"sensitive"}"#,
                safeErrorCode: "model_timed_out",
                startedAt: TestFixtures.receivedAt,
                now: expiredNow
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.markSelectorInvalid(
                abandonedClaim,
                safeErrorCode: "extractor_malformed_json",
                now: expiredNow
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordNormalizedResult(
                abandonedClaim,
                semanticResultJSON: "{}",
                decision: "none",
                now: expiredNow
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }

        let verification = ModelContext(database.container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>()).isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsSelectorAttempt>()).isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsReconstructedResult>()).isEmpty)
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
        let database = try TestFixtures.makeInMemoryDatabase()
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
        let database = try TestFixtures.makeInMemoryDatabase()
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
        let database = try TestFixtures.makeInMemoryDatabase()
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
        let database = try TestFixtures.makeInMemoryDatabase()
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
    func testPartialAbstainedReviewCreatesTransactionAndAccountAndRejectsInvalidCommands() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let rawBody = "INR 100 was credited to account **1234 from SYNTH PAYER."
        let alert = TestFixtures.makeAlert(body: rawBody)
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

        let amountSpan = try makeSpan(in: rawBody, matching: "INR 100")
        let accountSpan = try makeSpan(in: rawBody, matching: "**1234")
        let counterpartySpan = try makeSpan(in: rawBody, matching: "SYNTH PAYER")

        // 2-digit suffix must be rejected consistently with 3..8 digit alias normalization (IOS-21).
        await TestFixtures.assertThrowsErrorAsync {
            _ = try await store.resolveReview(
                ReviewCommand(
                    actionID: UUID(),
                    reviewCaseID: reviewID,
                    expectedRevision: 0,
                    kind: .correct,
                    corrections: [
                        SmsFieldCorrection(
                            field: "amount",
                            classification: .suppliedSourceSupportedCandidateMiss,
                            previousRevisionID: nil,
                            candidateID: nil,
                            evidence: nil,
                            scalarEvidence: amountSpan,
                            newValue: "10000"
                        ),
                        SmsFieldCorrection(
                            field: "direction",
                            classification: .suppliedManualUngroundedValue,
                            previousRevisionID: nil,
                            candidateID: nil,
                            evidence: nil,
                            scalarEvidence: nil,
                            newValue: "credit"
                        ),
                        SmsFieldCorrection(
                            field: "new_account_name",
                            classification: .suppliedManualUngroundedValue,
                            previousRevisionID: nil,
                            candidateID: nil,
                            evidence: nil,
                            newValue: "Short Suffix Account"
                        ),
                        SmsFieldCorrection(
                            field: "new_account_suffix",
                            classification: .suppliedManualUngroundedValue,
                            previousRevisionID: nil,
                            candidateID: nil,
                            evidence: nil,
                            newValue: "34"
                        ),
                    ],
                    retryConfiguration: nil
                ),
                now: TestFixtures.receivedAt
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .invalidCommand)
        }

        let command = ReviewCommand(
            actionID: UUID(),
            reviewCaseID: reviewID,
            expectedRevision: 0,
            kind: .correct,
            corrections: [
                SmsFieldCorrection(
                    field: "currency",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: "INR"
                ),
                SmsFieldCorrection(
                    field: "amount",
                    classification: .suppliedSourceSupportedCandidateMiss,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: amountSpan,
                    newValue: "10000"
                ),
                SmsFieldCorrection(
                    field: "direction",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: nil,
                    newValue: "credit"
                ),
                SmsFieldCorrection(
                    field: "account",
                    classification: .suppliedSourceSupportedCandidateMiss,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: accountSpan,
                    newValue: "1234"
                ),
                SmsFieldCorrection(
                    field: "counterparty",
                    classification: .suppliedSourceSupportedCandidateMiss,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: counterpartySpan,
                    newValue: "synth payer"
                ),
                SmsFieldCorrection(
                    field: "new_account_name",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: "Synthetic account"
                ),
                SmsFieldCorrection(
                    field: "new_account_bank",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: "Synthetic bank"
                ),
                SmsFieldCorrection(
                    field: "new_account_kind",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: "account"
                ),
                SmsFieldCorrection(
                    field: "new_account_suffix",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: "1234"
                ),
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
        XCTAssertEqual(transaction.merchant, "synth payer")
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.occurredAt, TestFixtures.receivedAt)
        XCTAssertEqual(transaction.parserName, SmsContractAssets.releaseID)
        XCTAssertEqual(transaction.amountEvidenceText, "INR 100")
        XCTAssertEqual(try verification.fetch(FetchDescriptor<InboxAlert>()).first?.status, .imported)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SmsTransactionRevision>()).first?.provenanceRawValue,
            "user_confirmed_source_span_revision"
        )
    }

    @MainActor
    func testStopAndSettleDiscardedEnforceTombstoneRedactionAndIdempotency() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
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
        let originalIdentity = discardAlert.sourceIdentity
        let originalDigest = discardAlert.contentDigest
        try await store.recordAnalysis(
            discardClaim,
            analysis: analysis,
            now: TestFixtures.receivedAt
        )
        try await store.recordSelectorResponse(
            discardClaim,
            response: DirectSelectorResponse(
                rawOutput: #"{"decision":"none"}"#,
                runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                requestJSON: #"{"message":"sensitive"}"#,
                completion: "complete"
            ),
            startedAt: TestFixtures.receivedAt,
            now: TestFixtures.receivedAt
        )
        try await store.recordNormalizedResult(
            discardClaim,
            semanticResultJSON: #"{"sensitive":"Card statement INR 50.00 ready."}"#,
            decision: "none",
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
        XCTAssertEqual(persistedDiscard.sourceIdentity, originalIdentity)
        XCTAssertEqual(persistedDiscard.contentDigest, originalDigest)
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
        XCTAssertNil(
            try verification.fetch(FetchDescriptor<SmsReconstructedResult>()).first?.semanticResultJSON
        )
    }

    @MainActor
    func testLaterLedgerEditAppendsLegacyBaselineFeedbackRevisionAndValidatesConflicts() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
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
        let database = try TestFixtures.makeInMemoryDatabase()
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
            claim,
            analysis: analysis,
            now: TestFixtures.receivedAt
        )
        try await store.recordNormalizedResult(
            claim,
            semanticResultJSON: resultJSON,
            decision: "posted",
            now: TestFixtures.receivedAt
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

    @MainActor
    func testReviewRejectTombstonesAlertPreservesIdentityAndScrubsAllOperations() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let rawBody = "INR 900.00 debited from account **4444 at Sensitive Vendor."
        let alert = TestFixtures.makeAlert(body: rawBody, sender: "AX-SENSITIVE")
        let originalIdentity = alert.sourceIdentity
        let originalDigest = alert.contentDigest
        context.insert(alert)
        try context.save()

        let factory = SmsOperationSnapshotFactory(context: context)
        let firstOp = try factory.create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        let store = SmsProcessingStore.shared(for: database.container)
        let firstClaim = try await store.claim(operationID: firstOp.operationID, now: TestFixtures.receivedAt)
        let firstAnalysis = try StructuralSmsAnalyzer().analyze(source: rawBody, operation: firstOp)
        try await store.recordAnalysis(firstClaim, analysis: firstAnalysis, now: TestFixtures.receivedAt)
        try await store.recordSelectorResponse(
            firstClaim,
            response: DirectSelectorResponse(
                rawOutput: #"{"decision":"abstain"}"#,
                runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                requestJSON: #"{"message":"INR 900.00 debited from account **4444 at Sensitive Vendor."}"#,
                completion: "complete"
            ),
            startedAt: TestFixtures.receivedAt,
            now: TestFixtures.receivedAt
        )
        try await store.recordNormalizedResult(
            firstClaim,
            semanticResultJSON: #"{"raw":"Sensitive Vendor"}"#,
            decision: "abstain",
            now: TestFixtures.receivedAt
        )
        let reviewID = try await store.retainForReview(
            firstClaim,
            reasons: ["extractor_abstained"],
            now: TestFixtures.receivedAt
        )

        let secondOp = try factory.create(
            sourceAlertID: alert.id,
            parentOperationID: firstOp.operationID,
            trigger: "retry",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt.addingTimeInterval(5)
        )
        let secondClaim = try await store.claim(
            operationID: secondOp.operationID,
            now: TestFixtures.receivedAt.addingTimeInterval(5)
        )
        let secondAnalysis = try StructuralSmsAnalyzer().analyze(source: rawBody, operation: secondOp)
        try await store.recordAnalysis(secondClaim, analysis: secondAnalysis, now: TestFixtures.receivedAt)
        try await store.recordSelectorResponse(
            secondClaim,
            response: DirectSelectorResponse(
                rawOutput: #"{"decision":"abstain"}"#,
                runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                requestJSON: #"{"message":"Sensitive Vendor second"}"#,
                completion: "complete"
            ),
            startedAt: TestFixtures.receivedAt,
            now: TestFixtures.receivedAt
        )
        try await store.recordNormalizedResult(
            secondClaim,
            semanticResultJSON: #"{"raw":"Sensitive Vendor second"}"#,
            decision: "abstain",
            now: TestFixtures.receivedAt
        )
        _ = try await store.retainForReview(
            secondClaim,
            reasons: ["extractor_abstained"],
            now: TestFixtures.receivedAt.addingTimeInterval(6)
        )

        // Save a draft containing raw SMS wording before rejecting.
        _ = try await store.resolveReview(
            ReviewCommand(
                actionID: UUID(),
                reviewCaseID: reviewID,
                expectedRevision: 0,
                kind: .saveDraft,
                corrections: [
                    SmsFieldCorrection(
                        field: "counterparty",
                        classification: .suppliedSourceSupportedCandidateMiss,
                        previousRevisionID: nil,
                        candidateID: nil,
                        evidence: nil,
                        scalarEvidence: try makeSpan(in: rawBody, matching: "Sensitive Vendor"),
                        newValue: "sensitive vendor"
                    )
                ],
                retryConfiguration: nil
            ),
            now: TestFixtures.receivedAt.addingTimeInterval(7)
        )

        let rejectReceipt = try await store.resolveReview(
            ReviewCommand(
                actionID: UUID(),
                reviewCaseID: reviewID,
                expectedRevision: 1,
                kind: .reject,
                corrections: [],
                retryConfiguration: nil
            ),
            now: TestFixtures.receivedAt.addingTimeInterval(8)
        )
        XCTAssertEqual(rejectReceipt.resultingRevision, 2)

        let verification = ModelContext(database.container)
        let persistedAlert = try XCTUnwrap(verification.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(persistedAlert.status, .rejected)
        XCTAssertEqual(persistedAlert.rejectionCode, "tombstoned_rejected")
        XCTAssertTrue(persistedAlert.rawBody.isEmpty)
        XCTAssertTrue(persistedAlert.sender.isEmpty)
        XCTAssertNil(persistedAlert.sourceApplication)
        XCTAssertEqual(persistedAlert.sourceIdentity, originalIdentity)
        XCTAssertEqual(persistedAlert.contentDigest, originalDigest)

        let analyses = try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>())
        XCTAssertEqual(analyses.count, 2)
        XCTAssertTrue(analyses.allSatisfy { $0.canonicalJSON == "{}" })

        let attempts = try verification.fetch(FetchDescriptor<SmsSelectorAttempt>())
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(attempts.allSatisfy { $0.requestJSON == "{}" && $0.rawOutput == nil })

        let results = try verification.fetch(FetchDescriptor<SmsReconstructedResult>())
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.semanticResultJSON == nil })

        let review = try XCTUnwrap(verification.fetch(FetchDescriptor<SmsReviewCase>()).first)
        XCTAssertEqual(review.state, .rejected)
        XCTAssertNil(review.draftJSON)
    }

    @MainActor
    func testEraseAllInvalidatesActiveClaimsAndBlocksInFlightWrites() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert(body: "INR 400.00 debited from account **8888 at Cafe.")
        context.insert(alert)
        try context.save()

        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let store = SmsProcessingStore.shared(for: database.container)
        let claim = try await store.claim(operationID: snapshot.operationID, now: TestFixtures.receivedAt)
        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)

        try LocalDataService(context: context).eraseAll()

        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordAnalysis(claim, analysis: analysis, now: TestFixtures.receivedAt)
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordSelectorResponse(
                claim,
                response: DirectSelectorResponse(
                    rawOutput: #"{"decision":"none"}"#,
                    runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
                    requestJSON: #"{"message":"INR 400.00 debited"}"#,
                    completion: "complete"
                ),
                startedAt: TestFixtures.receivedAt,
                now: TestFixtures.receivedAt
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }
        await TestFixtures.assertThrowsErrorAsync {
            try await store.recordNormalizedResult(
                claim,
                semanticResultJSON: #"{"body":"INR 400.00"}"#,
                decision: "posted",
                now: TestFixtures.receivedAt
            )
        } verify: { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .lostOwnership)
        }

        let verification = ModelContext(database.container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>()).isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsSelectorAttempt>()).isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsReconstructedResult>()).isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
    }

    @MainActor
    func testAmbiguousAndMigratedAccountResolutionLinksAliasCleanly() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let firstAccount = Account(name: "HDFC Debit", bank: "HDFC", kind: .account, suffix: "1234")
        let secondAccount = Account(name: "Axis Card", bank: "Axis", kind: .card, suffix: "1234")
        let migratedAccount = Account(name: "Migrated Savings", bank: "ICICI", kind: .account, suffix: "5678")
        context.insert(firstAccount)
        context.insert(secondAccount)
        context.insert(migratedAccount)
        for id in [firstAccount.id, secondAccount.id] {
            context.insert(
                SmsAccountAlias(
                    accountID: id,
                    normalizedAliasHash: CanonicalJSON.sha256("suffix:1234"),
                    aliasKind: "suffix",
                    matchingScope: "owned_account_v1",
                    confirmedByUser: true
                )
            )
        }
        try context.save()

        let store = SmsProcessingStore.shared(for: database.container)
        let ambiguousReviewID = try await seedGroundedReview(
            database: database,
            body: "INR 300.00 debited from account **1234 at Demo Cafe.",
            amountText: "INR 300.00",
            amountValue: "300.00",
            directionText: "debited",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "Demo Cafe"
        )
        let ambiguousDetails = try await store.loadReviewDetails(reviewCaseID: ambiguousReviewID)
        XCTAssertEqual(Set(ambiguousDetails.ambiguousAccountIDs), Set([firstAccount.id, secondAccount.id]))
        XCTAssertEqual(ambiguousDetails.primaryCurrency, "INR")

        await TestFixtures.assertThrowsErrorAsync {
            _ = try await store.resolveReview(
                ReviewCommand(
                    actionID: UUID(),
                    reviewCaseID: ambiguousReviewID,
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

        _ = try await store.resolveReview(
            ReviewCommand(
                actionID: UUID(),
                reviewCaseID: ambiguousReviewID,
                expectedRevision: 0,
                kind: .correct,
                corrections: [
                    SmsFieldCorrection(
                        field: "account_id",
                        classification: .selectedExistingCandidate,
                        previousRevisionID: nil,
                        candidateID: nil,
                        evidence: nil,
                        newValue: secondAccount.id.uuidString.lowercased()
                    )
                ],
                retryConfiguration: nil
            ),
            now: TestFixtures.receivedAt
        )

        let migratedReviewID = try await seedGroundedReview(
            database: database,
            body: "INR 150.00 debited from account **5678 at Metro Mart.",
            amountText: "INR 150.00",
            amountValue: "150.00",
            directionText: "debited",
            accountReference: "**5678",
            accountText: "**5678",
            counterpartyText: "Metro Mart"
        )
        let migratedDetails = try await store.loadReviewDetails(reviewCaseID: migratedReviewID)
        XCTAssertEqual(migratedDetails.suggestedAccountID, migratedAccount.id)

        _ = try await store.resolveReview(
            ReviewCommand(
                actionID: UUID(),
                reviewCaseID: migratedReviewID,
                expectedRevision: 0,
                kind: .correct,
                corrections: [
                    SmsFieldCorrection(
                        field: "account_id",
                        classification: .selectedExistingCandidate,
                        previousRevisionID: nil,
                        candidateID: nil,
                        evidence: nil,
                        newValue: migratedAccount.id.uuidString.lowercased()
                    )
                ],
                retryConfiguration: nil
            ),
            now: TestFixtures.receivedAt
        )

        let verification = ModelContext(database.container)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Account>()).count, 3)
        let resolved5678 = try await store.matchingAccountIDs(forNormalizedReference: "5678")
        XCTAssertEqual(resolved5678, [migratedAccount.id])
    }

    @MainActor
    func testDuplicateStatusIgnoresUnpersistedParentOpsAndReturnsRecentMatchSummaries() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let account = Account(name: "Main Card", bank: "HDFC", kind: .card, suffix: "2222")
        let alert = TestFixtures.makeAlert(body: "INR 750.00 debited from card **2222 at Store.")
        context.insert(account)
        context.insert(alert)
        try context.save()

        let factory = SmsOperationSnapshotFactory(context: context)
        let parentOp = try factory.create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
        let store = SmsProcessingStore.shared(for: database.container)
        let parentClaim = try await store.claim(operationID: parentOp.operationID, now: TestFixtures.receivedAt)
        _ = try await store.retainForReview(
            parentClaim,
            reasons: ["account_resolution_unresolved"],
            now: TestFixtures.receivedAt
        )

        let retryOp = try factory.create(
            sourceAlertID: alert.id,
            parentOperationID: parentOp.operationID,
            trigger: "retry",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt.addingTimeInterval(10)
        )
        let statusWithParentReview = try await store.duplicateStatus(
            operationID: retryOp.operationID,
            sourceID: alert.id,
            stableEventID: retryOp.stableEventID,
            accountID: account.id,
            direction: "debit",
            minorUnits: 75_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt
        )
        XCTAssertEqual(statusWithParentReview, "clear")

        let otherTransaction = Transaction(
            amountMinorUnits: 75_000,
            currencyCode: "INR",
            merchant: "Store",
            occurredAt: TestFixtures.receivedAt.addingTimeInterval(-60),
            direction: .debit,
            accountID: account.id,
            accountLabel: account.name,
            parserName: SmsContractAssets.releaseID,
            reviewState: .confirmed,
            sourceAlertID: UUID(),
            amountEvidenceText: "INR 750.00",
            dateEvidenceText: nil
        )
        context.insert(otherTransaction)
        try context.save()

        let statusWithRecentMatch = try await store.duplicateStatus(
            operationID: retryOp.operationID,
            sourceID: alert.id,
            stableEventID: retryOp.stableEventID,
            accountID: account.id,
            direction: "debit",
            minorUnits: 75_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt
        )
        XCTAssertEqual(statusWithRecentMatch, "possible_duplicate")

        let summaries = try await store.matchingDuplicateWindowTransactions(
            sourceID: alert.id,
            accountID: account.id,
            direction: "debit",
            minorUnits: 75_000,
            currency: "INR",
            occurredAt: TestFixtures.receivedAt
        )
        XCTAssertEqual(summaries.map(\.id), [otherTransaction.id])
    }

    @MainActor
    func testDeleteTransactionAtomicallyReopensReviewAndAllowsReconfirmation() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let context = database.container.mainContext
        let account = Account(name: "HDFC Checking", bank: "HDFC", kind: .account, suffix: "3333")
        context.insert(account)
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:3333"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        let body = "INR 200.00 paid from account **3333 at Bakery."
        let alert = TestFixtures.makeAlert(body: body)
        context.insert(alert)
        try context.save()

        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let rawOutput = try TestFixtures.strictPostedOutput(
            for: body,
            amountText: "INR 200.00",
            amountValue: "200.00",
            direction: "debit",
            directionText: "paid",
            accountReference: "**3333",
            accountText: "**3333",
            counterpartyText: "Bakery"
        )
        let store = SmsProcessingStore.shared(for: database.container)
        let coordinator = SmsProcessingCoordinator(
            store: store,
            extractor: FixedSmsExtractor(rawOutput: rawOutput),
            accountResolver: { _ in .unique(accountID: account.id) }
        )
        let outcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: alert.id,
                admissionReceiptID: alert.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: snapshot
        )
        guard case .persisted(_, let transactionIDs, _) = outcome,
            let transactionID = transactionIDs.first
        else {
            return XCTFail("Expected automatic persistence, got \(outcome)")
        }

        let deletedReviewID = try await store.deleteTransaction(
            transactionID: transactionID,
            now: TestFixtures.receivedAt.addingTimeInterval(20)
        )
        let reopenedReviewID = try XCTUnwrap(deletedReviewID)

        let verificationAfterDelete = ModelContext(database.container)
        XCTAssertTrue(try verificationAfterDelete.fetch(FetchDescriptor<Transaction>()).isEmpty)
        let revisionsAfterDelete = try verificationAfterDelete.fetch(FetchDescriptor<SmsTransactionRevision>())
        XCTAssertEqual(revisionsAfterDelete.count, 1)
        XCTAssertFalse(revisionsAfterDelete[0].isCurrentProjection)
        let alertAfterDelete = try XCTUnwrap(verificationAfterDelete.fetch(FetchDescriptor<InboxAlert>()).first)
        XCTAssertEqual(alertAfterDelete.status, .needsReview)
        XCTAssertNil(alertAfterDelete.transactionID)

        let details = try await store.loadReviewDetails(reviewCaseID: reopenedReviewID)
        XCTAssertEqual(details.duplicateStatus, "clear")
        XCTAssertNotNil(details.proposal)

        _ = try await store.resolveReview(
            ReviewCommand(
                actionID: UUID(),
                reviewCaseID: reopenedReviewID,
                expectedRevision: details.reviewRevision,
                kind: .confirm,
                corrections: [],
                retryConfiguration: nil
            ),
            now: TestFixtures.receivedAt.addingTimeInterval(30)
        )
        let verificationAfterReconfirm = ModelContext(database.container)
        XCTAssertEqual(try verificationAfterReconfirm.fetch(FetchDescriptor<Transaction>()).count, 1)
        let revisionsAfterReconfirm = try verificationAfterReconfirm.fetch(
            FetchDescriptor<SmsTransactionRevision>(sortBy: [SortDescriptor(\.revision)])
        )
        XCTAssertEqual(revisionsAfterReconfirm.map(\.revision), [0, 1])
        XCTAssertEqual(revisionsAfterReconfirm.map(\.isCurrentProjection), [false, true])
    }

    @MainActor
    func testLegacyBackfillSkipsV7TransactionsWithExistingRevisionsAndSharedStoreMatchesPerContainer() async throws {
        let database = try TestFixtures.makeInMemoryDatabase()
        let otherDatabase = try TestFixtures.makeInMemoryDatabase()
        let sharedA = SmsProcessingStore.shared(for: database.container)
        let sharedB = SmsProcessingStore.shared(for: database.container)
        let sharedOther = SmsProcessingStore.shared(for: otherDatabase.container)
        XCTAssertTrue(sharedA === sharedB)
        XCTAssertFalse(sharedA === sharedOther)

        let context = database.container.mainContext
        let legacyTx = Transaction(
            amountMinorUnits: 1_500,
            currencyCode: "INR",
            merchant: "Legacy Cafe",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: nil,
            accountLabel: nil,
            parserName: "V4",
            reviewState: .confirmed,
            sourceAlertID: UUID(),
            amountEvidenceText: "INR 15.00",
            dateEvidenceText: nil
        )
        let v7Tx = Transaction(
            amountMinorUnits: 2_500,
            currencyCode: "INR",
            merchant: "V7 Cafe",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: nil,
            accountLabel: nil,
            parserName: SmsContractAssets.releaseID,
            reviewState: .confirmed,
            sourceAlertID: UUID(),
            amountEvidenceText: "INR 25.00",
            dateEvidenceText: nil
        )
        context.insert(legacyTx)
        context.insert(v7Tx)
        context.insert(
            SmsTransactionRevision(
                transactionID: v7Tx.id,
                sourceAlertID: v7Tx.sourceAlertID,
                stableEventID: UUID(),
                revision: 0,
                previousRevisionID: nil,
                operationID: UUID(),
                feedbackActionID: nil,
                amountMinorUnits: 2_500,
                currencyCode: "INR",
                currencyScale: 2,
                direction: "debit",
                merchant: "V7 Cafe",
                accountID: nil,
                occurredAt: TestFixtures.receivedAt,
                provenance: "automatic_grounded_extraction",
                isCurrentProjection: true
            )
        )
        try context.save()

        try await sharedA.backfillLegacyTransactions(now: TestFixtures.receivedAt)
        try await sharedA.backfillLegacyTransactions(now: TestFixtures.receivedAt)

        let verification = ModelContext(database.container)
        let snapshots = try verification.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>())
        XCTAssertEqual(snapshots.map(\.transactionID), [legacyTx.id])
    }

    private func makeSpan(in source: String, matching substring: String) throws -> UnicodeScalarSpan {
        let range = try XCTUnwrap(source.range(of: substring))
        let start = source[..<range.lowerBound].unicodeScalars.count
        let end = start + source[range].unicodeScalars.count
        return try UnicodeScalarSpan(source: source, startScalar: start, endScalar: end, text: substring)
    }
}
