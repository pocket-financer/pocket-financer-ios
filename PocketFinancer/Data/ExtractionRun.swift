import Foundation
import SwiftData

/// Schema-compatibility value types retained for `PocketFinancerSchemaV2`..`V7`.
enum DraftClassification: String, Sendable {
    case transaction
    case nonTransaction = "non_transaction"
}

struct ParsedAlertDraft: Equatable, Sendable {
    let classification: DraftClassification
    let direction: String
    let amountText: String
    let merchant: String
    let accountLabel: String
    let occurredAtText: String
    let currencyCode: String
}

enum EvidenceValidationStage: String, CaseIterable, Sendable {
    case classification
    case direction
    case amount
    case merchant
    case account
    case date
}

enum EvidenceValidationStageState: String, Sendable {
    case passed
    case failed
    case notRun = "not_run"
}

enum ExtractionValidationOutcome: String, CaseIterable, Sendable {
    case notPerformed = "not_performed"
    case passed
    case failed
}

enum ExtractionRunDisposition: String, CaseIterable, Sendable {
    case imported
    case queued
    case needsReview = "needs_review"
}

/// A local, owner-visible snapshot of one historical parser attempt.
///
/// `exactInstructions`, `exactRequest`, and the draft fields are sensitive financial
/// evidence. They belong only in the protected SwiftData store and must never be logged.
@Model
final class ExtractionRun {
    @Attribute(.unique) var id: UUID
    var alertID: UUID
    var attemptIndex: Int
    var startedAt: Date
    var responseReceivedAt: Date?
    var completedAt: Date?
    var parserName: String
    var contractVersion: String
    var profileVersion: String
    var localeIdentifier: String
    var localeWasSupported: Bool?
    var supportedLanguageIdentifiersRawValue: String
    var exactInstructions: String
    var exactRequest: String
    var draftClassificationRawValue: String?
    var draftDirection: String?
    var draftAmountText: String?
    var draftMerchant: String?
    var draftAccountLabel: String?
    var draftOccurredAtText: String?
    var draftCurrencyCode: String?
    var validationClassificationStateRawValue: String?
    var validationDirectionStateRawValue: String?
    var validationAmountStateRawValue: String?
    var validationMerchantStateRawValue: String?
    var validationAccountStateRawValue: String?
    var validationDateStateRawValue: String?
    var validationOutcomeRawValue: String?
    var safeResultCode: String?
    var terminalDispositionRawValue: String?
    var acceptedTransactionID: UUID?
    var acceptedAmountMinorUnits: Int64?
    var acceptedCurrencyCode: String?
    var acceptedDirectionRawValue: String?
    var acceptedMerchant: String?
    var acceptedAccountLabel: String?
    var acceptedOccurredAt: Date?
    var acceptedReviewStateRawValue: String?
    var acceptedAmountEvidenceText: String?
    var acceptedDateEvidenceText: String?

    init(
        id: UUID = UUID(),
        alertID: UUID,
        attemptIndex: Int,
        startedAt: Date,
        parserName: String,
        contractVersion: String,
        profileVersion: String,
        localeIdentifier: String,
        localeWasSupported: Bool? = nil,
        supportedLanguageIdentifiers: [String] = [],
        exactInstructions: String,
        exactRequest: String
    ) {
        self.id = id
        self.alertID = alertID
        self.attemptIndex = attemptIndex
        self.startedAt = startedAt
        self.parserName = parserName
        self.contractVersion = contractVersion
        self.profileVersion = profileVersion
        self.localeIdentifier = localeIdentifier
        self.localeWasSupported = localeWasSupported
        self.supportedLanguageIdentifiersRawValue = Array(Set(supportedLanguageIdentifiers))
            .sorted()
            .joined(separator: "\n")
        self.exactInstructions = exactInstructions
        self.exactRequest = exactRequest
    }

    var parserDraft: ParsedAlertDraft? {
        guard
            let classificationRawValue = draftClassificationRawValue,
            let classification = DraftClassification(rawValue: classificationRawValue),
            let direction = draftDirection,
            let amountText = draftAmountText,
            let merchant = draftMerchant,
            let accountLabel = draftAccountLabel,
            let occurredAtText = draftOccurredAtText,
            let currencyCode = draftCurrencyCode
        else {
            return nil
        }

        return ParsedAlertDraft(
            classification: classification,
            direction: direction,
            amountText: amountText,
            merchant: merchant,
            accountLabel: accountLabel,
            occurredAtText: occurredAtText,
            currencyCode: currencyCode
        )
    }

    var supportedLanguageIdentifiers: [String] {
        supportedLanguageIdentifiersRawValue
            .split(separator: "\n")
            .map(String.init)
    }

    var validationOutcome: ExtractionValidationOutcome? {
        validationOutcomeRawValue.flatMap(ExtractionValidationOutcome.init(rawValue:))
    }

    var terminalDisposition: ExtractionRunDisposition? {
        terminalDispositionRawValue.flatMap(ExtractionRunDisposition.init(rawValue:))
    }

    var acceptedDirection: TransactionDirection? {
        acceptedDirectionRawValue.flatMap(TransactionDirection.init(rawValue:))
    }

    var acceptedReviewState: ReviewState? {
        acceptedReviewStateRawValue.flatMap(ReviewState.init(rawValue:))
    }

    var totalDuration: TimeInterval? {
        completedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    var parserDuration: TimeInterval? {
        responseReceivedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    func validationState(for stage: EvidenceValidationStage) -> EvidenceValidationStageState? {
        let rawValue: String?
        switch stage {
        case .classification:
            rawValue = validationClassificationStateRawValue
        case .direction:
            rawValue = validationDirectionStateRawValue
        case .amount:
            rawValue = validationAmountStateRawValue
        case .merchant:
            rawValue = validationMerchantStateRawValue
        case .account:
            rawValue = validationAccountStateRawValue
        case .date:
            rawValue = validationDateStateRawValue
        }
        return rawValue.flatMap(EvidenceValidationStageState.init(rawValue:))
    }
}
