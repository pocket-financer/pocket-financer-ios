import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import SwiftData

nonisolated enum SmsProcessingStoreError: Error, Equatable, Sendable {
    case sourceNotFound
    case operationNotFound
    case reviewCaseNotFound
    case transactionNotFound
    case configurationMismatch
    case stateConflict
    case lostOwnership
    case revisionConflict
    case invalidCommand
    case saveFailed
    case admissionBusy
    case sourceConflict
}

nonisolated struct SmsOperationClaim: Equatable, Sendable {
    let operationID: UUID
    let ownerToken: UUID
    let generation: Int64
    let expiresAt: Date
    let eraseEpoch: Int64

    init(
        operationID: UUID,
        ownerToken: UUID,
        generation: Int64,
        expiresAt: Date,
        eraseEpoch: Int64 = 0
    ) {
        self.operationID = operationID
        self.ownerToken = ownerToken
        self.generation = generation
        self.expiresAt = expiresAt
        self.eraseEpoch = eraseEpoch
    }
}

nonisolated struct DuplicateWindowTransactionSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let amountMinorUnits: Int64
    let currencyCode: String
    let direction: TransactionDirection
    let merchant: String
    let accountID: UUID?
    let accountLabel: String?
    let occurredAt: Date
    let sourceAlertID: UUID
}

nonisolated struct SmsReviewDetails: Equatable, Sendable {
    let reviewCaseID: UUID
    let reviewRevision: Int
    let reviewState: SmsReviewState
    let sourceAlertID: UUID
    let operationID: UUID
    let sender: String
    let rawBody: String
    let receivedAt: Date
    let primaryCurrency: String
    let reasonCodes: [String]
    let proposal: SmsReviewProposal?
    let retainedEvidence: SmsReviewRetainedEvidence
    let draftCorrections: [SmsFieldCorrection]
    let ambiguousAccountIDs: [UUID]
    let suggestedAccountID: UUID?
    let duplicateStatus: String
    let duplicateMatches: [DuplicateWindowTransactionSummary]
}

@ModelActor
actor SmsProcessingStore {
    static let claimLease: TimeInterval = 120

    nonisolated private final class WeakStoreBox: @unchecked Sendable {
        weak var store: SmsProcessingStore?

        init(_ store: SmsProcessingStore) {
            self.store = store
        }
    }

    nonisolated private static let admissionMutex = NSLock()
    nonisolated private static let sharedRegistryLock = NSLock()
    nonisolated(unsafe) private static var sharedStores: [ObjectIdentifier: WeakStoreBox] = [:]
    nonisolated(unsafe) private static var eraseEpochs: [ObjectIdentifier: Int64] = [:]

    /// Returns a container-scoped shared store actor so legacy backfill, duplicate checks,
    /// and review mutations serialize on a single actor per `ModelContainer`.
    nonisolated static func shared(for container: ModelContainer) -> SmsProcessingStore {
        let key = ObjectIdentifier(container)
        sharedRegistryLock.lock()
        defer { sharedRegistryLock.unlock() }
        if let existing = sharedStores[key]?.store {
            return existing
        }
        sharedStores = sharedStores.filter { $0.value.store != nil }
        let store = SmsProcessingStore(modelContainer: container)
        sharedStores[key] = WeakStoreBox(store)
        return store
    }

    /// Invalidates all active operation claims for `container` when local data is erased.
    nonisolated static func invalidateForErase(container: ModelContainer) {
        let key = ObjectIdentifier(container)
        sharedRegistryLock.lock()
        defer { sharedRegistryLock.unlock() }
        eraseEpochs[key, default: 0] += 1
        sharedStores.removeValue(forKey: key)
    }

    nonisolated static func currentEraseEpoch(for container: ModelContainer) -> Int64 {
        let key = ObjectIdentifier(container)
        sharedRegistryLock.lock()
        defer { sharedRegistryLock.unlock() }
        return eraseEpochs[key] ?? 0
    }

    /// Serializes source operation selection, creation and the initial claim. Never
    /// hold this lock across an await or inference. Uniqueness alone is an upsert,
    /// not a compare-and-insert guard in SwiftData.
    nonisolated static func withAdmissionLock<T>(
        container: ModelContainer,
        _ body: (ModelContext) throws -> T
    ) throws -> T {
        guard admissionMutex.try() else { throw SmsProcessingStoreError.admissionBusy }
        defer { admissionMutex.unlock() }
        guard container.configurations.count == 1,
            let configuration = container.configurations.first
        else { throw SmsProcessingStoreError.configurationMismatch }

        var descriptor: Int32 = -1
        if !configuration.isStoredInMemoryOnly {
            let lockURL = configuration.url.appendingPathExtension("admission-lock")
            descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw SmsProcessingStoreError.saveFailed }
        }
        defer {
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
            }
        }
        if descriptor >= 0 {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw SmsProcessingStoreError.admissionBusy
            }
            let lockURL = configuration.url.appendingPathExtension("admission-lock")
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: lockURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = lockURL
            try protectedURL.setResourceValues(values)
        }
        let freshContext = ModelContext(container)
        freshContext.autosaveEnabled = false
        return try body(freshContext)
    }

    /// Called only inside withAdmissionLock, before exposing newly created work.
    /// A crash before this save leaves a ready snapshot for visible owner recovery.
    nonisolated static func claimForAdmission(
        operationID: UUID,
        context: ModelContext,
        now: Date = .now
    ) throws -> SmsOperationClaim {
        let targetID = operationID
        guard
            let operation = try context.fetch(
                FetchDescriptor<SmsProcessingOperation>(predicate: #Predicate { $0.id == targetID })
            ).first
        else { throw SmsProcessingStoreError.operationNotFound }
        guard operation.state == .ready, operation.settledAt == nil,
            operation.ownerToken == nil
        else { throw SmsProcessingStoreError.stateConflict }
        let token = UUID()
        let expiresAt = now.addingTimeInterval(claimLease)
        operation.ownerGeneration += 1
        operation.ownerToken = token
        operation.claimExpiresAt = expiresAt
        operation.state = .claimed
        operation.transitionSequence += 1
        operation.updatedAt = now
        do { try context.save() } catch {
            context.rollback()
            throw SmsProcessingStoreError.saveFailed
        }
        return SmsOperationClaim(
            operationID: operationID,
            ownerToken: token,
            generation: operation.ownerGeneration,
            expiresAt: expiresAt,
            eraseEpoch: currentEraseEpoch(for: context.container)
        )
    }

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
            expiresAt: expiresAt,
            eraseEpoch: Self.currentEraseEpoch(for: modelContainer)
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
            expiresAt: expiresAt,
            eraseEpoch: claim.eraseEpoch
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

        for transaction in transactions
        where !snapshottedIDs.contains(transaction.id)
            && !revisionTransactionIDs.contains(transaction.id)
        {
            modelContext.insert(SmsLegacyTransactionSnapshot(transaction: transaction, capturedAt: now))
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
        let sourceID = operation.sourceAlertID
        let cases = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate {
                    $0.currentOperationID == operationID
                })
        )
        let reviewCase: SmsReviewCase
        if let existing = cases.first {
            reviewCase = existing
            reviewCase.reasonCodesRawValue = reasons.joined(separator: "\n")
            reviewCase.state = .open
            reviewCase.updatedAt = now
        } else if let retried = try reusableReviewCase(for: operation) {
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
                sourceAlertID: sourceID,
                currentOperationID: operationID,
                reasonCodes: reasons,
                stableEventIDs: [operation.stableEventID],
                createdAt: now
            )
            modelContext.insert(reviewCase)
        }
        if let alert = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        ).first,
            alert.status != .imported,
            alert.status != .rejected
        {
            alert.status = .needsReview
            alert.lastErrorCode = reasons.first
            alert.updatedAt = now
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
        let retriedOperationIDs = Set(operations.compactMap(\.parentOperationID))
        var reviewIDs: [UUID] = []
        for operation in operations where operation.settledAt == nil && operation.updatedAt <= cutoff {
            // An explicit retry of unowned ready/interrupted work owns recovery.
            // Do not create another Review for its preserved, superseded parent.
            if [.ready, .interrupted, .retryWait].contains(operation.state)
                && operation.ownerToken == nil && retriedOperationIDs.contains(operation.id)
            {
                continue
            }
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
            let projection = try projectGroundedReview(
                review: review,
                command: command,
                feedbackActionID: actionID,
                now: now
            )
            feedback.transactionID = projection.transactionID
            feedback.transactionRevisionID = projection.revisionID
        } else if command.kind == .reject {
            try settleRejectedReview(
                sourceAlertID: review.sourceAlertID,
                excludingReviewCaseID: review.id,
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
        } else if command.kind == .reject || command.kind == .confirm {
            review.draftJSON = nil
        }
        try saveOrRollback()
        return ReviewReceipt(
            actionID: actionID,
            reviewCaseID: reviewID,
            resultingRevision: resultingRevision,
            replayed: false
        )
    }

    /// Atomically deletes a transaction, deactivates its revision projection, and reopens
    /// the source alert in Needs Review without leaving it blocked as `already_persisted`.
    @discardableResult
    func deleteTransaction(transactionID: UUID, now: Date = .now) throws -> UUID? {
        let targetID = transactionID
        guard
            let transaction = try modelContext.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == targetID })
            ).first
        else { throw SmsProcessingStoreError.transactionNotFound }

        let sourceID = transaction.sourceAlertID
        let revisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate {
                    $0.transactionID == targetID || $0.sourceAlertID == sourceID
                }
            )
        )
        for revision in revisions {
            revision.isCurrentProjection = false
        }
        modelContext.delete(transaction)

        var reopenedReviewCaseID: UUID?
        if let alert = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        ).first {
            alert.transactionID = nil
            alert.updatedAt = now
            if !alert.rawBody.isEmpty {
                alert.status = .needsReview
                alert.lastErrorCode = "transaction_deleted_by_user"

                let operations = try modelContext.fetch(
                    FetchDescriptor<SmsProcessingOperation>(
                        predicate: #Predicate { $0.sourceAlertID == sourceID },
                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                    )
                ).sorted {
                    if $0.createdAt == $1.createdAt { return $0.id.uuidString > $1.id.uuidString }
                    return $0.createdAt > $1.createdAt
                }
                for operation in operations where operation.state == .persisted {
                    operation.state = .retainedReview
                    operation.transitionSequence += 1
                    operation.updatedAt = now
                }
                if let latestOperation = operations.first {
                    try reopenReconstructedResultForReview(operationID: latestOperation.id)
                    let existingCases = try modelContext.fetch(
                        FetchDescriptor<SmsReviewCase>(
                            predicate: #Predicate { $0.sourceAlertID == sourceID },
                            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
                        )
                    )
                    if let existing = existingCases.first {
                        existing.currentOperationID = latestOperation.id
                        existing.state = .open
                        existing.reasonCodesRawValue = "transaction_deleted_by_user"
                        existing.draftJSON = nil
                        existing.updatedAt = now
                        reopenedReviewCaseID = existing.id
                    } else {
                        let reviewCase = SmsReviewCase(
                            sourceAlertID: sourceID,
                            currentOperationID: latestOperation.id,
                            state: .open,
                            revision: 0,
                            reasonCodes: ["transaction_deleted_by_user"],
                            stableEventIDs: [latestOperation.stableEventID],
                            createdAt: now
                        )
                        modelContext.insert(reviewCase)
                        reopenedReviewCaseID = reviewCase.id
                    }
                }
            }
        }
        try saveOrRollback()
        return reopenedReviewCaseID
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

    private func projectGroundedReview(
        review: SmsReviewCase,
        command: ReviewCommand,
        feedbackActionID: UUID,
        now: Date
    ) throws -> (transactionID: UUID, revisionID: UUID) {
        let sourceID = review.sourceAlertID
        let targetOperationID = review.currentOperationID
        guard
            let operation = try operation(id: targetOperationID),
            operation.contractReleaseID == SmsContractAssets.releaseID,
            SmsProcessingJSON.configurationMatches(
                configurationJSON: operation.configurationJSON,
                configurationHash: operation.configurationHash
            ),
            let configuration = try? JSONSerialization.jsonObject(
                with: Data(operation.configurationJSON.utf8)
            ) as? [String: Any],
            configuration["contract"] as? String == SmsContractAssets.releaseID,
            let contractRelease = configuration["contract_release"] as? [String: Any],
            contractRelease["release_id"] as? String == operation.contractReleaseID,
            let persistencePolicy = configuration["persistence_policy"] as? [String: Any],
            persistencePolicy["rollout_mode"] as? String == "automatic",
            configuration["source_ref_hash"] as? String
                == CanonicalJSON.sha256(sourceID.uuidString.lowercased()),
            let currencyContext = configuration["currency_context"] as? [String: Any],
            let defaultCurrencyRaw = currencyContext["primary_currency"] as? String,
            CurrencyFormatter.supportedScales[defaultCurrencyRaw.uppercased()] != nil,
            let receiptConfig = configuration["received_timestamp"] as? [String: Any],
            receiptConfig["read_only"] as? Bool == true,
            let receiptEpochMs = exactInt64(receiptConfig["epoch_ms"]),
            receiptEpochMs >= 0,
            let alert = try modelContext.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
            ).first,
            !alert.rawBody.isEmpty,
            alert.transactionID == nil
        else { throw SmsProcessingStoreError.invalidCommand }

        if let analysis = try modelContext.fetch(
            FetchDescriptor<SmsProcessingAnalysis>(
                predicate: #Predicate { $0.operationID == targetOperationID }
            )
        ).first {
            guard
                analysis.configurationHash == operation.configurationHash,
                analysis.sourceHash == CanonicalJSON.sha256(alert.rawBody)
            else { throw SmsProcessingStoreError.invalidCommand }
        }

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
        let existingTransactions = try modelContext.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.sourceAlertID == sourceID })
        )
        guard existingTransactions.isEmpty else { throw SmsProcessingStoreError.stateConflict }
        let existingOperations = try modelContext.fetch(
            FetchDescriptor<SmsProcessingOperation>(
                predicate: #Predicate { $0.sourceAlertID == sourceID }
            )
        )
        guard !existingOperations.contains(where: { $0.state == .persisted }) else {
            throw SmsProcessingStoreError.stateConflict
        }

        let storedResult = try modelContext.fetch(
            FetchDescriptor<SmsReconstructedResult>(
                predicate: #Predicate { $0.operationID == targetOperationID }
            )
        ).first
        let base: SmsReviewProposal?
        if let storedResult,
            storedResult.contractVersion == "pocketfinancer.processing-result/3",
            storedResult.recognitionDecisionRawValue == "posted"
        {
            guard
                let parsed = SmsReviewProjection.parse(
                    resultJSON: storedResult.semanticResultJSON,
                    source: alert.rawBody
                ),
                parsed.duplicateIdempotencyKey == sourceID.uuidString.lowercased(),
                parsed.duplicateSourceEventKey == stableEventID.uuidString.lowercased(),
                parsed.duplicateStatus != "already_persisted"
            else { throw SmsProcessingStoreError.invalidCommand }
            base = parsed
        } else {
            if let storedJSON = storedResult?.semanticResultJSON,
                let root = try? JSONSerialization.jsonObject(with: Data(storedJSON.utf8))
                    as? [String: Any],
                let duplicate = root["duplicate_assessment"] as? [String: Any],
                duplicate["status"] as? String == "already_persisted"
            {
                throw SmsProcessingStoreError.invalidCommand
            }
            base = nil
        }

        if command.kind == .confirm, base == nil {
            throw SmsProcessingStoreError.invalidCommand
        }

        let allowedFields: Set<String> = [
            "currency",
            "amount",
            "direction",
            "account",
            "counterparty",
            "account_id",
            "new_account_name",
            "new_account_bank",
            "new_account_kind",
            "new_account_suffix",
        ]
        guard command.corrections.allSatisfy({ allowedFields.contains($0.field) }) else {
            throw SmsProcessingStoreError.invalidCommand
        }

        var currency = base?.currency ?? defaultCurrencyRaw.uppercased()
        if let currencyCorrection = command.corrections.first(where: { $0.field == "currency" }) {
            guard currencyCorrection.scalarEvidence == nil else {
                throw SmsProcessingStoreError.invalidCommand
            }
            let code = currencyCorrection.newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard CurrencyFormatter.supportedScales[code] != nil else {
                throw SmsProcessingStoreError.invalidCommand
            }
            currency = code
        }

        var amountMinorUnits = base?.amountMinorUnits
        var amountSpan = base?.amountSpan
        var direction = base?.direction
        var accountReference = base?.accountReference
        var accountSpan = base?.accountSpan
        var counterparty = base?.counterparty
        var explicitAccountID: UUID?
        var newAccountName: String?
        var newAccountBank: String?
        var newAccountKind: AccountKind?
        var newAccountSuffix: String?

        for correction in command.corrections {
            switch correction.field {
            case "currency":
                continue
            case "amount":
                guard let rawSpan = correction.scalarEvidence else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let verified = try UnicodeScalarSpan(
                    source: alert.rawBody,
                    startScalar: rawSpan.startScalar,
                    endScalar: rawSpan.endScalar,
                    text: rawSpan.text
                )
                guard
                    let grounded = try? SmsExtractorNormalizer.minorUnits(
                        evidenceText: verified.text,
                        currency: currency
                    ),
                    let declared = Int64(correction.newValue),
                    grounded > 0,
                    grounded == declared
                else { throw SmsProcessingStoreError.invalidCommand }
                amountMinorUnits = grounded
                amountSpan = verified
            case "direction":
                guard ["debit", "credit"].contains(correction.newValue) else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                if let rawSpan = correction.scalarEvidence {
                    let verified = try UnicodeScalarSpan(
                        source: alert.rawBody,
                        startScalar: rawSpan.startScalar,
                        endScalar: rawSpan.endScalar,
                        text: rawSpan.text
                    )
                    guard SmsExtractorNormalizer.isDirectionGrounded(correction.newValue, in: verified.text)
                    else { throw SmsProcessingStoreError.invalidCommand }
                } else {
                    guard correction.classification == .suppliedManualUngroundedValue else {
                        throw SmsProcessingStoreError.invalidCommand
                    }
                }
                direction = correction.newValue
            case "account":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    accountReference = nil
                    accountSpan = nil
                } else {
                    guard let rawSpan = correction.scalarEvidence else {
                        throw SmsProcessingStoreError.invalidCommand
                    }
                    let verified = try UnicodeScalarSpan(
                        source: alert.rawBody,
                        startScalar: rawSpan.startScalar,
                        endScalar: rawSpan.endScalar,
                        text: rawSpan.text
                    )
                    guard
                        let normalized = SmsExtractorNormalizer.normalizeAccount(verified.text),
                        normalized == SmsExtractorNormalizer.normalizeAccount(correction.newValue)
                    else { throw SmsProcessingStoreError.invalidCommand }
                    accountReference = normalized
                    accountSpan = verified
                }
            case "counterparty":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    counterparty = nil
                } else {
                    guard let rawSpan = correction.scalarEvidence else {
                        throw SmsProcessingStoreError.invalidCommand
                    }
                    let verified = try UnicodeScalarSpan(
                        source: alert.rawBody,
                        startScalar: rawSpan.startScalar,
                        endScalar: rawSpan.endScalar,
                        text: rawSpan.text
                    )
                    guard
                        let normalized = SmsExtractorNormalizer.normalizeCounterparty(verified.text),
                        normalized == SmsExtractorNormalizer.normalizeCounterparty(correction.newValue)
                    else { throw SmsProcessingStoreError.invalidCommand }
                    counterparty = normalized
                }
            case "account_id":
                guard correction.scalarEvidence == nil else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let trimmed = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != "null" {
                    guard let value = UUID(uuidString: trimmed) else {
                        throw SmsProcessingStoreError.invalidCommand
                    }
                    explicitAccountID = value
                }
            case "new_account_name":
                guard correction.scalarEvidence == nil else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw SmsProcessingStoreError.invalidCommand }
                newAccountName = value
            case "new_account_bank":
                guard correction.scalarEvidence == nil else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                newAccountBank = value.isEmpty ? nil : value
            case "new_account_kind":
                guard correction.scalarEvidence == nil,
                    let value = AccountKind(rawValue: correction.newValue)
                else { throw SmsProcessingStoreError.invalidCommand }
                newAccountKind = value
            case "new_account_suffix":
                guard correction.scalarEvidence == nil else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    value.isEmpty
                        || ((3...8).contains(value.count)
                            && value.allSatisfy({ $0.isASCII && $0.isNumber }))
                else { throw SmsProcessingStoreError.invalidCommand }
                newAccountSuffix = value.isEmpty ? nil : value
            default:
                throw SmsProcessingStoreError.invalidCommand
            }
        }
        guard !(explicitAccountID != nil && newAccountName != nil) else {
            throw SmsProcessingStoreError.invalidCommand
        }

        guard
            let finalAmount = amountMinorUnits,
            finalAmount > 0,
            let finalAmountSpan = amountSpan,
            let currencyScale = CurrencyFormatter.supportedScales[currency],
            (try? SmsExtractorNormalizer.minorUnits(
                evidenceText: finalAmountSpan.text,
                currency: currency
            )) == finalAmount,
            let finalDirectionRaw = direction,
            let finalDirection = TransactionDirection(rawValue: finalDirectionRaw)
        else { throw SmsProcessingStoreError.invalidCommand }

        let normalizedReference: String?
        if let accountReference {
            guard
                accountSpan != nil,
                let normalized = SmsExtractorNormalizer.normalizeAccount(accountReference)
            else { throw SmsProcessingStoreError.invalidCommand }
            normalizedReference = normalized
        } else {
            normalizedReference = nil
        }

        let account = try resolveAccountForReview(
            explicitAccountID: explicitAccountID,
            newAccountName: newAccountName,
            newAccountBank: newAccountBank,
            newAccountKind: newAccountKind,
            newAccountSuffix: newAccountSuffix,
            normalizedReference: normalizedReference,
            sender: alert.sender,
            now: now
        )

        let receiptTimestamp =
            base?.receiptTimestamp
            ?? Date(timeIntervalSince1970: TimeInterval(receiptEpochMs) / 1_000)
        let merchant = counterparty ?? "Unspecified counterparty"
        let transaction = Transaction(
            amountMinorUnits: finalAmount,
            currencyCode: currency,
            merchant: merchant,
            occurredAt: receiptTimestamp,
            direction: finalDirection,
            accountID: account.id,
            accountLabel: account.name,
            isEdited: command.kind == .correct,
            parserName: operation.contractReleaseID,
            reviewState: .confirmed,
            sourceAlertID: sourceID,
            amountEvidenceText: finalAmountSpan.text,
            dateEvidenceText: nil,
            now: now
        )
        modelContext.insert(transaction)
        alert.transactionID = transaction.id
        alert.status = .imported
        alert.lastErrorCode = nil
        alert.rejectionCode = nil
        alert.parserName = operation.contractReleaseID
        alert.updatedAt = now

        let priorRevisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate { $0.sourceAlertID == sourceID },
                sortBy: [SortDescriptor(\.revision)]
            )
        )
        let previousRevision = priorRevisions.last
        let revision = SmsTransactionRevision(
            transactionID: transaction.id,
            sourceAlertID: sourceID,
            stableEventID: stableEventID,
            revision: (previousRevision?.revision ?? -1) + 1,
            previousRevisionID: previousRevision?.id,
            operationID: operation.id,
            feedbackActionID: feedbackActionID,
            amountMinorUnits: finalAmount,
            currencyCode: currency,
            currencyScale: currencyScale,
            direction: finalDirection.rawValue,
            merchant: merchant,
            accountID: account.id,
            occurredAt: receiptTimestamp,
            provenance: command.kind == .confirm
                ? "user_confirmed_grounded_proposal"
                : "user_confirmed_source_span_revision",
            isCurrentProjection: true,
            createdAt: now
        )
        modelContext.insert(revision)
        return (transaction.id, revision.id)
    }

    private func resolveAccountForReview(
        explicitAccountID: UUID?,
        newAccountName: String?,
        newAccountBank: String?,
        newAccountKind: AccountKind?,
        newAccountSuffix: String?,
        normalizedReference: String?,
        sender: String,
        now: Date
    ) throws -> Account {
        let scope = "owned_account_v1"
        if let explicitAccountID {
            let targetID = explicitAccountID
            guard
                let existing = try modelContext.fetch(
                    FetchDescriptor<Account>(predicate: #Predicate { $0.id == targetID })
                ).first
            else { throw SmsProcessingStoreError.invalidCommand }
            if let normalizedReference {
                let aliasKind = normalizedReference.contains("@") ? "vpa" : "suffix"
                try insertConfirmedAliasIfAbsent(
                    accountID: existing.id,
                    normalizedReference: normalizedReference,
                    aliasKind: aliasKind,
                    now: now
                )
            }
            return existing
        }
        if let newAccountName {
            let referenceKind = normalizedReference.map { $0.contains("@") ? "vpa" : "suffix" }
            let suffix = newAccountSuffix ?? (referenceKind == "suffix" ? normalizedReference : nil)
            let created = Account(
                name: newAccountName,
                bank: newAccountBank ?? newAccountName,
                kind: newAccountKind ?? (referenceKind == "vpa" ? .account : .card),
                suffix: suffix,
                now: now
            )
            modelContext.insert(created)
            if let normalizedReference {
                let aliasKind = normalizedReference.contains("@") ? "vpa" : "suffix"
                try insertConfirmedAliasIfAbsent(
                    accountID: created.id,
                    normalizedReference: normalizedReference,
                    aliasKind: aliasKind,
                    now: now
                )
            }
            if let newAccountSuffix,
                let normalizedSuffix = SmsExtractorNormalizer.normalizeAccount(newAccountSuffix),
                normalizedSuffix != normalizedReference
            {
                try insertConfirmedAliasIfAbsent(
                    accountID: created.id,
                    normalizedReference: normalizedSuffix,
                    aliasKind: normalizedSuffix.contains("@") ? "vpa" : "suffix",
                    now: now
                )
            }
            return created
        }

        guard let normalizedReference else { throw SmsProcessingStoreError.invalidCommand }
        let aliasKind = normalizedReference.contains("@") ? "vpa" : "suffix"
        let aliasHash = CanonicalJSON.sha256("\(aliasKind):\(normalizedReference)")
        let matchedIDs = try matchingAccountIDs(forNormalizedReference: normalizedReference)
        guard matchedIDs.count <= 1 else { throw SmsProcessingStoreError.invalidCommand }
        if let matchedID = matchedIDs.first {
            let targetID = matchedID
            guard
                let existing = try modelContext.fetch(
                    FetchDescriptor<Account>(predicate: #Predicate { $0.id == targetID })
                ).first
            else { throw SmsProcessingStoreError.invalidCommand }
            return existing
        }

        let suffix = aliasKind == "suffix" ? normalizedReference : nil
        let accountID = try deterministicReviewUUID(
            "account\0\(scope)\0\(aliasKind)\0\(aliasHash)"
        )
        let aliasID = try deterministicReviewUUID(
            "alias\0\(scope)\0\(aliasKind)\0\(aliasHash)"
        )
        let created = Account(
            id: accountID,
            name: aliasKind == "vpa"
                ? "UPI account \(normalizedReference)"
                : "Account ••\(normalizedReference.suffix(4))",
            bank: sender.isEmpty ? "Unknown Account" : sender,
            kind: aliasKind == "vpa" ? .account : .card,
            suffix: suffix,
            now: now
        )
        modelContext.insert(created)
        modelContext.insert(
            SmsAccountAlias(
                id: aliasID,
                accountID: created.id,
                normalizedAliasHash: aliasHash,
                aliasKind: aliasKind,
                matchingScope: scope,
                confirmedByUser: true,
                createdAt: now
            )
        )
        return created
    }

    private func insertConfirmedAliasIfAbsent(
        accountID: UUID,
        normalizedReference: String,
        aliasKind: String,
        now: Date
    ) throws {
        let aliasHash = CanonicalJSON.sha256("\(aliasKind):\(normalizedReference)")
        let scope = "owned_account_v1"
        let confirmed = true
        let targetAccountID = accountID
        let existing = try modelContext.fetch(
            FetchDescriptor<SmsAccountAlias>(
                predicate: #Predicate {
                    $0.accountID == targetAccountID
                        && $0.normalizedAliasHash == aliasHash
                        && $0.confirmedByUser == confirmed
                        && $0.matchingScopeRawValue == scope
                }
            )
        )
        guard existing.isEmpty else { return }
        modelContext.insert(
            SmsAccountAlias(
                accountID: accountID,
                normalizedAliasHash: aliasHash,
                aliasKind: aliasKind,
                matchingScope: scope,
                confirmedByUser: true,
                createdAt: now
            )
        )
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

    private func exactInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType))
        else { return nil }
        let decimal = number.decimalValue
        guard decimal >= Decimal(Int64.min), decimal <= Decimal(Int64.max) else { return nil }
        return number.int64Value
    }

    private func reopenReconstructedResultForReview(operationID: UUID) throws {
        let targetID = operationID
        guard
            let result = try modelContext.fetch(
                FetchDescriptor<SmsReconstructedResult>(
                    predicate: #Predicate { $0.operationID == targetID }
                )
            ).first,
            let rawJSON = result.semanticResultJSON,
            var root = try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any]
        else { return }
        var changed = false
        if root["status"] as? String == "eligible" {
            root["status"] = "review"
            changed = true
        }
        if var duplicate = root["duplicate_assessment"] as? [String: Any],
            duplicate["status"] as? String == "already_persisted"
        {
            duplicate["status"] = "clear"
            root["duplicate_assessment"] = duplicate
            changed = true
        }
        if changed {
            result.semanticResultJSON = try SmsProcessingJSON.canonical(root)
        }
    }

    private func settleRejectedReview(
        sourceAlertID: UUID,
        excludingReviewCaseID: UUID,
        now: Date
    ) throws {
        let targetSourceID = sourceAlertID
        if let alert = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == targetSourceID })
        ).first {
            alert.eraseSensitiveEvidence(now: now)
            alert.status = .rejected
            alert.rejectionCode = "tombstoned_rejected"
            alert.lastErrorCode = "tombstoned_rejected"
            alert.updatedAt = now
        }
        try scrubSensitiveArtifacts(
            sourceAlertID: sourceAlertID,
            retentionState: "tombstoned_rejected",
            excludingReviewCaseID: excludingReviewCaseID,
            now: now
        )
    }

    private func scrubSensitiveArtifacts(
        sourceAlertID: UUID,
        retentionState: String,
        excludingReviewCaseID: UUID? = nil,
        now: Date
    ) throws {
        let targetSourceID = sourceAlertID
        let operations = try modelContext.fetch(
            FetchDescriptor<SmsProcessingOperation>(
                predicate: #Predicate { $0.sourceAlertID == targetSourceID }
            )
        )
        for operation in operations {
            let operationID = operation.id
            for analysis in try modelContext.fetch(
                FetchDescriptor<SmsProcessingAnalysis>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ) {
                analysis.canonicalJSON = "{}"
            }
            for attempt in try modelContext.fetch(
                FetchDescriptor<SmsSelectorAttempt>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ) {
                attempt.requestJSON = "{}"
                attempt.validatedSelectionJSON = nil
                attempt.rawOutput =
                    retentionState == "tombstoned_none" ? #"{"decision":"none"}"# : nil
            }
            for reconstructed in try modelContext.fetch(
                FetchDescriptor<SmsReconstructedResult>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ) {
                reconstructed.semanticResultJSON = nil
            }
        }
        for reviewCase in try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate { $0.sourceAlertID == targetSourceID }
            )
        ) {
            reviewCase.draftJSON = nil
            if reviewCase.id != excludingReviewCaseID,
                [.open, .draft, .waitingRetry].contains(reviewCase.state)
            {
                reviewCase.state = .rejected
                reviewCase.updatedAt = now
            }
        }
    }

    private func reusableReviewCase(for operation: SmsProcessingOperation) throws -> SmsReviewCase? {
        if let parentOperationID = operation.parentOperationID {
            let parentID = parentOperationID
            if let retried = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(
                    predicate: #Predicate { $0.currentOperationID == parentID }
                )
            ).first {
                return retried
            }
        }
        let sourceID = operation.sourceAlertID
        return try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate { $0.sourceAlertID == sourceID },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        ).first { [.open, .draft, .waitingRetry].contains($0.state) }
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
        if operation.state == .persisted {
            let targetID = operationID
            let revisions = try modelContext.fetch(
                FetchDescriptor<SmsTransactionRevision>(
                    predicate: #Predicate {
                        $0.operationID == targetID && $0.isCurrentProjection
                    }
                )
            )
            var transactionIDs = revisions.map(\.transactionID)
            if transactionIDs.isEmpty {
                let sourceID = operation.sourceAlertID
                if let alert = try modelContext.fetch(
                    FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
                ).first,
                    let transactionID = alert.transactionID
                {
                    transactionIDs = [transactionID]
                }
            }
            return .persisted(
                operationID: operationID,
                transactionIDs: transactionIDs,
                alreadyCommitted: true
            )
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
                reason: operation.tombstoneReason ?? "terminal_discard"
            )
        }
        return nil
    }

    func recordAnalysis(
        _ claim: SmsOperationClaim,
        analysis: SmsAnalysis,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        let targetID = claim.operationID
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
                operationID: claim.operationID,
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
        _ claim: SmsOperationClaim,
        response: DirectSelectorResponse,
        startedAt: Date,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        let operationID = claim.operationID
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
        _ claim: SmsOperationClaim,
        runtimeProfileJSON: String,
        requestJSON: String,
        safeErrorCode: String,
        startedAt: Date,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        let attempt = SmsSelectorAttempt(
            operationID: claim.operationID, attemptIndex: 0,
            runtimeProfileJSON: runtimeProfileJSON, requestJSON: requestJSON,
            startedAt: startedAt
        )
        attempt.completionRawValue = "failed"
        attempt.safeErrorCode = safeErrorCode
        attempt.completedAt = now
        modelContext.insert(attempt)
        try saveOrRollback()
    }

    func markSelectorInvalid(
        _ claim: SmsOperationClaim,
        safeErrorCode: String,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        guard let attempt = try selectorAttempt(operationID: claim.operationID) else {
            throw SmsProcessingStoreError.stateConflict
        }
        attempt.safeErrorCode = safeErrorCode
        attempt.completionRawValue = "invalid"
        try saveOrRollback()
    }

    func recordNormalizedResult(
        _ claim: SmsOperationClaim,
        semanticResultJSON: String,
        decision: String?,
        now: Date = .now
    ) throws {
        _ = try requireOwned(claim, now: now)
        let targetID = claim.operationID
        if let existing = try modelContext.fetch(
            FetchDescriptor<SmsReconstructedResult>(
                predicate: #Predicate { $0.operationID == targetID }
            )
        ).first {
            existing.recognitionDecisionRawValue = decision ?? existing.recognitionDecisionRawValue
            existing.semanticResultJSON = semanticResultJSON
            try saveOrRollback()
            return
        }
        modelContext.insert(
            SmsReconstructedResult(
                operationID: claim.operationID,
                contractVersion: "pocketfinancer.processing-result/3",
                recognitionDecision: decision ?? "",
                semanticResultJSON: semanticResultJSON,
                createdAt: now
            )
        )
        try saveOrRollback()
    }

    func recordGateDecision(
        _ claim: SmsOperationClaim,
        result: String,
        primaryReason: String,
        checksJSON: String,
        accountResolutionJSON: String,
        rolloutMode: String = "automatic",
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
                rolloutMode: rolloutMode,
                createdAt: now
            )
        )
        try saveOrRollback()
    }

    func openReviewCaseID(sourceAlertID: UUID) throws -> UUID? {
        let targetID = sourceAlertID
        let cases = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate { $0.sourceAlertID == targetID },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
        return cases.first { [.open, .draft, .waitingRetry].contains($0.state) }?.id
    }

    func loadReviewDetails(sourceAlertID: UUID) throws -> SmsReviewDetails? {
        guard let reviewCaseID = try openReviewCaseID(sourceAlertID: sourceAlertID) else {
            return nil
        }
        return try loadReviewDetails(reviewCaseID: reviewCaseID)
    }

    func loadReviewDetails(reviewCaseID: UUID) throws -> SmsReviewDetails {
        let targetReviewID = reviewCaseID
        guard
            let review = try modelContext.fetch(
                FetchDescriptor<SmsReviewCase>(predicate: #Predicate { $0.id == targetReviewID })
            ).first
        else { throw SmsProcessingStoreError.reviewCaseNotFound }

        let sourceID = review.sourceAlertID
        guard
            let alert = try modelContext.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
            ).first
        else { throw SmsProcessingStoreError.sourceNotFound }

        let targetOperationID = review.currentOperationID
        guard let operation = try operation(id: targetOperationID) else {
            throw SmsProcessingStoreError.operationNotFound
        }

        let storedResult = try modelContext.fetch(
            FetchDescriptor<SmsReconstructedResult>(
                predicate: #Predicate { $0.operationID == targetOperationID }
            )
        ).first
        let analysis = try modelContext.fetch(
            FetchDescriptor<SmsProcessingAnalysis>(
                predicate: #Predicate { $0.operationID == targetOperationID }
            )
        ).first

        let proposal: SmsReviewProposal? =
            if let storedResult,
                storedResult.contractVersion == "pocketfinancer.processing-result/3",
                storedResult.recognitionDecisionRawValue == "posted"
            {
                SmsReviewProjection.parse(
                    resultJSON: storedResult.semanticResultJSON,
                    source: alert.rawBody
                )
            } else {
                nil
            }

        let retainedEvidence = SmsReviewProjection.parseRetainedEvidence(
            resultJSON: storedResult?.semanticResultJSON,
            analysisJSON: analysis?.canonicalJSON,
            operationConfigurationJSON: operation.configurationJSON,
            source: alert.rawBody,
            fallbackPrimaryCurrency: PrimaryCurrencySettings.currentCode,
            fallbackReceiptTimestamp: alert.receivedAt,
            fallbackReceiptProvenance: "platform_received"
        )

        let draftCorrections: [SmsFieldCorrection] =
            if let draftJSON = review.draftJSON,
                let decoded = try? JSONDecoder().decode(
                    [SmsFieldCorrection].self,
                    from: Data(draftJSON.utf8)
                )
            {
                decoded
            } else {
                []
            }

        let accountReference =
            proposal?.accountReference
            ?? retainedEvidence.slmFields[.account]?.normalizedAccount
        let matchedAccountIDs =
            accountReference.flatMap { try? matchingAccountIDs(forNormalizedReference: $0) } ?? []
        let ambiguousAccountIDs = matchedAccountIDs.count >= 2 ? matchedAccountIDs : []
        let suggestedAccountID = try suggestAccountID(
            matchedAccountIDs: matchedAccountIDs,
            proposalAccountID: proposal?.resolvedAccountID,
            accountReference: accountReference
        )

        let amountMinorUnits =
            proposal?.amountMinorUnits
            ?? retainedEvidence.slmFields[.amount]?.normalizedAmount?.minorUnits
        let currency =
            proposal?.currency
            ?? retainedEvidence.slmFields[.amount]?.normalizedAmount?.currency
            ?? retainedEvidence.primaryCurrency
        let direction =
            proposal?.direction
            ?? retainedEvidence.slmFields[.direction]?.normalizedDirection?.rawValue
        let effectiveAccountID =
            matchedAccountIDs.count == 1 ? matchedAccountIDs[0] : proposal?.resolvedAccountID

        let liveAlreadyPersisted = try isSourceAlreadyPersisted(
            operationID: operation.id,
            sourceID: sourceID,
            stableEventID: operation.stableEventID
        )
        let duplicateMatches: [DuplicateWindowTransactionSummary]
        let duplicateStatus: String
        if liveAlreadyPersisted {
            duplicateStatus = "already_persisted"
            duplicateMatches = []
        } else if let amountMinorUnits, let direction, let effectiveAccountID {
            duplicateMatches = try matchingDuplicateWindowTransactions(
                sourceID: sourceID,
                accountID: effectiveAccountID,
                direction: direction,
                minorUnits: amountMinorUnits,
                currency: currency,
                occurredAt: retainedEvidence.receiptTimestamp,
                excludedOperationID: operation.id
            )
            duplicateStatus = duplicateMatches.isEmpty ? "clear" : "possible_duplicate"
        } else {
            duplicateStatus = "clear"
            duplicateMatches = []
        }

        let reasonCodes = review.reasonCodesRawValue
            .split(separator: "\n")
            .map(String.init)
        return SmsReviewDetails(
            reviewCaseID: review.id,
            reviewRevision: review.revision,
            reviewState: review.state,
            sourceAlertID: sourceID,
            operationID: operation.id,
            sender: alert.sender,
            rawBody: alert.rawBody,
            receivedAt: retainedEvidence.receiptTimestamp,
            primaryCurrency: retainedEvidence.primaryCurrency,
            reasonCodes: reasonCodes,
            proposal: proposal,
            retainedEvidence: retainedEvidence,
            draftCorrections: draftCorrections,
            ambiguousAccountIDs: ambiguousAccountIDs,
            suggestedAccountID: suggestedAccountID,
            duplicateStatus: duplicateStatus,
            duplicateMatches: duplicateMatches
        )
    }

    private func suggestAccountID(
        matchedAccountIDs: [UUID],
        proposalAccountID: UUID?,
        accountReference: String?
    ) throws -> UUID? {
        if matchedAccountIDs.count == 1 {
            return matchedAccountIDs[0]
        }
        guard matchedAccountIDs.isEmpty else { return nil }
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        if let proposalAccountID, accounts.contains(where: { $0.id == proposalAccountID }) {
            return proposalAccountID
        }
        guard
            let accountReference,
            let normalized = SmsExtractorNormalizer.normalizeAccount(accountReference),
            !normalized.contains("@")
        else { return nil }
        let suffixMatches = accounts.filter { account in
            guard let suffix = account.suffix, !suffix.isEmpty else { return false }
            return SmsExtractorNormalizer.normalizeAccount(suffix) == normalized
        }
        return suffixMatches.count == 1 ? suffixMatches[0].id : nil
    }

    private func isSourceAlreadyPersisted(
        operationID: UUID,
        sourceID: UUID,
        stableEventID: UUID
    ) throws -> Bool {
        let operations = try modelContext.fetch(FetchDescriptor<SmsProcessingOperation>())
            .filter { $0.id != operationID }
        if operations.contains(where: {
            $0.state == .persisted
                && ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
        }) {
            return true
        }
        let persistedForSource = try modelContext.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.sourceAlertID == sourceID })
        )
        if !persistedForSource.isEmpty {
            return true
        }
        let currentRevisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate {
                    ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
                        && $0.isCurrentProjection
                }
            )
        )
        return !currentRevisions.isEmpty
    }

    func matchingAccountIDs(forNormalizedReference reference: String) throws -> [UUID] {
        guard let normalized = SmsExtractorNormalizer.normalizeAccount(reference) else {
            return []
        }
        let aliasKind = normalized.contains("@") ? "vpa" : "suffix"
        let aliasHash = CanonicalJSON.sha256("\(aliasKind):\(normalized)")
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
        let liveAccountIDs = Set(try modelContext.fetch(FetchDescriptor<Account>()).map(\.id))
        return Array(Set(aliases.map(\.accountID)).intersection(liveAccountIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    func matchingDuplicateWindowTransactions(
        sourceID: UUID,
        accountID: UUID?,
        direction: String,
        minorUnits: Int64,
        currency: String,
        occurredAt: Date,
        windowSeconds: TimeInterval = SmsContractAssets.duplicateWindowSeconds,
        excludedOperationID: UUID? = nil
    ) throws -> [DuplicateWindowTransactionSummary] {
        guard let accountID else { return [] }
        let excludedTransactionIDs: Set<UUID>
        if let excludedOperationID {
            let targetOperationID = excludedOperationID
            excludedTransactionIDs = Set(
                try modelContext.fetch(
                    FetchDescriptor<SmsTransactionRevision>(
                        predicate: #Predicate { $0.operationID == targetOperationID }
                    )
                ).map(\.transactionID)
            )
        } else {
            excludedTransactionIDs = []
        }
        let normalizedCurrency = currency.uppercased()
        let transactions = try modelContext.fetch(FetchDescriptor<Transaction>())
        let matches = transactions.filter { tx in
            guard tx.sourceAlertID != sourceID,
                !excludedTransactionIDs.contains(tx.id),
                tx.accountID == accountID,
                tx.directionRawValue == direction,
                tx.amountMinorUnits == minorUnits,
                tx.currencyCode.uppercased() == normalizedCurrency
            else { return false }
            return abs(tx.occurredAt.timeIntervalSince(occurredAt)) <= windowSeconds
        }
        return matches.sorted {
            abs($0.occurredAt.timeIntervalSince(occurredAt))
                < abs($1.occurredAt.timeIntervalSince(occurredAt))
        }.map { tx in
            DuplicateWindowTransactionSummary(
                id: tx.id,
                amountMinorUnits: tx.amountMinorUnits,
                currencyCode: tx.currencyCode,
                direction: tx.direction,
                merchant: tx.merchant,
                accountID: tx.accountID,
                accountLabel: tx.accountLabel,
                occurredAt: tx.occurredAt,
                sourceAlertID: tx.sourceAlertID
            )
        }
    }

    func duplicateStatus(
        operationID: UUID,
        sourceID: UUID,
        stableEventID: UUID,
        accountID: UUID?,
        direction: String,
        minorUnits: Int64,
        currency: String,
        occurredAt: Date,
        windowSeconds: TimeInterval = SmsContractAssets.duplicateWindowSeconds
    ) throws -> String {
        let operations = try modelContext.fetch(FetchDescriptor<SmsProcessingOperation>())
            .filter { $0.id != operationID }
        if operations.contains(where: {
            $0.state == .persisted
                && ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
        }) {
            return "already_persisted"
        }
        let persistedForSource = try modelContext.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.sourceAlertID == sourceID })
        )
        if !persistedForSource.isEmpty {
            return "already_persisted"
        }
        let currentRevisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate {
                    ($0.sourceAlertID == sourceID || $0.stableEventID == stableEventID)
                        && $0.isCurrentProjection
                }
            )
        )
        if !currentRevisions.isEmpty {
            return "already_persisted"
        }
        let matches = try matchingDuplicateWindowTransactions(
            sourceID: sourceID,
            accountID: accountID,
            direction: direction,
            minorUnits: minorUnits,
            currency: currency,
            occurredAt: occurredAt,
            windowSeconds: windowSeconds,
            excludedOperationID: operationID
        )
        return matches.isEmpty ? "clear" : "possible_duplicate"
    }

    func persistAutomaticTransaction(
        _ claim: SmsOperationClaim,
        extraction: SmsExtractedTransaction,
        accountID: UUID,
        operation: SmsOperationSnapshot,
        now: Date = .now
    ) throws -> UUID {
        let persistedOperation = try requireOwned(claim, now: now)
        let sourceID = persistedOperation.sourceAlertID
        guard sourceID == operation.sourceID else {
            throw SmsProcessingStoreError.configurationMismatch
        }
        let occurredAt = Date(
            timeIntervalSince1970: TimeInterval(operation.configuration.receivedTimestamp.epochMs) / 1_000
        )
        let duplicateState = try duplicateStatus(
            operationID: operation.operationID,
            sourceID: sourceID,
            stableEventID: operation.stableEventID,
            accountID: accountID,
            direction: extraction.direction.rawValue,
            minorUnits: extraction.minorUnits,
            currency: extraction.currency,
            occurredAt: occurredAt
        )
        guard duplicateState == "clear" else {
            throw SmsProcessingStoreError.stateConflict
        }
        guard
            let alert = try modelContext.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
            ).first,
            !alert.rawBody.isEmpty,
            alert.transactionID == nil
        else { throw SmsProcessingStoreError.stateConflict }
        let targetAccountID = accountID
        guard
            let account = try modelContext.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == targetAccountID })
            ).first
        else { throw SmsProcessingStoreError.invalidCommand }
        let stableEventID = persistedOperation.stableEventID
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
            let direction = TransactionDirection(rawValue: extraction.direction.rawValue),
            let scale = CurrencyFormatter.supportedScales[extraction.currency]
        else { throw SmsProcessingStoreError.invalidCommand }
        let merchant = extraction.counterparty ?? "Unspecified counterparty"
        let transaction = Transaction(
            amountMinorUnits: extraction.minorUnits,
            currencyCode: extraction.currency,
            merchant: merchant,
            occurredAt: occurredAt,
            direction: direction,
            accountID: account.id,
            accountLabel: account.name,
            isEdited: false,
            parserName: SmsContractAssets.releaseID,
            reviewState: .confirmed,
            sourceAlertID: sourceID,
            amountEvidenceText: extraction.amountSpan.text,
            dateEvidenceText: nil,
            now: now
        )
        modelContext.insert(transaction)
        alert.transactionID = transaction.id
        alert.status = .imported
        alert.lastErrorCode = nil
        alert.rejectionCode = nil
        alert.parserName = SmsContractAssets.releaseID
        alert.updatedAt = now
        let priorRevisions = try modelContext.fetch(
            FetchDescriptor<SmsTransactionRevision>(
                predicate: #Predicate { $0.sourceAlertID == sourceID },
                sortBy: [SortDescriptor(\.revision)]
            )
        )
        let previousRevision = priorRevisions.last
        let revision = SmsTransactionRevision(
            transactionID: transaction.id,
            sourceAlertID: sourceID,
            stableEventID: stableEventID,
            revision: (previousRevision?.revision ?? -1) + 1,
            previousRevisionID: previousRevision?.id,
            operationID: operation.operationID,
            feedbackActionID: nil,
            amountMinorUnits: extraction.minorUnits,
            currencyCode: extraction.currency,
            currencyScale: scale,
            direction: direction.rawValue,
            merchant: merchant,
            accountID: account.id,
            occurredAt: occurredAt,
            provenance: "automatic_grounded_extraction",
            isCurrentProjection: true,
            createdAt: now
        )
        modelContext.insert(revision)
        let openReviews = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate { $0.sourceAlertID == sourceID }
            )
        )
        for reviewCase in openReviews where [.open, .draft, .waitingRetry].contains(reviewCase.state) {
            reviewCase.currentOperationID = persistedOperation.id
            reviewCase.state = .confirmed
            reviewCase.draftJSON = nil
            reviewCase.updatedAt = now
        }
        persistedOperation.state = .persisted
        persistedOperation.transitionSequence += 1
        persistedOperation.ownerToken = nil
        persistedOperation.claimExpiresAt = nil
        persistedOperation.settledAt = now
        persistedOperation.updatedAt = now
        persistedOperation.settlementReceiptJSON = try CanonicalJSON.string(
            PersistedSettlement(operationID: operation.operationID, transactionIDs: [transaction.id])
        )
        try saveOrRollback()
        return transaction.id
    }

    func settleDiscarded(
        _ claim: SmsOperationClaim,
        retentionState: String,
        reason: String,
        now: Date = .now
    ) throws {
        let operation = try requireOwned(claim, now: now)
        let sourceID = operation.sourceAlertID
        if let alert = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        ).first {
            alert.eraseSensitiveEvidence(now: now)
            alert.status = .rejected
            alert.rejectionCode = retentionState
            alert.lastErrorCode = reason
            alert.updatedAt = now
        }
        try scrubSensitiveArtifacts(
            sourceAlertID: sourceID,
            retentionState: retentionState,
            now: now
        )
        operation.state = .discarded
        operation.transitionSequence += 1
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        operation.settledAt = now
        operation.updatedAt = now
        operation.settlementReceiptJSON = try CanonicalJSON.string(
            TombstoneSettlement(retentionState: retentionState, reason: reason)
        )
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
        let sourceID = operation.sourceAlertID
        if let alert = try modelContext.fetch(
            FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        ).first,
            alert.status != .imported,
            alert.status != .rejected
        {
            alert.status = .needsReview
            alert.lastErrorCode = reasons.first
            alert.updatedAt = now
        }
        if let existing = try modelContext.fetch(
            FetchDescriptor<SmsReviewCase>(
                predicate: #Predicate {
                    $0.currentOperationID == targetID
                })
        ).first {
            operation.ownerGeneration += 1
            operation.ownerToken = nil
            operation.claimExpiresAt = nil
            operation.state = .retainedReview
            operation.transitionSequence += 1
            operation.updatedAt = now
            operation.settledAt = now
            operation.settlementReceiptJSON = try CanonicalJSON.string(
                ReviewSettlement(reviewCaseID: existing.id, reasons: reasons)
            )
            try saveOrRollback()
            return existing.id
        }
        if let retried = try reusableReviewCase(for: operation) {
            retried.currentOperationID = operationID
            retried.reasonCodesRawValue = reasons.joined(separator: "\n")
            retried.state = .open
            retried.updatedAt = now
            var stableIDs = Set(
                retried.stableEventIDsRawValue.split(separator: "\n").map(String.init)
            )
            stableIDs.insert(operation.stableEventID.uuidString)
            retried.stableEventIDsRawValue = stableIDs.sorted().joined(separator: "\n")
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
        operation.ownerGeneration += 1
        operation.ownerToken = nil
        operation.claimExpiresAt = nil
        operation.state = .retainedReview
        operation.transitionSequence += 1
        operation.updatedAt = now
        operation.settledAt = now
        let review = SmsReviewCase(
            sourceAlertID: sourceID,
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
        guard claim.eraseEpoch == Self.currentEraseEpoch(for: modelContainer) else {
            throw SmsProcessingStoreError.lostOwnership
        }
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

nonisolated private struct TombstoneSettlement: Codable {
    let retentionState: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case retentionState = "retention_state"
        case reason
    }
}

nonisolated private struct PersistedSettlement: Codable {
    let operationID: UUID
    let transactionIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case transactionIDs = "transaction_ids"
    }
}
