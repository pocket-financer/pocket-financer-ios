import Foundation
import SwiftData

enum SmsOperationState: String, CaseIterable, Sendable {
    case admitted
    case awaitingConfiguration = "awaiting_configuration"
    case ready
    case claimed
    case analyzed
    case triaged
    case selectorRunning = "selector_running"
    case selectorRecorded = "selector_recorded"
    case validated
    case reconstructed
    case persisted
    case retainedReview = "retain_review"
    case retryWait = "retry_wait"
    case interrupted
    case discarded
}

enum SmsReviewState: String, CaseIterable, Sendable {
    case open
    case draft
    case waitingRetry = "waiting_retry"
    case confirmed
    case corrected
    case rejected
}

/// Append-only metadata observed after the immutable alert admission record.
@Model
final class SmsSourceMetadataEvent {
    @Attribute(.unique) var id: UUID
    var sourceAlertID: UUID
    var sequence: Int
    var kindRawValue: String
    var payloadJSON: String
    var occurredAt: Date

    init(
        id: UUID = UUID(),
        sourceAlertID: UUID,
        sequence: Int,
        kind: String,
        payloadJSON: String,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.sourceAlertID = sourceAlertID
        self.sequence = sequence
        self.kindRawValue = kind
        self.payloadJSON = payloadJSON
        self.occurredAt = occurredAt
    }
}

/// Immutable operation identity/configuration plus fenced mutable processing state.
@Model
final class SmsProcessingOperation {
    @Attribute(.unique) var id: UUID
    var sourceAlertID: UUID
    var parentOperationID: UUID?
    var stableEventID: UUID
    var triggerRawValue: String
    var configurationJSON: String
    var configurationHash: String
    var contractReleaseID: String
    var stateRawValue: String
    var transitionSequence: Int
    var ownerToken: UUID?
    var ownerGeneration: Int64
    var claimExpiresAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var settledAt: Date?
    var settlementReceiptJSON: String?
    var deletionEpoch: Int64

    init(
        id: UUID = UUID(),
        sourceAlertID: UUID,
        parentOperationID: UUID? = nil,
        stableEventID: UUID = UUID(),
        trigger: String,
        configurationJSON: String,
        configurationHash: String,
        contractReleaseID: String,
        state: SmsOperationState = .ready,
        createdAt: Date = .now,
        deletionEpoch: Int64 = 0
    ) {
        self.id = id
        self.sourceAlertID = sourceAlertID
        self.parentOperationID = parentOperationID
        self.stableEventID = stableEventID
        self.triggerRawValue = trigger
        self.configurationJSON = configurationJSON
        self.configurationHash = configurationHash
        self.contractReleaseID = contractReleaseID
        self.stateRawValue = state.rawValue
        self.transitionSequence = 0
        self.ownerGeneration = 0
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletionEpoch = deletionEpoch
    }

    var state: SmsOperationState {
        get { SmsOperationState(rawValue: stateRawValue) ?? .interrupted }
        set { stateRawValue = newValue.rawValue }
    }
}

@Model
final class SmsProcessingAnalysis {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var analysisID: String
    var contractVersion: String
    var sourceHash: String
    var configurationHash: String
    var canonicalJSON: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        operationID: UUID,
        analysisID: String,
        contractVersion: String,
        sourceHash: String,
        configurationHash: String,
        canonicalJSON: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.operationID = operationID
        self.analysisID = analysisID
        self.contractVersion = contractVersion
        self.sourceHash = sourceHash
        self.configurationHash = configurationHash
        self.canonicalJSON = canonicalJSON
        self.createdAt = createdAt
    }
}

@Model
final class SmsSelectorAttempt {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var attemptIndex: Int
    var runtimeProfileJSON: String
    var requestJSON: String
    var rawOutput: String?
    var outputByteCount: Int?
    var completionRawValue: String
    var validatedSelectionJSON: String?
    var safeErrorCode: String?
    var startedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        operationID: UUID,
        attemptIndex: Int,
        runtimeProfileJSON: String,
        requestJSON: String,
        startedAt: Date = .now
    ) {
        self.id = id
        self.operationID = operationID
        self.attemptIndex = attemptIndex
        self.runtimeProfileJSON = runtimeProfileJSON
        self.requestJSON = requestJSON
        self.completionRawValue = "running"
        self.startedAt = startedAt
    }
}

@Model
final class SmsProcessingTraceEvent {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var sequence: Int
    var occurredAt: Date
    var stageRawValue: String
    var statusRawValue: String
    var reasonCodesRawValue: String
    var detailJSON: String?
    var previousEventHash: String?
    var eventHash: String

    init(
        id: UUID = UUID(),
        operationID: UUID,
        sequence: Int,
        occurredAt: Date = .now,
        stage: String,
        status: String,
        reasonCodes: [String] = [],
        detailJSON: String? = nil,
        previousEventHash: String? = nil,
        eventHash: String
    ) {
        self.id = id
        self.operationID = operationID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.stageRawValue = stage
        self.statusRawValue = status
        self.reasonCodesRawValue = reasonCodes.joined(separator: "\n")
        self.detailJSON = detailJSON
        self.previousEventHash = previousEventHash
        self.eventHash = eventHash
    }

    var reasonCodes: [String] {
        reasonCodesRawValue.split(separator: "\n").map(String.init)
    }
}

@Model
final class SmsReconstructedResult {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var contractVersion: String
    var recognitionDecisionRawValue: String
    var semanticResultJSON: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        operationID: UUID,
        contractVersion: String,
        recognitionDecision: String,
        semanticResultJSON: String?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.operationID = operationID
        self.contractVersion = contractVersion
        self.recognitionDecisionRawValue = recognitionDecision
        self.semanticResultJSON = semanticResultJSON
        self.createdAt = createdAt
    }
}

@Model
final class SmsPersistenceDecision {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var resultRawValue: String
    var primaryReason: String
    var checksJSON: String
    var accountResolutionJSON: String
    var rolloutModeRawValue: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        operationID: UUID,
        result: String,
        primaryReason: String,
        checksJSON: String,
        accountResolutionJSON: String,
        rolloutMode: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.operationID = operationID
        self.resultRawValue = result
        self.primaryReason = primaryReason
        self.checksJSON = checksJSON
        self.accountResolutionJSON = accountResolutionJSON
        self.rolloutModeRawValue = rolloutMode
        self.createdAt = createdAt
    }
}

@Model
final class SmsReviewCase {
    @Attribute(.unique) var id: UUID
    var sourceAlertID: UUID
    var currentOperationID: UUID
    var stateRawValue: String
    var revision: Int
    var reasonCodesRawValue: String
    var draftJSON: String?
    var stableEventIDsRawValue: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceAlertID: UUID,
        currentOperationID: UUID,
        state: SmsReviewState = .open,
        revision: Int = 0,
        reasonCodes: [String],
        draftJSON: String? = nil,
        stableEventIDs: [UUID] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceAlertID = sourceAlertID
        self.currentOperationID = currentOperationID
        self.stateRawValue = state.rawValue
        self.revision = revision
        self.reasonCodesRawValue = reasonCodes.joined(separator: "\n")
        self.draftJSON = draftJSON
        self.stableEventIDsRawValue = stableEventIDs.map(\.uuidString).joined(separator: "\n")
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var state: SmsReviewState {
        get { SmsReviewState(rawValue: stateRawValue) ?? .open }
        set { stateRawValue = newValue.rawValue }
    }
}

@Model
final class SmsUserFeedbackEvent {
    @Attribute(.unique) var actionID: UUID
    var reviewCaseID: UUID?
    var operationID: UUID?
    var transactionID: UUID?
    var transactionRevisionID: UUID?
    var expectedReviewRevision: Int
    var resultingReviewRevision: Int
    var actionRawValue: String
    var actorClassRawValue: String
    var correctionsJSON: String
    var retryConfigurationRawValue: String?
    var canonicalLabelID: String?
    var canonicalLabelRevision: Int?
    var previousEventHash: String?
    var eventHash: String
    var createdAt: Date

    init(
        actionID: UUID,
        reviewCaseID: UUID?,
        operationID: UUID?,
        transactionID: UUID? = nil,
        transactionRevisionID: UUID?,
        expectedReviewRevision: Int,
        resultingReviewRevision: Int,
        action: String,
        actorClass: String,
        correctionsJSON: String,
        retryConfiguration: String?,
        canonicalLabelID: String? = nil,
        canonicalLabelRevision: Int? = nil,
        previousEventHash: String?,
        eventHash: String,
        createdAt: Date = .now
    ) {
        self.actionID = actionID
        self.reviewCaseID = reviewCaseID
        self.operationID = operationID
        self.transactionID = transactionID
        self.transactionRevisionID = transactionRevisionID
        self.expectedReviewRevision = expectedReviewRevision
        self.resultingReviewRevision = resultingReviewRevision
        self.actionRawValue = action
        self.actorClassRawValue = actorClass
        self.correctionsJSON = correctionsJSON
        self.retryConfigurationRawValue = retryConfiguration
        self.canonicalLabelID = canonicalLabelID
        self.canonicalLabelRevision = canonicalLabelRevision
        self.previousEventHash = previousEventHash
        self.eventHash = eventHash
        self.createdAt = createdAt
    }
}

@Model
final class SmsTransactionRevision {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var sourceAlertID: UUID
    var stableEventID: UUID
    var revision: Int
    var previousRevisionID: UUID?
    var operationID: UUID?
    var feedbackActionID: UUID?
    var amountMinorUnits: Int64?
    var currencyCode: String?
    var currencyScale: Int?
    var directionRawValue: String?
    var merchant: String?
    var accountID: UUID?
    var occurredAt: Date?
    var provenanceRawValue: String
    var isCurrentProjection: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        transactionID: UUID,
        sourceAlertID: UUID,
        stableEventID: UUID,
        revision: Int,
        previousRevisionID: UUID?,
        operationID: UUID?,
        feedbackActionID: UUID?,
        amountMinorUnits: Int64?,
        currencyCode: String?,
        currencyScale: Int?,
        direction: String?,
        merchant: String?,
        accountID: UUID?,
        occurredAt: Date?,
        provenance: String,
        isCurrentProjection: Bool,
        createdAt: Date = .now
    ) {
        self.id = id
        self.transactionID = transactionID
        self.sourceAlertID = sourceAlertID
        self.stableEventID = stableEventID
        self.revision = revision
        self.previousRevisionID = previousRevisionID
        self.operationID = operationID
        self.feedbackActionID = feedbackActionID
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.currencyScale = currencyScale
        self.directionRawValue = direction
        self.merchant = merchant
        self.accountID = accountID
        self.occurredAt = occurredAt
        self.provenanceRawValue = provenance
        self.isCurrentProjection = isCurrentProjection
        self.createdAt = createdAt
    }
}

@Model
final class SmsAccountAlias {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var normalizedAliasHash: String
    var aliasKindRawValue: String
    var matchingScopeRawValue: String
    var confirmedByUser: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        accountID: UUID,
        normalizedAliasHash: String,
        aliasKind: String,
        matchingScope: String,
        confirmedByUser: Bool,
        createdAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.normalizedAliasHash = normalizedAliasHash
        self.aliasKindRawValue = aliasKind
        self.matchingScopeRawValue = matchingScope
        self.confirmedByUser = confirmedByUser
        self.createdAt = createdAt
    }
}

@Model
final class SmsLegacyTransactionSnapshot {
    @Attribute(.unique) var transactionID: UUID
    var amountMinorUnits: Int64
    var currencyCode: String
    var merchant: String
    var occurredAt: Date
    var directionRawValue: String
    var accountID: UUID?
    var sourceAlertID: UUID
    var originalEditHistoryKnown: Bool
    var capturedAt: Date

    init(transaction: Transaction, capturedAt: Date = .now) {
        transactionID = transaction.id
        amountMinorUnits = transaction.amountMinorUnits
        currencyCode = transaction.currencyCode
        merchant = transaction.merchant
        occurredAt = transaction.occurredAt
        directionRawValue = transaction.directionRawValue
        accountID = transaction.accountID
        sourceAlertID = transaction.sourceAlertID
        originalEditHistoryKnown = false
        self.capturedAt = capturedAt
    }
}

@Model
final class SmsTraceImportReceipt {
    @Attribute(.unique) var transferID: UUID
    var manifestHash: String
    var sourcePlatformRawValue: String
    var consentedAt: Date
    var importedAt: Date
    var operationCount: Int
    var provenanceRawValue: String

    init(
        transferID: UUID,
        manifestHash: String,
        sourcePlatform: String,
        consentedAt: Date,
        importedAt: Date = .now,
        operationCount: Int,
        provenance: String
    ) {
        self.transferID = transferID
        self.manifestHash = manifestHash
        self.sourcePlatformRawValue = sourcePlatform
        self.consentedAt = consentedAt
        self.importedAt = importedAt
        self.operationCount = operationCount
        self.provenanceRawValue = provenance
    }
}

/// Makes the V7 contract boundary a real, lightweight SwiftData schema change.
/// Rows are created only when a native SMS release is explicitly activated.
@Model
final class SmsContractReleaseState {
    @Attribute(.unique) var releaseID: String
    var activatedAt: Date

    init(releaseID: String, activatedAt: Date = .now) {
        self.releaseID = releaseID
        self.activatedAt = activatedAt
    }
}
