import Foundation

nonisolated enum SmsExtractorDecision: String, Codable, Sendable { case none, abstain, posted }
nonisolated enum SmsExtractorDirection: String, Codable, Sendable { case debit, credit }

nonisolated struct SmsExtractedTransaction: Codable, Equatable, Sendable {
    let minorUnits: Int64
    let currency: String
    let direction: SmsExtractorDirection
    let accountReference: String
    let counterparty: String?
    let amountSpan: UnicodeScalarSpan
    let directionSpan: UnicodeScalarSpan
    let accountSpan: UnicodeScalarSpan
    let counterpartySpan: UnicodeScalarSpan?
}

nonisolated struct SmsExtractorResult: Codable, Equatable, Sendable {
    let decision: SmsExtractorDecision
    let transaction: SmsExtractedTransaction?
}

nonisolated enum SmsExtractorValidationError: Error, Equatable, Sendable {
    case malformedJSON, duplicateJSONKey, extraContent, outputNotObject, decisionTypeInvalid
    case unknownDecision, nonPostedExtraFields, missingAmount, missingDirection, missingAccount
    case postedFieldSetInvalid, amountInvalid, currencyInvalid, directionInvalid, accountInvalid, counterpartyInvalid
    case evidenceInvalid, evidenceOutOfBounds, evidenceMismatch, amountValueDisagreement, outputTruncated

    var reasonCode: String {
        switch self {
        case .malformedJSON: "extractor_malformed_json"
        case .duplicateJSONKey: "extractor_duplicate_json_key"
        case .extraContent: "extractor_extra_content"
        case .outputNotObject: "extractor_output_not_object"
        case .decisionTypeInvalid: "extractor_decision_type_invalid"
        case .unknownDecision: "extractor_unknown_decision"
        case .nonPostedExtraFields: "extractor_non_posted_extra_fields"
        case .missingAmount: "extractor_missing_amount"
        case .missingDirection: "extractor_missing_direction"
        case .missingAccount: "extractor_missing_account"
        case .postedFieldSetInvalid: "extractor_posted_field_set_invalid"
        case .amountInvalid: "extractor_amount_invalid"
        case .currencyInvalid: "extractor_currency_invalid"
        case .directionInvalid: "extractor_direction_invalid"
        case .accountInvalid: "extractor_account_reference_invalid"
        case .counterpartyInvalid: "extractor_counterparty_invalid"
        case .evidenceInvalid: "extractor_evidence_invalid"
        case .evidenceOutOfBounds: "extractor_evidence_out_of_bounds"
        case .evidenceMismatch: "extractor_evidence_mismatch"
        case .amountValueDisagreement: "extractor_amount_value_disagreement"
        case .outputTruncated: "runtime_output_truncated"
        }
    }
}
