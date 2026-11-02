import Foundation

enum SmsStorageDisposition: String, Sendable {
    case invoke
    case discard
    case retainReview = "retain_review"
}

enum SmsSelectorAction: String, Sendable {
    case runNormal = "run_normal"
    case runAssistive = "run_assistive"
    case skip
}

struct SmsTriageDecision: Sendable {
    let disposition: SmsStorageDisposition
    let selectorAction: SmsSelectorAction
    let reasonCodes: [String]
}

struct SmsTriageEvaluator: Sendable {
    nonisolated func evaluate(_ analysis: SmsAnalysis) -> SmsTriageDecision {
        var reasons = Set(analysis.reasonCodes)
        let directions = analysis.candidates.filter { $0.kind == .direction }
        let amounts = analysis.candidates.filter { $0.kind == .amount }
        let completedClauses = Set(directions.compactMap(\.clauseID))
        let completeClauses = completedClauses.intersection(amounts.compactMap(\.clauseID))
        func result(
            _ disposition: SmsStorageDisposition,
            _ action: SmsSelectorAction,
            _ reason: String
        ) -> SmsTriageDecision {
            reasons.insert(reason)
            return SmsTriageDecision(
                disposition: disposition, selectorAction: action, reasonCodes: reasons.sorted()
            )
        }
        if reasons.contains("invalid_input") {
            return result(.discard, .skip, "discard_invalid_input")
        }
        if completedClauses.isEmpty {
            if !reasons.intersection([
                "pending_event", "expected_refund_not_posted", "authorization_or_hold_not_posted",
            ]).isEmpty {
                return result(.retainReview, .skip, "review_uncertain_financial_state")
            }
            if reasons.contains("credential_otp") {
                return result(.discard, .skip, "discard_standalone_credential_otp")
            }
            if reasons.contains("request_or_authorization") {
                return result(.discard, .skip, "discard_unapproved_request")
            }
            if reasons.contains("non_posted_failure") {
                return result(.discard, .skip, "discard_explicit_non_posted_movement")
            }
            if !reasons.isEmpty && reasons.isSubset(of: ["balance_information"]) {
                return result(.discard, .skip, "discard_unambiguous_standalone_non_event")
            }
            return result(.retainReview, .skip, "review_no_completed_event_candidate")
        }
        if directions.count > 1 {
            return result(
                .retainReview, completeClauses.isEmpty ? .skip : .runAssistive,
                "review_multiple_completed_event_candidates"
            )
        }
        if completeClauses.isEmpty {
            return result(.retainReview, .skip, "review_missing_core_candidate")
        }
        let conflicts = Set([
            "conflicting_currencies", "ambiguous_currency_marker", "unsupported_currency_code",
            "pending_event", "request_or_authorization", "non_posted_failure",
        ])
        if !reasons.intersection(conflicts).isEmpty {
            return result(.retainReview, .runAssistive, "review_conflicting_or_ambiguous_context")
        }
        return result(.invoke, .runNormal, "invoke_grounded_single_event")
    }
}
