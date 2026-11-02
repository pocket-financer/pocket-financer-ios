import Foundation

nonisolated struct ReconstructedSmsTransaction: Codable, Equatable, Sendable {
    let analysisID: String
    let stableEventID: UUID
    let amountCandidateID: String
    let directionCandidateID: String
    let accountCandidateID: String
    let counterpartyCandidateID: String
    let minorUnits: Int64
    let currency: String
    let currencyScale: Int
    let currencyProvenance: String
    let direction: String
    let accountEvidence: SmsEvidenceSpan?
    let accountIdentifier: String?
    let counterpartyEvidence: SmsEvidenceSpan?
    let occurredAtEpochMilliseconds: Int64?
    let timestampProvenance: String
}

enum SemanticReconstructionError: String, Error, Sendable {
    case notPosted = "reconstruction_not_posted"
    case candidateMissing = "reconstruction_candidate_missing"
    case invalidMoney = "reconstruction_invalid_money"
    case invalidDirection = "reconstruction_invalid_direction"
}

struct SemanticReconstructor: Sendable {
    nonisolated func reconstruct(
        selection: GroundedSelectorResult,
        analysis: SmsAnalysis,
        operation: SmsOperationSnapshot
    ) throws -> ReconstructedSmsTransaction {
        guard let selected = selection.posted, selection.decision == .posted else {
            throw SemanticReconstructionError.notPosted
        }
        let candidates = Dictionary(uniqueKeysWithValues: analysis.candidates.map { ($0.id, $0) })
        guard
            let amount = candidates[selected.amountCandidateID],
            let direction = candidates[selected.directionCandidateID],
            let account = candidates[selected.accountCandidateID],
            let counterparty = candidates[selected.counterpartyCandidateID]
        else { throw SemanticReconstructionError.candidateMissing }
        guard
            let minorText = amount.value["minor_units"],
            let minorUnits = Int64(minorText), minorUnits > 0,
            let currency = amount.value["currency"],
            let scale = CurrencyProfileRegistry.scales[currency]
        else { throw SemanticReconstructionError.invalidMoney }
        guard let directionValue = direction.value["direction"],
            directionValue == "debit" || directionValue == "credit"
        else { throw SemanticReconstructionError.invalidDirection }
        return ReconstructedSmsTransaction(
            analysisID: analysis.analysisID,
            stableEventID: operation.stableEventID,
            amountCandidateID: amount.id,
            directionCandidateID: direction.id,
            accountCandidateID: account.id,
            counterpartyCandidateID: counterparty.id,
            minorUnits: minorUnits,
            currency: currency,
            currencyScale: scale,
            currencyProvenance: amount.value["currency_provenance"] ?? "unknown",
            direction: directionValue,
            accountEvidence: account.evidence,
            accountIdentifier: account.value["identifier"],
            counterpartyEvidence: counterparty.evidence,
            occurredAtEpochMilliseconds: operation.configuration.sourceTimestampEpochMilliseconds,
            timestampProvenance: operation.configuration.sourceTimestampProvenance
        )
    }
}
