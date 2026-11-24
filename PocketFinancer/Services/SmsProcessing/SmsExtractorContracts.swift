import Foundation

nonisolated enum SmsExtractorDecision: String, Codable, Sendable {
    case none
    case abstain
    case posted
}

nonisolated enum SmsExtractorDirection: String, Codable, Sendable {
    case debit
    case credit
}

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

nonisolated struct DirectSelectorResponse: Equatable, Sendable {
    let rawOutput: String
    let runtimeProfileJSON: String
    let requestJSON: String
    let completion: String
}

nonisolated enum ModelUnavailabilityReason: String, Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

nonisolated enum TransactionParserError: Error, Equatable, Sendable {
    case modelUnavailable(ModelUnavailabilityReason)
    case timedOut
    case cancelled
    case assetsUnavailable
    case unsupportedLanguageOrLocale
    case guardrailViolation
    case unsupportedGuide
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case modelRefused
    case contextWindowExceeded
    case generationFailed

    var isRetryable: Bool {
        switch self {
        case .modelUnavailable(.appleIntelligenceNotEnabled),
            .modelUnavailable(.modelNotReady),
            .modelUnavailable(.unknown),
            .timedOut,
            .cancelled,
            .assetsUnavailable,
            .rateLimited,
            .concurrentRequests:
            true
        case .modelUnavailable(.deviceNotEligible),
            .unsupportedLanguageOrLocale,
            .guardrailViolation,
            .unsupportedGuide,
            .decodingFailure,
            .modelRefused,
            .contextWindowExceeded,
            .generationFailed:
            false
        }
    }

    var safeCode: String {
        switch self {
        case .modelUnavailable(let reason):
            "model_\(reason.rawValue)"
        case .timedOut:
            "model_timed_out"
        case .cancelled:
            "model_cancelled"
        case .assetsUnavailable:
            "model_assets_unavailable"
        case .unsupportedLanguageOrLocale:
            "model_unsupported_language"
        case .guardrailViolation:
            "model_guardrail_violation"
        case .unsupportedGuide:
            "model_unsupported_guide"
        case .decodingFailure:
            "model_decoding_failed"
        case .rateLimited:
            "model_rate_limited"
        case .concurrentRequests:
            "model_concurrent_requests"
        case .modelRefused:
            "model_refused"
        case .contextWindowExceeded:
            "model_context_window_exceeded"
        case .generationFailed:
            "model_generation_failed"
        }
    }
}

nonisolated enum SmsExtractorValidationError: Error, Equatable, Sendable {
    case malformedJSON
    case duplicateJSONKey
    case extraContent
    case outputNotObject
    case decisionTypeInvalid
    case unknownDecision
    case nonPostedExtraFields
    case missingAmount
    case missingDirection
    case missingAccount
    case postedFieldSetInvalid
    case amountInvalid
    case currencyInvalid
    case directionInvalid
    case accountInvalid
    case counterpartyInvalid
    case evidenceInvalid
    case evidenceOutOfBounds
    case evidenceMismatch
    case amountValueDisagreement
    case outputTruncated

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
