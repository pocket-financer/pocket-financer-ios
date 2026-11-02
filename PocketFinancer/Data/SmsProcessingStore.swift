import CryptoKit
import Foundation
import SwiftData

enum SmsProcessingStoreError: Error, Equatable, Sendable {
    case sourceNotFound
    case operationNotFound
    case reviewCaseNotFound
    case configurationMismatch
    case stateConflict
    case lostOwnership
    case revisionConflict
    case invalidCommand
    case saveFailed
}

struct SmsOperationClaim: Equatable, Sendable {
    let operationID: UUID
    let ownerToken: UUID
    let generation: Int64
    let expiresAt: Date
}

@ModelActor
actor SmsProcessingStore {
    static let claimLease: TimeInterval = 120

    func operation(id: UUID) throws -> SmsProcessingOperation? {
        let operationID = id
        return try modelContext.fetch(
            FetchDescriptor<SmsProcessingOperation>(predicate: #Predicate { $0.id == operationID })
        ).first
    }

    private func reviewCase(operationID: UUID) throws -> SmsReviewCase? {
        let targetID = operationID
        return try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate { $0.currentOperationID == targetID }
            )
        ).first
    }

    func claim(operationID: UUID, now: Date = .now) throws -> SmsOperationClaim {
        guard let operation = try operation(id: operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        if operation.settledAt != nil {
            throw SmsProcessingStoreError.stateConflict
        }
        if operation.ownerToken != nil {
            guard let expiresAt = operation.claimExpiresAt, expiresAt <= now else {
                throw SmsProcessingStoreError.lostOwnership
            }
        }
        let ownerToken = UUID()
        let expiresAt = now.addingTimeInterval(Self.claimLease)
        operation.ownerGeneration += 1
        operation.ownerToken = ownerToken
        operation.claimExpiresAt = expiresAt
        operation.state = .claimed
        operation.transitionSequence += 1
        operation.updatedAt = now
        try saveOrRollback()
        return SmsOperationClaim(
            operationID: operationID,
            ownerToken: ownerToken,
            generation: operation.ownerGeneration,
            expiresAt: expiresAt
        )
    }

    func heartbeat(_ claim: SmsOperationClaim, now: Date = .now) throws -> SmsOperationClaim {
        let operation = try requireOwned(claim, now: now)
        let expiresAt = now.addingTimeInterval(Self.claimLease)
        operation.claimExpiresAt = expiresAt
        operation.updatedAt = now
        try saveOrRollback()
        return SmsOperationClaim(
            operationID: claim.operationID,
            ownerToken: claim.ownerToken,
            generation: claim.generation,
            expiresAt: expiresAt
        )
    }

    func transition(
        _ claim: SmsOperationClaim,
        expected: SmsOperationState,
        to next: SmsOperationState,
        now: Date = .now
    ) throws {
        let operation = try requireOwned(claim, now: now)
        guard operation.state == expected else { throw SmsProcessingStoreError.stateConflict }
        operation.state = next
        operation.transitionSequence += 1
        operation.updatedAt = now
        try saveOrRollback()
    }

    func appendTrace(
        _ claim: SmsOperationClaim,
        stage: String,
        status: String,
        reasonCodes: [String] = [],
        detailJSON: String? = nil,
        now: Date = .now
    ) throws -> SmsTraceReceipt {
        _ = try requireOwned(claim, now: now)
        let operationID = claim.operationID
        let existing = try modelContext.fetch(
            FetchDescriptor<SmsProcessingTraceEvent>(
                predicate: #Predicate { $0.operationID == operationID },
                sortBy: [SortDescriptor(\.sequence)]
            )
        )
        let sequence = existing.count
        let previousHash = existing.last?.eventHash
        let eventID = UUID()
        let payload = TraceHashPayload(
            sequence: sequence,
            eventID: eventID.uuidString.lowercased(),
            occurredAtEpochMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
            stage: stage,
            status: status,
            reasonCodes: reasonCodes,
            detailJSON: detailJSON,
            previousEventHash: previousHash
        )
        let event = SmsProcessingTraceEvent(
            id: eventID,
            operationID: operationID,
            sequence: sequence,
            occurredAt: now,
            stage: stage,
            status: status,
            reasonCodes: reasonCodes,
            detailJSON: detailJSON,
            previousEventHash: previousHash,
            eventHash: try CanonicalJSON.sha256(payload)
        )
        modelContext.insert(event)
        try saveOrRollback()
        return SmsTraceReceipt(eventID: eventID, sequence: sequence, eventHash: event.eventHash)
    }

    /// Idempotently records the exact stored state available for pre-V5 transactions.
    /// It deliberately does not claim that an edited row's original extraction is known.
    func backfillLegacyTransactions(now: Date = .now) throws {
        let transactions = try modelContext.fetch(FetchDescriptor<Transaction>())
        let snapshots = try modelContext.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>())
        let snapshottedIDs = Set(snapshots.map(\.transactionID))
        let revisions = try modelContext.fetch(FetchDescriptor<SmsTransactionRevision>())
        let revisionTransactionIDs = Set(revisions.map(\.transactionID))

        for transaction in transactions where !snapshottedIDs.contains(transaction.id) {
            modelContext.insert(SmsLegacyTransactionSnapshot(transaction: transaction, capturedAt: now))
            guard !revisionTransactionIDs.contains(transaction.id) else { continue }
            modelContext.insert(
                SmsTransactionRevision(
                    transactionID: transaction.id,
                    sourceAlertID: transaction.sourceAlertID,
                    stableEventID: transaction.id,
                    revision: 0,
                    previousRevisionID: nil,
                    operationID: nil,
                    feedbackActionID: nil,
                    amountMinorUnits: transaction.amountMinorUnits,
                    currencyCode: transaction.currencyCode,
                    currencyScale: CurrencyFormatter.supportedScales[
                        transaction.currencyCode.uppercased()
                    ],
                    direction: transaction.directionRawValue,
                    merchant: transaction.merchant,
                    accountID: transaction.accountID,
                    occurredAt: transaction.occurredAt,
                    provenance: "legacy_current_state_original_history_unknown",
                    isCurrentProjection: true,
                    createdAt: now
                )
            )
        }
        try saveOrRollback()
    }

    func retainForReview(
        _ claim: SmsOperationClaim,
        reasons: [String],
        now: Date = .now
    ) throws -> UUID {
        let operation = try requireOwned(claim, now: now)
        let operationID = claim.operationID
        let cases = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate {
                    $0.currentOperationID == operationID
                })
        )
        let reviewCase: SmsReviewCase
        if let existing = cases.first {
            reviewCase = existing
        } else if let parentOperationID = operation.parentOperationID {
            let parentID = parentOperationID
            if let retried = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(
                    predicate: #Predicate { $0.currentOperationID == parentID }
                )
            ).first {
                reviewCase = retried
                reviewCase.currentOperationID = operationID
                reviewCase.reasonCodesRawValue = reasons.joined(separator: "\n")
                reviewCase.state = .open
                reviewCase.updatedAt = now
                var stableIDs = Set(
                    reviewCase.stableEventIDsRawValue.split(separator: "\n").map(String.init)
                )
                stableIDs.insert(operation.stableEventID.uuidString)
                reviewCase.stableEventIDsRawValue = stableIDs.sorted().joined(separator: "\n")
            } else {
                reviewCase = SmsReviewCase(
                    sourceAlertID: operation.sourceAlertID,
                    currentOperationID: operationID,
                    reasonCodes: reasons,
                    stableEventIDs: [operation.stableEventID]
                )
                modelContext.insert(reviewCase)
            }
        } else {
            reviewCase = SmsReviewCase(
                sourceAlertID: operation.sourceAlertID,
                currentOperationID: operationID,
                reasonCodes: reasons,
                stableEventIDs: [operation.stableEventID]
            )
            modelContext.insert(reviewCase)
        }
        operation.state = .retainedReview
        operation.transitionSequence += 1
        operation.updatedAt = now
        operation.settledAt = now
        operation.settlementReceiptJSON = try CanonicalJSON.string(
            ReviewSettlement(reviewCaseID: reviewCase.id, reasons: reasons)
        )
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        try saveOrRollback()
        return reviewCase.id
    }

    func stop(operationID: UUID, now: Date = .now) throws -> StopReceipt {
        guard let operation = try operation(id: operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        if operation.settledAt != nil {
            return StopReceipt(
                operationID: operationID,
                reviewCaseID: try reviewCase(operationID: operationID)?.id,
                state: operation.state,
                committed: operation.state == .persisted
            )
        }
        operation.ownerGeneration += 1
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        operation.state = .interrupted
        operation.transitionSequence += 1
        operation.updatedAt = now
        try saveOrRollback()
        let reviewID = try retainUnownedForReview(
            operationID: operationID,
            reasons: ["operation_interrupted"],
            now: now
        )
        return StopReceipt(
            operationID: operationID,
            reviewCaseID: reviewID,
            state: .retainedReview,
            committed: false
        )
    }

    /// Fences work abandoned by a terminated process and makes the admitted
    /// evidence visible in review. A live lease is never stolen.
    @discardableResult
    func recoverExpiredOperations(now: Date = .now) throws -> [UUID] {
        let cutoff = now.addingTimeInterval(-Self.claimLease)
        let operations = try modelContext.fetch(
            FetchDescriptor<SmsProcessingOperation>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
        var reviewIDs: [UUID] = []
        for operation in operations where operation.settledAt == nil && operation.updatedAt <= cutoff {
            let hasLiveLease =
                operation.ownerToken != nil
                && operation.claimExpiresAt.map { $0 > now } == true
            guard !hasLiveLease else { continue }

            // Fence an expired or malformed owner before using the unowned recovery path.
            if operation.ownerToken != nil {
                operation.ownerGeneration += 1
                operation.ownerToken = nil
                operation.claimExpiresAt = nil
            }
            try appendRecoveryTrace(operation: operation, now: now)
            reviewIDs.append(
                try retainUnownedForReview(
                    operationID: operation.id,
                    reasons: ["operation_interrupted"],
                    now: now
                )
            )
        }
        return reviewIDs
    }

    func resolveReview(_ command: ReviewCommand, now: Date = .now) throws -> ReviewReceipt {
        let actionID = command.actionID
        if let replay = try modelContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(
                predicate: #Predicate {
                    $0.actionID == actionID
                })
        ).first {
            guard let replayReviewCaseID = replay.reviewCaseID,
                replayReviewCaseID == command.reviewCaseID
            else {
                throw SmsProcessingStoreError.invalidCommand
            }
            return ReviewReceipt(
                actionID: actionID,
                reviewCaseID: replayReviewCaseID,
                resultingRevision: replay.resultingReviewRevision,
                replayed: true
            )
        }
        let reviewID = command.reviewCaseID
        guard
            let review = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(predicate: #Predicate { $0.id == reviewID })
            ).first
        else {
            throw SmsProcessingStoreError.reviewCaseNotFound
        }
        guard review.revision == command.expectedRevision else {
            throw SmsProcessingStoreError.revisionConflict
        }
        guard validate(command) else { throw SmsProcessingStoreError.invalidCommand }
        let resultingRevision = command.expectedRevision + 1
        let previousEventHash = try latestFeedbackHash(reviewCaseID: reviewID)
        let correctionsJSON = try CanonicalJSON.string(command.corrections)
        let eventHash = try CanonicalJSON.sha256(
            FeedbackHashPayload(
                actionID: actionID.uuidString.lowercased(),
                reviewCaseID: reviewID.uuidString.lowercased(),
                operationID: review.currentOperationID.uuidString.lowercased(),
                expectedRevision: command.expectedRevision,
                resultingRevision: resultingRevision,
                action: command.kind.rawValue,
                correctionsJSON: correctionsJSON,
                retryConfiguration: command.retryConfiguration,
                previousEventHash: previousEventHash
            )
        )
        let feedback = SmsUserFeedbackEvent(
            actionID: actionID,
            reviewCaseID: reviewID,
            operationID: review.currentOperationID,
            transactionRevisionID: nil,
            expectedReviewRevision: command.expectedRevision,
            resultingReviewRevision: resultingRevision,
            action: command.kind.rawValue,
            actorClass: "user",
            correctionsJSON: correctionsJSON,
            retryConfiguration: command.retryConfiguration,
            previousEventHash: previousEventHash,
            eventHash: eventHash,
            createdAt: now
        )
        if command.kind == .confirm || command.kind == .correct {
            feedback.transactionRevisionID = try projectReview(
                review: review,
                command: command,
                feedbackActionID: actionID,
                now: now
            )
        }
        modelContext.insert(feedback)
        review.revision = resultingRevision
        review.updatedAt = now
        review.state =
            switch command.kind {
            case .confirm, .resolveMultipleEvents: .confirmed
            case .correct: .corrected
            case .reject: .rejected
            case .saveDraft: .draft
            case .retry: .waitingRetry
            }
        if command.kind == .saveDraft || command.kind == .correct {
            review.draftJSON = correctionsJSON
        }
        try saveOrRollback()
        return ReviewReceipt(
            actionID: actionID,
            reviewCaseID: reviewID,
            resultingRevision: resultingRevision,
            replayed: false
        )
    }

    /// Applies a user-authorized edit to an existing ledger projection while
    /// preserving both the prior projection and an append-only feedback event.
    func editTransactionProjection(
        _ command: TransactionProjectionEditCommand,
        now: Date = .now
    ) throws -> TransactionProjectionEditReceipt {
        let actionID = command.actionID
        if let replay = try modelContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(
                predicate: #Predicate { $0.actionID == actionID }
            )
        ).first {
            guard replay.transactionID == command.transactionID else {
                throw SmsProcessingStoreError.invalidCommand
            }
            return TransactionProjectionEditReceipt(
                actionID: actionID,
                transactionID: command.transactionID,
                resultingRevision: replay.resultingReviewRevision,
                replayed: true
            )
        }
        let transactionID = command.transactionID
        guard
            command.amountMinorUnits > 0,
            let scale = CurrencyFormatter.supportedScales[command.currencyCode.uppercased()],
            !command.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let transaction = try modelContext.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == transactionID })
            ).first
        else { throw SmsProcessingStoreError.invalidCommand }
        let accountID = command.accountID
        guard
            let account = try modelContext.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == accountID })
            ).first
        else { throw SmsProcessingStoreError.invalidCommand }

        var revisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate { $0.transactionID == transactionID },
                sortBy: [SortDescriptor(\.revision)]
            )
        )
        let current = revisions.last(where: \.isCurrentProjection)
        guard current?.revision ?? -1 == command.expectedRevision else {
            throw SmsProcessingStoreError.revisionConflict
        }
        if current == nil {
            let legacy = SmsTransactionRevision(
                transactionID: transaction.id,
                sourceAlertID: transaction.sourceAlertID,
                stableEventID: transaction.id,
                revision: 0,
                previousRevisionID: nil,
                operationID: nil,
                feedbackActionID: nil,
                amountMinorUnits: transaction.amountMinorUnits,
                currencyCode: transaction.currencyCode,
                currencyScale: CurrencyFormatter.supportedScales[transaction.currencyCode.uppercased()],
                direction: transaction.direction.rawValue,
                merchant: transaction.merchant,
                accountID: transaction.accountID,
                occurredAt: transaction.occurredAt,
                provenance: "legacy_current_state_original_history_unknown",
                isCurrentProjection: true,
                createdAt: now
            )
            modelContext.insert(legacy)
            revisions.append(legacy)
        }
        guard let previous = revisions.last(where: \.isCurrentProjection) else {
            throw SmsProcessingStoreError.stateConflict
        }
        previous.isCurrentProjection = false
        let resultingRevision = previous.revision + 1
        let correctionsJSON = try CanonicalJSON.string(command.corrections)
        let previousEventHash = try latestFeedbackHash(transactionID: transactionID)
        let eventHash = try CanonicalJSON.sha256(
            ProjectionFeedbackHashPayload(
                actionID: actionID.uuidString.lowercased(),
                transactionID: transactionID.uuidString.lowercased(),
                expectedRevision: command.expectedRevision,
                resultingRevision: resultingRevision,
                action: command.corrections.isEmpty ? "confirmed_unchanged" : "correct",
                correctionsJSON: correctionsJSON,
                previousEventHash: previousEventHash
            )
        )
        let revision = SmsTransactionRevision(
            transactionID: transactionID,
            sourceAlertID: transaction.sourceAlertID,
            stableEventID: previous.stableEventID,
            revision: resultingRevision,
            previousRevisionID: previous.id,
            operationID: previous.operationID,
            feedbackActionID: actionID,
            amountMinorUnits: command.amountMinorUnits,
            currencyCode: command.currencyCode.uppercased(),
            currencyScale: scale,
            direction: command.direction.rawValue,
            merchant: command.merchant,
            accountID: accountID,
            occurredAt: command.occurredAt,
            provenance: command.corrections.isEmpty
                ? "user_confirmed_unchanged_projection"
                : "user_corrected_projection",
            isCurrentProjection: true,
            createdAt: now
        )
        let feedback = SmsUserFeedbackEvent(
            actionID: actionID,
            reviewCaseID: nil,
            operationID: previous.operationID,
            transactionID: transactionID,
            transactionRevisionID: revision.id,
            expectedReviewRevision: command.expectedRevision,
            resultingReviewRevision: resultingRevision,
            action: command.corrections.isEmpty ? "confirmed_unchanged" : "correct",
            actorClass: "user",
            correctionsJSON: correctionsJSON,
            retryConfiguration: nil,
            previousEventHash: previousEventHash,
            eventHash: eventHash,
            createdAt: now
        )

        transaction.amountMinorUnits = command.amountMinorUnits
        transaction.currencyCode = command.currencyCode.uppercased()
        transaction.direction = command.direction
        transaction.merchant = command.merchant
        transaction.accountID = accountID
        transaction.accountLabel = account.name
        transaction.occurredAt = command.occurredAt
        transaction.reviewState = .confirmed
        transaction.isEdited = transaction.isEdited || !command.corrections.isEmpty
        transaction.updatedAt = now
        let sourceID = transaction.sourceAlertID
        if let source = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        ).first {
            source.status = .imported
            source.lastErrorCode = nil
            source.updatedAt = now
        }
        modelContext.insert(revision)
        modelContext.insert(feedback)
        try saveOrRollback()
        return TransactionProjectionEditReceipt(
            actionID: actionID,
            transactionID: transactionID,
            resultingRevision: resultingRevision,
            replayed: false
        )
    }

    private func projectReview(
        review: SmsReviewCase,
        command: ReviewCommand,
        feedbackActionID: UUID,
        now: Date
    ) throws -> UUID {
        let operationID = review.currentOperationID
        guard let operation = try operation(id: operationID) else {
            throw SmsProcessingStoreError.invalidCommand
        }
        let storedResult = try modelContext.fetch(
            FetchDescriptor<SmsReconstructedResult>(
                predicate: #Predicate { $0.operationID == operationID }
            )
        ).first
        if storedResult?.contractVersion == "pocketfinancer.processing-result/3" {
            guard let storedResult else { throw SmsProcessingStoreError.invalidCommand }
            return try projectV4Review(
                review: review,
                operation: operation,
                storedResult: storedResult,
                command: command,
                feedbackActionID: feedbackActionID,
                now: now
            )
        }
        let result = storedResult?.semanticResultJSON.flatMap {
            try? JSONDecoder().decode(
                ReconstructedSmsTransaction.self, from: Data($0.utf8)
            )
        }
        if command.kind == .confirm, result == nil {
            throw SmsProcessingStoreError.invalidCommand
        }

        var amount = result?.minorUnits
        var currency = result?.currency.uppercased()
        var direction = result?.direction
        var merchant = result.map { $0.counterpartyEvidence?.text ?? "Unspecified counterparty" }
        var accountID = result == nil ? nil : try uniquelyResolvedAccountID(operationID: operationID)
        var newAccountName: String?
        var newAccountBank: String?
        var newAccountKind: AccountKind?
        var newAccountSuffix: String?
        var occurredAt = result?.occurredAtEpochMilliseconds.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        }
        for correction in command.corrections {
            switch correction.field {
            case "amount_minor_units":
                guard let value = Int64(correction.newValue), value > 0 else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                amount = value
            case "currency":
                let value = correction.newValue.uppercased()
                guard CurrencyFormatter.supportedScales[value] != nil else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                currency = value
            case "direction":
                guard TransactionDirection(rawValue: correction.newValue) != nil else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                direction = correction.newValue
            case "counterparty":
                guard !correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                merchant = correction.newValue
            case "account_id":
                guard let value = UUID(uuidString: correction.newValue) else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let targetID = value
                guard
                    try modelContext.fetch(
                        FetchDescriptor<Account>(predicate: #Predicate { $0.id == targetID })
                    ).first != nil
                else { throw SmsProcessingStoreError.invalidCommand }
                accountID = value
            case "new_account_name":
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw SmsProcessingStoreError.invalidCommand }
                newAccountName = value
            case "new_account_bank":
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                newAccountBank = value.isEmpty ? nil : value
            case "new_account_kind":
                guard let value = AccountKind(rawValue: correction.newValue) else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                newAccountKind = value
            case "new_account_suffix":
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    value.isEmpty
                        || (value.count >= 2 && value.count <= 8 && value.allSatisfy(\.isNumber))
                else { throw SmsProcessingStoreError.invalidCommand }
                newAccountSuffix = value.isEmpty ? nil : value
            case "occurred_at_epoch_ms":
                guard let value = Int64(correction.newValue), value >= 0 else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                occurredAt = Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
            default:
                throw SmsProcessingStoreError.invalidCommand
            }
        }
        guard
            let amount,
            amount > 0,
            let currency,
            let scale = CurrencyFormatter.supportedScales[currency],
            let occurredAt,
            let direction,
            let transactionDirection = TransactionDirection(rawValue: direction),
            let merchant,
            !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !(accountID != nil && newAccountName != nil)
        else { throw SmsProcessingStoreError.invalidCommand }

        if accountID == nil {
            guard let newAccountName else { throw SmsProcessingStoreError.invalidCommand }
            let account = Account(
                name: newAccountName,
                bank: newAccountBank ?? newAccountName,
                kind: newAccountKind ?? .unknown,
                suffix: newAccountSuffix,
                now: now
            )
            modelContext.insert(account)
            accountID = account.id
        }
        guard let accountID else { throw SmsProcessingStoreError.invalidCommand }

        let sourceID = review.sourceAlertID
        guard
            let alert = try modelContext.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
            ).first
        else { throw SmsProcessingStoreError.sourceNotFound }
        let currentRevisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate { $0.sourceAlertID == sourceID && $0.isCurrentProjection }
            )
        )
        for revision in currentRevisions {
            revision.isCurrentProjection = false
        }
        let previous = currentRevisions.max { $0.revision < $1.revision }
        let transaction: Transaction
        if let existingID = alert.transactionID {
            let targetID = existingID
            guard
                let existing = try modelContext.fetch(
                    FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == targetID })
                ).first
            else { throw SmsProcessingStoreError.stateConflict }
            existing.amountMinorUnits = amount
            existing.currencyCode = currency
            existing.merchant = merchant
            existing.occurredAt = occurredAt
            existing.direction = transactionDirection
            existing.accountID = accountID
            existing.accountLabel = try accountName(id: accountID)
            existing.reviewState = .confirmed
            existing.isEdited = command.kind == .correct
            existing.updatedAt = now
            transaction = existing
        } else {
            let amountEvidence =
                try result.map {
                    try amountEvidenceText(
                        operationID: operationID,
                        candidateID: $0.amountCandidateID
                    )
                } ?? ""
            transaction = Transaction(
                amountMinorUnits: amount,
                currencyCode: currency,
                merchant: merchant,
                occurredAt: occurredAt,
                direction: transactionDirection,
                accountID: accountID,
                accountLabel: try accountName(id: accountID),
                isEdited: command.kind == .correct,
                parserName: result == nil ? "manual-review-entry" : "grounded-candidate-selector",
                reviewState: .confirmed,
                sourceAlertID: sourceID,
                amountEvidenceText: amountEvidence,
                dateEvidenceText: nil,
                now: now
            )
            modelContext.insert(transaction)
            alert.transactionID = transaction.id
        }
        alert.status = .imported
        alert.lastErrorCode = nil
        alert.updatedAt = now
        let revision = SmsTransactionRevision(
            transactionID: transaction.id,
            sourceAlertID: sourceID,
            stableEventID: operation.stableEventID,
            revision: (previous?.revision ?? -1) + 1,
            previousRevisionID: previous?.id,
            operationID: operationID,
            feedbackActionID: feedbackActionID,
            amountMinorUnits: amount,
            currencyCode: currency,
            currencyScale: scale,
            direction: direction,
            merchant: merchant,
            accountID: accountID,
            occurredAt: occurredAt,
            provenance:
                command.kind == .confirm
                ? "user_confirmed_grounded_proposal"
                : result == nil ? "user_supplied_review_transaction" : "user_corrected_projection",
            isCurrentProjection: true,
            createdAt: now
        )
        modelContext.insert(revision)
        return revision.id
    }

    private func projectV4Review(
        review: SmsReviewCase,
        operation: SmsProcessingOperation,
        storedResult: SmsReconstructedResult,
        command: ReviewCommand,
        feedbackActionID: UUID,
        now: Date
    ) throws -> UUID {
        let sourceID = review.sourceAlertID
        let targetOperationID = operation.id
        guard
            operation.contractReleaseID == NativeSmsV4Assets.releaseID,
            SmsV4ProcessingJSON.configurationMatches(
                configurationJSON: operation.configurationJSON,
                configurationHash: operation.configurationHash
            ),
            let configuration = try? JSONSerialization.jsonObject(
                with: Data(operation.configurationJSON.utf8)
            ) as? [String: Any],
            configuration["contract"] as? String == "pocketfinancer.processing-config/4",
            let contractRelease = configuration["contract_release"] as? [String: Any],
            contractRelease["release_id"] as? String == NativeSmsV4Assets.releaseID,
            let persistencePolicy = configuration["persistence_policy"] as? [String: Any],
            persistencePolicy["rollout_mode"] as? String == "review_only",
            configuration["source_ref_hash"] as? String
                == CanonicalJSON.sha256(sourceID.uuidString.lowercased()),
            let alert = try modelContext.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
            ).first,
            !alert.rawBody.isEmpty,
            alert.transactionID == nil,
            let analysis = try modelContext.fetch(
                FetchDescriptor<SmsProcessingAnalysis>(
                    predicate: #Predicate { $0.operationID == targetOperationID }
                )
            ).first,
            analysis.configurationHash == operation.configurationHash,
            analysis.sourceHash == CanonicalJSON.sha256(alert.rawBody),
            let base = SmsReviewProjection.parse(
                resultJSON: storedResult.semanticResultJSON,
                source: alert.rawBody
            ),
            base.duplicateIdempotencyKey == sourceID.uuidString.lowercased(),
            base.duplicateSourceEventKey == operation.stableEventID.uuidString.lowercased(),
            base.duplicateStatus != "already_persisted"
        else { throw SmsProcessingStoreError.invalidCommand }
        let allowed = Set(["amount", "direction", "account", "counterparty"])
        guard command.corrections.allSatisfy({ allowed.contains($0.field) }) else {
            throw SmsProcessingStoreError.invalidCommand
        }
        let projection = try SmsReviewProjection.applying(
            command.corrections,
            to: base,
            source: alert.rawBody
        )
        let stableEventID = operation.stableEventID
        let existingRevisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate {
                    ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
                        && $0.isCurrentProjection
                }
            )
        )
        guard existingRevisions.isEmpty else { throw SmsProcessingStoreError.stateConflict }
        guard
            let direction = TransactionDirection(rawValue: projection.direction),
            let currencyScale = CurrencyFormatter.supportedScales[projection.currency]
        else {
            throw SmsProcessingStoreError.invalidCommand
        }
        let merchant = projection.counterparty ?? "Unspecified counterparty"

        guard
            let normalizedReference = SmsExtractorNormalizer.normalizeAccount(
                projection.accountReference
            )
        else { throw SmsProcessingStoreError.invalidCommand }
        let aliasKind = normalizedReference.contains("@") ? "vpa" : "suffix"
        let aliasHash = CanonicalJSON.sha256("\(aliasKind):\(normalizedReference)")
        let confirmed = true
        let scope = "owned_account_v1"
        let aliases = try modelContext.fetch(
            FetchDescriptor<SmsAccountAlias>(
                predicate: #Predicate {
                    $0.normalizedAliasHash == aliasHash
                        && $0.confirmedByUser == confirmed
                        && $0.matchingScopeRawValue == scope
                }
            )
        )
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let matches = Array(Set(aliases.map(\.accountID))).compactMap { accountsByID[$0] }
        guard matches.count <= 1 else { throw SmsProcessingStoreError.invalidCommand }
        let account: Account
        if let existing = matches.first {
            account = existing
        } else {
            let suffix = aliasKind == "suffix" ? normalizedReference : nil
            let accountID = try deterministicReviewUUID(
                "account\0\(scope)\0\(aliasKind)\0\(aliasHash)"
            )
            let aliasID = try deterministicReviewUUID(
                "alias\0\(scope)\0\(aliasKind)\0\(aliasHash)"
            )
            account = Account(
                id: accountID,
                name: aliasKind == "vpa"
                    ? "UPI account \(normalizedReference)"
                    : "Account ••\(normalizedReference.suffix(4))",
                bank: alert.sender.isEmpty ? "Unknown Account" : alert.sender,
                kind: aliasKind == "vpa" ? .account : .card,
                suffix: suffix,
                now: now
            )
            modelContext.insert(account)
            modelContext.insert(
                SmsAccountAlias(
                    id: aliasID,
                    accountID: account.id,
                    normalizedAliasHash: aliasHash,
                    aliasKind: aliasKind,
                    matchingScope: scope,
                    confirmedByUser: true,
                    createdAt: now
                )
            )
        }

        let transaction = Transaction(
            amountMinorUnits: projection.amountMinorUnits,
            currencyCode: projection.currency,
            merchant: merchant,
            occurredAt: projection.receiptTimestamp,
            direction: direction,
            accountID: account.id,
            accountLabel: account.name,
            isEdited: !command.corrections.isEmpty,
            parserName: "direct-sms-extractor-v4",
            reviewState: .confirmed,
            sourceAlertID: sourceID,
            amountEvidenceText: projection.amountSpan.text,
            dateEvidenceText: nil,
            now: now
        )
        modelContext.insert(transaction)
        alert.transactionID = transaction.id
        alert.status = .imported
        alert.lastErrorCode = nil
        alert.updatedAt = now
        let revision = SmsTransactionRevision(
            transactionID: transaction.id,
            sourceAlertID: sourceID,
            stableEventID: operation.stableEventID,
            revision: 0,
            previousRevisionID: nil,
            operationID: operation.id,
            feedbackActionID: feedbackActionID,
            amountMinorUnits: projection.amountMinorUnits,
            currencyCode: projection.currency,
            currencyScale: currencyScale,
            direction: direction.rawValue,
            merchant: merchant,
            accountID: account.id,
            occurredAt: projection.receiptTimestamp,
            provenance: command.corrections.isEmpty
                ? "user_confirmed_grounded_proposal"
                : "user_confirmed_source_span_revision",
            isCurrentProjection: true,
            createdAt: now
        )
        modelContext.insert(revision)
        return revision.id
    }

    private func deterministicReviewUUID(_ seed: String) throws -> UUID {
        let hex = CanonicalJSON.sha256(seed)
        let first = String(hex.prefix(8))
        let second = String(hex.dropFirst(8).prefix(4))
        let third = String(hex.dropFirst(12).prefix(4))
        let fourth = String(hex.dropFirst(16).prefix(4))
        let fifth = String(hex.dropFirst(20).prefix(12))
        let value = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        guard let identifier = UUID(uuidString: value) else {
            throw SmsProcessingStoreError.invalidCommand
        }
        return identifier
    }

    private func uniquelyResolvedAccountID(operationID: UUID) throws -> UUID? {
        let targetID = operationID
        guard
            let gate = try modelContext.fetch(
                FetchDescriptor<SmsPersistenceDecision>(predicate: #Predicate { $0.operationID == targetID })
            ).first,
            let object = try? JSONSerialization.jsonObject(with: Data(gate.accountResolutionJSON.utf8))
                as? [String: Any],
            object["result"] as? String == "unique",
            let rawID = object["account_id"] as? String
        else { return nil }
        return UUID(uuidString: rawID)
    }

    private func accountName(id: UUID) throws -> String {
        let targetID = id
        guard
            let account = try modelContext.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == targetID })
            ).first
        else { throw SmsProcessingStoreError.invalidCommand }
        return account.name
    }

    private func amountEvidenceText(operationID: UUID, candidateID: String) throws -> String {
        let targetID = operationID
        guard
            let stored = try modelContext.fetch(
                FetchDescriptor<SmsProcessingAnalysis>(predicate: #Predicate { $0.operationID == targetID })
            ).first,
            let document = try? JSONSerialization.jsonObject(
                with: Data(stored.canonicalJSON.utf8)
            ) as? [String: Any],
            let candidates = document["candidates"] as? [[String: Any]],
            let candidate = candidates.first(where: {
                $0["candidate_id"] as? String == candidateID
            }),
            let evidence = candidate["evidence"] as? [String: Any],
            let text = evidence["text"] as? String
        else { throw SmsProcessingStoreError.invalidCommand }
        return text
    }

    struct SourceEvidence: Sendable {
        let body: String
        let sender: String
        let admissionReceiptID: UUID
    }

    func sourceEvidence(sourceID: UUID) throws -> SourceEvidence {
        let targetID = sourceID
        guard
            let alert = try modelContext.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == targetID })
            ).first
        else { throw SmsProcessingStoreError.sourceNotFound }
        return SourceEvidence(
            body: alert.rawBody,
            sender: alert.sender,
            admissionReceiptID: alert.id
        )
    }

    func settledOutcome(operationID: UUID) throws -> SmsProcessingOutcome? {
        guard let operation = try operation(id: operationID), operation.settledAt != nil else {
            return nil
        }
        if operation.state == .retainedReview {
            let targetID = operationID
            guard
                let review = try modelContext.fetch(
                    FetchDescriptor<SmsReviewCase>(
                        predicate: #Predicate {
                            $0.currentOperationID == targetID
                        })
                ).first
            else { throw SmsProcessingStoreError.reviewCaseNotFound }
            return .retainedForReview(
                operationID: operationID,
                reviewCaseID: review.id,
                reasons: review.reasonCodesRawValue.split(separator: "\n").map(String.init)
            )
        }
        if operation.state == .discarded {
            return .terminallyDiscarded(
                operationID: operationID,
                reason: operation.settlementReceiptJSON ?? "terminal_discard"
            )
        }
        return nil
    }

    func recordAnalysis(_ analysis: SmsAnalysis, operationID: UUID, now: Date = .now) throws {
        let targetID = operationID
        if try modelContext.fetch(
            FetchDescriptor<SmsProcessingAnalysis>(
                predicate: #Predicate {
                    $0.operationID == targetID
                })
        ).first != nil {
            return
        }
        modelContext.insert(
            SmsProcessingAnalysis(
                operationID: operationID,
                analysisID: analysis.analysisID,
                contractVersion: analysis.contract,
                sourceHash: analysis.sourceHash,
                configurationHash: analysis.configurationHash,
                canonicalJSON: try analysis.canonicalJSON,
                createdAt: now
            ))
        try saveOrRollback()
    }

    func recordSelectorResponse(
        operationID: UUID,
        response: DirectSelectorResponse,
        startedAt: Date,
        now: Date = .now
    ) throws {
        let attempt =
            try selectorAttempt(operationID: operationID)
            ?? SmsSelectorAttempt(
                operationID: operationID,
                attemptIndex: 0,
                runtimeProfileJSON: response.runtimeProfileJSON,
                requestJSON: response.requestJSON,
                startedAt: startedAt
            )
        if attempt.modelContext == nil { modelContext.insert(attempt) }
        attempt.rawOutput = response.rawOutput
        attempt.outputByteCount = response.rawOutput.utf8.count
        attempt.completionRawValue = response.completion
        attempt.completedAt = now
        try saveOrRollback()
    }

    func recordSelectorFailure(
        operationID: UUID,
        runtimeProfileJSON: String,
        requestJSON: String,
        safeErrorCode: String,
        startedAt: Date,
        now: Date = .now
    ) throws {
        let attempt = SmsSelectorAttempt(
            operationID: operationID, attemptIndex: 0,
            runtimeProfileJSON: runtimeProfileJSON, requestJSON: requestJSON,
            startedAt: startedAt
        )
        attempt.completionRawValue = "failed"
        attempt.safeErrorCode = safeErrorCode
        attempt.completedAt = now
        modelContext.insert(attempt)
        try saveOrRollback()
    }

    func markSelectorInvalid(operationID: UUID, safeErrorCode: String) throws {
        guard let attempt = try selectorAttempt(operationID: operationID) else {
            throw SmsProcessingStoreError.stateConflict
        }
        attempt.safeErrorCode = safeErrorCode
        attempt.completionRawValue = "invalid"
        try saveOrRollback()
    }

    func recordReconstruction(
        _ result: ReconstructedSmsTransaction,
        operationID: UUID,
        now: Date = .now
    ) throws {
        modelContext.insert(
            SmsReconstructedResult(
                operationID: operationID,
                contractVersion: "pocketfinancer.processing-result/2",
                recognitionDecision: "posted",
                semanticResultJSON: try CanonicalJSON.string(result),
                createdAt: now
            ))
        try saveOrRollback()
    }

    func recordV4NormalizedResult(
        operationID: UUID,
        semanticResultJSON: String,
        decision: String
    ) throws {
        let targetID = operationID
        guard
            try modelContext.fetch(
                FetchDescriptor<SmsReconstructedResult>(
                    predicate: #Predicate { $0.operationID == targetID }
                )
            ).first == nil
        else { return }
        modelContext.insert(
            SmsReconstructedResult(
                operationID: operationID,
                contractVersion: "pocketfinancer.processing-result/3",
                recognitionDecision: decision,
                semanticResultJSON: semanticResultJSON
            ))
        try saveOrRollback()
    }

    func recordV4GateDecision(
        _ claim: SmsOperationClaim,
        result: String,
        primaryReason: String,
        checksJSON: String,
        accountResolutionJSON: String,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        let operationID = claim.operationID
        guard
            try modelContext.fetch(
                FetchDescriptor<SmsPersistenceDecision>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ).first == nil
        else { return }
        modelContext.insert(
            SmsPersistenceDecision(
                operationID: operationID,
                result: result,
                primaryReason: primaryReason,
                checksJSON: checksJSON,
                accountResolutionJSON: accountResolutionJSON,
                rolloutMode: "review_only",
                createdAt: now
            ))
        try saveOrRollback()
    }

    func v4DuplicateStatus(
        operationID: UUID,
        sourceID: UUID,
        stableEventID: UUID,
        transactionFingerprint: String
    ) throws -> String {
        let operations = try modelContext.fetch(FetchDescriptor<SmsProcessingOperation>())
            .filter { $0.id != operationID }
        if operations.contains(where: {
            $0.state == .persisted
                && ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
        }) {
            return "already_persisted"
        }
        if operations.contains(where: {
            $0.state != .discarded
                && ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
        }) {
            return "possible_duplicate"
        }
        let results = try modelContext.fetch(FetchDescriptor<SmsReconstructedResult>())
            .filter { $0.operationID != operationID }
        for result in results {
            guard let json = result.semanticResultJSON,
                let root = try? JSONSerialization.jsonObject(
                    with: Data(json.utf8)
                ) as? [String: Any],
                let duplicate = root["duplicate_assessment"] as? [String: Any],
                duplicate["transaction_fingerprint"] as? String == transactionFingerprint
            else { continue }
            return "possible_duplicate"
        }
        return "clear"
    }

    func recordGateDecision(
        _ decision: PersistenceGateDecision,
        accountResolution: SmsAccountResolution,
        claim: SmsOperationClaim,
        rolloutMode: String,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        let accountJSON: String
        switch accountResolution {
        case .missing:
            accountJSON = #"{"result":"missing"}"#
        case .unresolved:
            accountJSON = #"{"result":"unresolved"}"#
        case .ambiguous(let ids):
            let values = ids.map { #""\#($0.uuidString.lowercased())""# }.sorted()
            accountJSON =
                #"{"account_ids":[\#(values.joined(separator: ","))],"result":"ambiguous"}"#
        case .unique(let id):
            accountJSON = #"{"result":"unique","account_id":"\#(id.uuidString.lowercased())"}"#
        }
        modelContext.insert(
            SmsPersistenceDecision(
                operationID: claim.operationID,
                result: decision.result.rawValue,
                primaryReason: decision.primaryReason,
                checksJSON: try CanonicalJSON.string(decision.checks),
                accountResolutionJSON: accountJSON,
                rolloutMode: rolloutMode,
                createdAt: now
            ))
        try saveOrRollback()
    }

    func settleDiscarded(
        _ claim: SmsOperationClaim,
        reason: String,
        now: Date = .now
    ) throws {
        let operation = try requireOwned(claim, now: now)
        let sourceID = operation.sourceAlertID
        if let alert = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        ).first {
            alert.eraseSensitiveEvidence()
            alert.status = .rejected
        }
        operation.state = .discarded
        operation.transitionSequence += 1
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        operation.settledAt = now
        operation.updatedAt = now
        operation.settlementReceiptJSON = reason
        try saveOrRollback()
    }

    func retainUnownedForReview(
        operationID: UUID,
        reasons: [String],
        now: Date = .now
    ) throws -> UUID {
        guard let operation = try operation(id: operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        if operation.settledAt != nil {
            let targetID = operationID
            if let existing = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(
                    predicate: #Predicate { $0.currentOperationID == targetID }
                )
            ).first {
                return existing.id
            }
            throw SmsProcessingStoreError.stateConflict
        }
        if operation.ownerToken != nil {
            guard let expiresAt = operation.claimExpiresAt, expiresAt <= now else {
                throw SmsProcessingStoreError.lostOwnership
            }
        }
        let targetID = operationID
        if let existing = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate {
                    $0.currentOperationID == targetID
                })
        ).first {
            return existing.id
        }
        if let parentOperationID = operation.parentOperationID {
            let parentID = parentOperationID
            if let retried = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(
                    predicate: #Predicate { $0.currentOperationID == parentID }
                )
            ).first {
                retried.currentOperationID = operationID
                retried.reasonCodesRawValue = reasons.joined(separator: "\n")
                retried.state = .open
                retried.updatedAt = now
                operation.ownerGeneration += 1
                operation.ownerToken = nil
                operation.claimExpiresAt = nil
                operation.state = .retainedReview
                operation.transitionSequence += 1
                operation.updatedAt = now
                operation.settledAt = now
                operation.settlementReceiptJSON = try CanonicalJSON.string(
                    ReviewSettlement(reviewCaseID: retried.id, reasons: reasons)
                )
                try saveOrRollback()
                return retried.id
            }
        }
        operation.ownerGeneration += 1
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        operation.state = .retainedReview
        operation.transitionSequence += 1
        operation.updatedAt = now
        operation.settledAt = now
        let review = SmsReviewCase(
            sourceAlertID: operation.sourceAlertID,
            currentOperationID: operation.id,
            reasonCodes: reasons,
            stableEventIDs: [operation.stableEventID],
            createdAt: now
        )
        modelContext.insert(review)
        operation.settlementReceiptJSON = try CanonicalJSON.string(
            ReviewSettlement(reviewCaseID: review.id, reasons: reasons)
        )
        try saveOrRollback()
        return review.id
    }

    private func selectorAttempt(operationID: UUID) throws -> SmsSelectorAttempt? {
        let targetID = operationID
        return try modelContext.fetch(
            FetchDescriptor<SmsSelectorAttempt>(
                predicate: #Predicate {
                    $0.operationID == targetID && $0.attemptIndex == 0
                })
        ).first
    }

    private func appendRecoveryTrace(
        operation: SmsProcessingOperation,
        now: Date
    ) throws {
        let operationID = operation.id
        let existing = try modelContext.fetch(
            FetchDescriptor<SmsProcessingTraceEvent>(
                predicate: #Predicate { $0.operationID == operationID },
                sortBy: [SortDescriptor(\.sequence)]
            )
        )
        let sequence = existing.count
        let eventID = UUID()
        let reasons = ["operation_interrupted"]
        let payload = TraceHashPayload(
            sequence: sequence,
            eventID: eventID.uuidString.lowercased(),
            occurredAtEpochMilliseconds: Int64(
                (now.timeIntervalSince1970 * 1_000).rounded(.towardZero)
            ),
            stage: "recovery",
            status: "retained_review",
            reasonCodes: reasons,
            detailJSON: nil,
            previousEventHash: existing.last?.eventHash
        )
        modelContext.insert(
            SmsProcessingTraceEvent(
                id: eventID,
                operationID: operationID,
                sequence: sequence,
                occurredAt: now,
                stage: "recovery",
                status: "retained_review",
                reasonCodes: reasons,
                detailJSON: nil,
                previousEventHash: existing.last?.eventHash,
                eventHash: try CanonicalJSON.sha256(payload)
            )
        )
    }

    private func requireOwned(
        _ claim: SmsOperationClaim,
        now: Date
    ) throws -> SmsProcessingOperation {
        guard let operation = try operation(id: claim.operationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }
        guard operation.ownerToken == claim.ownerToken,
            operation.ownerGeneration == claim.generation,
            operation.claimExpiresAt.map({ $0 >= now }) == true,
            operation.settledAt == nil
        else {
            throw SmsProcessingStoreError.lostOwnership
        }
        return operation
    }

    private func latestFeedbackHash(reviewCaseID: UUID) throws -> String? {
        let targetID = reviewCaseID
        return try modelContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(
                predicate: #Predicate { $0.reviewCaseID == targetID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).first?.eventHash
    }

    private func latestFeedbackHash(transactionID: UUID) throws -> String? {
        let targetID = transactionID
        return try modelContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>(
                predicate: #Predicate { $0.transactionID == targetID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).first?.eventHash
    }

    private func validate(_ command: ReviewCommand) -> Bool {
        guard Set(command.corrections.map(\.field)).count == command.corrections.count else {
            return false
        }
        return switch command.kind {
        case .correct:
            !command.corrections.isEmpty && command.retryConfiguration == nil
        case .saveDraft, .resolveMultipleEvents:
            command.retryConfiguration == nil
        case .retry:
            command.corrections.isEmpty
                && ["original", "current"].contains(command.retryConfiguration)
        case .confirm, .reject:
            command.corrections.isEmpty && command.retryConfiguration == nil
        }
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw SmsProcessingStoreError.saveFailed
        }
    }
}

nonisolated private struct TraceHashPayload: Codable {
    let sequence: Int
    let eventID: String
    let occurredAtEpochMilliseconds: Int64
    let stage: String
    let status: String
    let reasonCodes: [String]
    let detailJSON: String?
    let previousEventHash: String?
}

nonisolated private struct ReviewSettlement: Codable {
    let reviewCaseID: UUID
    let reasons: [String]
}

nonisolated private struct FeedbackHashPayload: Codable {
    let actionID: String
    let reviewCaseID: String
    let operationID: String
    let expectedRevision: Int
    let resultingRevision: Int
    let action: String
    let correctionsJSON: String
    let retryConfiguration: String?
    let previousEventHash: String?
}

nonisolated private struct ProjectionFeedbackHashPayload: Codable {
    let actionID: String
    let transactionID: String
    let expectedRevision: Int
    let resultingRevision: Int
    let action: String
    let correctionsJSON: String
    let previousEventHash: String?
}
