import Foundation
import SwiftData

/// Schema-compatibility value types retained for `PocketFinancerSchemaV4`..`V7`.
enum AlertRejectionCode: String, Sendable {
    case missingAmount = "missing_amount"
    case missingAccount = "missing_account"
    case missingTransactionVerb = "missing_transaction_verb"
    case oneTimePassword = "one_time_password"
    case collectRequest = "collect_request"
    case promotion = "promotion"
    case unsuccessfulTransaction = "unsuccessful_transaction"
    case emptyBody = "empty_body"
}

enum AlertFilterDecision: Equatable, Sendable {
    case eligible
    case needsReview
    case rejectAndErase
}

enum AlertFilterStageID: String, CaseIterable, Sendable {
    case nonEmptyBody
    case oneTimePassword
    case collectRequest
    case unsuccessfulTransaction
    case promotion
    case amount
    case account
    case transactionVerb
}

enum AlertFilterStageState: String, Equatable, Sendable {
    case passed
    case failed
    case notRun
}

struct AlertFilterStageOutcome: Equatable, Sendable {
    let id: AlertFilterStageID
    let title: String
    let detail: String
    let state: AlertFilterStageState
}

struct PersistedAlertFilterStage: Codable, Equatable, Sendable {
    let idRawValue: String
    let title: String
    let detail: String
    let stateRawValue: String

    init(_ stage: AlertFilterStageOutcome) {
        idRawValue = stage.id.rawValue
        title = stage.title
        detail = stage.detail
        stateRawValue = stage.state.rawValue
    }

    nonisolated var outcome: AlertFilterStageOutcome? {
        guard
            let id = AlertFilterStageID(rawValue: idRawValue),
            let state = AlertFilterStageState(rawValue: stateRawValue)
        else {
            return nil
        }
        return AlertFilterStageOutcome(
            id: id,
            title: title,
            detail: detail,
            state: state
        )
    }
}

/// Preserved historical deterministic filter trace for migrated V4..V7 stores.
@Model
final class DeterministicFilterRun {
    @Attribute(.unique) var id: UUID
    var alertID: UUID
    var evaluationIndex: Int
    var evaluatedAt: Date
    var rulesVersion: String
    var decisionRawValue: String
    var rejectionCodeRawValue: String?
    var completedStagesRawValue: String
    var senderWasUsed: Bool
    var stagesJSON: String
    var extractionRunID: UUID?

    init(
        id: UUID = UUID(),
        alertID: UUID,
        evaluationIndex: Int,
        evaluatedAt: Date,
        rulesVersion: String,
        decisionRawValue: String,
        rejectionCodeRawValue: String?,
        completedStages: [String],
        senderWasUsed: Bool,
        stagesJSON: String,
        extractionRunID: UUID? = nil
    ) {
        self.id = id
        self.alertID = alertID
        self.evaluationIndex = evaluationIndex
        self.evaluatedAt = evaluatedAt
        self.rulesVersion = rulesVersion
        self.decisionRawValue = decisionRawValue
        self.rejectionCodeRawValue = rejectionCodeRawValue
        self.completedStagesRawValue = completedStages.joined(separator: "\n")
        self.senderWasUsed = senderWasUsed
        self.stagesJSON = stagesJSON
        self.extractionRunID = extractionRunID
    }

    var decision: AlertFilterDecision? {
        switch decisionRawValue {
        case "eligible":
            return .eligible
        case "needs_review":
            return .needsReview
        case "reject_and_erase":
            return .rejectAndErase
        default:
            return nil
        }
    }

    var rejectionCode: AlertRejectionCode? {
        rejectionCodeRawValue.flatMap(AlertRejectionCode.init(rawValue:))
    }

    var completedStages: [String] {
        completedStagesRawValue.split(separator: "\n").map(String.init)
    }

    var stages: [AlertFilterStageOutcome]? {
        guard let data = stagesJSON.data(using: .utf8),
            let persisted = try? JSONDecoder().decode([PersistedAlertFilterStage].self, from: data)
        else {
            return nil
        }
        let outcomes = persisted.compactMap(\.outcome)
        return outcomes.count == persisted.count ? outcomes : nil
    }
}
