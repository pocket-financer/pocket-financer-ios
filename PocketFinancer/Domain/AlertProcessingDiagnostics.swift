import Foundation

struct ProcessingCodePresentation: Equatable, Sendable {
    let title: String
    let detail: String
}

enum AlertProcessingDiagnostics {
    static func statusTitle(_ status: AlertStatus) -> String {
        switch status {
        case .pending:
            "Saved for retry"
        case .processing:
            "Processing locally"
        case .imported:
            "Imported"
        case .needsReview:
            "Needs review"
        case .rejected:
            "Rejected deterministically"
        case .duplicate:
            "Duplicate"
        }
    }

    static func originTitle(_ origin: AlertOrigin) -> String {
        switch origin {
        case .shortcut:
            "Shortcut automation"
        case .manual:
            "Manual import"
        }
    }

    static func attemptDuration(
        lastAttemptAt: Date?,
        updatedAt: Date,
        status: AlertStatus
    ) -> TimeInterval? {
        guard status != .processing, let lastAttemptAt else { return nil }
        return max(0, updatedAt.timeIntervalSince(lastAttemptAt))
    }

    static func durationText(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "Under 1 second"
        }
        if duration < 60 {
            return String(format: "%.1f seconds", duration)
        }

        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }

    static func presentation(for code: String) -> ProcessingCodePresentation {
        switch code {
        case "model_appleIntelligenceNotEnabled":
            .init(
                title: "Apple Intelligence is disabled",
                detail: "The alert remains saved locally and can be retried after Apple Intelligence is enabled."
            )
        case "model_modelNotReady":
            .init(
                title: "Model is not ready",
                detail:
                    "Apple reports only modelNotReady, without download progress or a more specific public cause. The alert remains retryable."
            )
        case "model_assets_unavailable":
            .init(
                title: "Model assets unavailable",
                detail: "Apple's local assets were unavailable for this attempt; the alert remains retryable."
            )
        case "model_deviceNotEligible":
            .init(
                title: "Device is not eligible",
                detail: "This device cannot run the system language model, so the retained alert needs manual review."
            )
        case "model_unknown":
            .init(
                title: "Model unavailable",
                detail: "Apple reported an unrecognized availability state; the alert remains retryable."
            )
        case "model_timed_out":
            .init(
                title: "Attempt timed out",
                detail:
                    "Pocket Financer requested cancellation after 60 seconds. Apple's model may take additional time to release the local request."
            )
        case "model_cancelled":
            .init(
                title: "Attempt interrupted",
                detail: "Local processing was cancelled before a structured result was accepted."
            )
        case "model_rate_limited":
            .init(
                title: "Model temporarily busy",
                detail: "Apple rate-limited this local request; the alert remains retryable."
            )
        case "model_concurrent_requests":
            .init(
                title: "Another model request was active",
                detail: "The system rejected overlapping work; Pocket Financer serializes future requests."
            )
        case "model_unsupported_language":
            .init(
                title: "Language or locale unsupported",
                detail:
                    "Apple's model rejected Pocket Financer's checked U.S. English model locale or detected an unsupported request language. The phone's India region is separate and can remain unchanged."
            )
        case "model_guardrail_violation":
            .init(
                title: "Apple guardrail stopped generation",
                detail: "The system safety layer blocked this extraction. Pocket Financer did not accept a transaction."
            )
        case "model_refused":
            .init(
                title: "Model declined the request",
                detail: "Apple's model refused to produce the requested structured extraction."
            )
        case "model_unsupported_guide":
            .init(
                title: "Extraction schema unsupported",
                detail: "The installed model could not use part of Pocket Financer's guided output schema."
            )
        case "model_decoding_failed":
            .init(
                title: "Structured output could not be decoded",
                detail: "A response arrived, but it did not decode into the required transaction structure."
            )
        case "model_context_window_exceeded":
            .init(
                title: "Model context limit exceeded",
                detail: "The request exceeded the system model's available context window."
            )
        case "model_generation_failed":
            .init(
                title: "No structured extraction produced",
                detail: "The local model did not return a transaction structure that Pocket Financer could inspect."
            )
        case "modelRejected", "extractor_abstained":
            .init(
                title: "Extractor abstained",
                detail:
                    "The model abstained rather than guessing, so the original evidence "
                    + "remains available for review."
            )
        case "explicitlyUnsuccessfulTransaction":
            .init(
                title: "Transaction was explicitly unsuccessful",
                detail:
                    "Failed, declined, unsuccessful, or negated wording prevented "
                    + "the model output from creating a transaction."
            )
        case "invalidDirection", "extractor_direction_invalid":
            .init(
                title: "Direction was invalid or ungrounded",
                detail:
                    "The debit or credit direction was invalid or not grounded in wording "
                    + "from the alert body."
            )
        case "directionNotGrounded":
            .init(
                title: "Direction was not grounded",
                detail: "The debit or credit direction was not supported by wording in the alert body."
            )
        case "amountNotGrounded":
            .init(
                title: "Amount was not grounded",
                detail: "The extracted amount was not copied exactly from the alert body."
            )
        case "amountCandidateMismatch", "extractor_amount_value_disagreement":
            .init(
                title: "Extracted amount disagreed with evidence",
                detail:
                    "The declared amount value did not match deterministic parsing of its "
                    + "selected evidence span."
            )
        case "ambiguousTransactionAmount":
            .init(
                title: "Transaction amount was ambiguous",
                detail:
                    "The alert contained zero or multiple plausible transaction amounts, "
                    + "so no amount was accepted automatically."
            )
        case "invalidAmount", "extractor_amount_invalid", "extractor_currency_invalid":
            .init(
                title: "Amount or currency was invalid",
                detail: "The grounded amount or currency could not be validated safely against the alert body."
            )
        case "merchantNotGrounded", "extractor_counterparty_invalid":
            .init(
                title: "Counterparty was invalid or ungrounded",
                detail:
                    "The extracted merchant or counterparty did not match its source evidence "
                    + "in the alert body."
            )
        case "accountNotGrounded", "extractor_account_reference_invalid":
            .init(
                title: "Account reference was invalid or ungrounded",
                detail:
                    "The extracted account or card label did not normalize cleanly from its "
                    + "evidence span in the alert."
            )
        case "invalidAccountEvidence":
            .init(
                title: "Account evidence was too vague",
                detail:
                    "The extracted account or card text did not include at least three visible "
                    + "suffix digits, so it could not identify a usable local account."
            )
        case "dateNotGrounded":
            .init(
                title: "Date was not grounded",
                detail: "The extracted date text was not copied exactly from the alert body."
            )
        case "invalidDate":
            .init(
                title: "Date was invalid",
                detail: "The grounded date text could not be parsed safely."
            )
        case "extractor_evidence_invalid", "extractor_evidence_out_of_bounds", "extractor_evidence_mismatch":
            .init(
                title: "Source evidence mismatch",
                detail: "An extracted span did not match exact Unicode-scalar substrings in the source message."
            )
        case "extractor_none", "tombstoned_none":
            .init(
                title: "No completed transaction",
                detail:
                    "The extractor classified this alert as non-transactional and erased "
                    + "sensitive text into a tombstone."
            )
        case "tombstoned_excluded":
            .init(
                title: "Excluded before model invocation",
                detail:
                    "The deterministic prefilter excluded this alert as non-transactional "
                    + "and erased sensitive text."
            )
        case "prefilter_empty", "prefilter_no_digits", "prefilter_gaming_promo",
            "prefilter_collect_or_mandate_request", "prefilter_otp_verification",
            "prefilter_telecom_notice", "prefilter_brokerage_eod_report", "prefilter_no_financial_cue":
            .init(
                title: "Excluded by local prefilter",
                detail:
                    "The deterministic prefilter identified non-transactional content "
                    + "and erased sensitive body text."
            )
        case "account_resolution_unresolved":
            .init(
                title: "Account not yet linked",
                detail:
                    "Confirm or create the local account in Review; future alerts for this "
                    + "suffix or VPA can auto-save."
            )
        case "account_resolution_ambiguous":
            .init(
                title: "Multiple accounts matched",
                detail: "More than one local account matched this reference, so manual confirmation is required."
            )
        case "duplicate_possible", "duplicate_already_persisted":
            .init(
                title: "Possible duplicate detected",
                detail:
                    "A matching transaction was already persisted within the 5-minute "
                    + "duplicate window or for this alert."
            )
        case "persistence_all_gates_passed":
            .init(
                title: "Saved automatically",
                detail: "All grounding, account-resolution, and duplicate checks passed for automatic local save."
            )
        case "configuration_integrity":
            .init(
                title: "Asset integrity verification failed",
                detail: "Bundled SMS pipeline contracts did not match their manifest digests, so processing stopped."
            )
        case "runtime_unavailable", "runtime_ineligible":
            .init(
                title: "Local model runtime unavailable",
                detail: "On-device Apple Foundation Models were not available; the alert remains retained locally."
            )
        case "runtime_output_truncated":
            .init(
                title: "Model output truncated",
                detail: "The local model response did not finish cleanly within output limits and was rejected."
            )
        case "operation_interrupted", "user_cancelled", "process_interrupted":
            .init(
                title: "Processing interrupted",
                detail: "Processing was interrupted before settlement; evidence remains retained for retry."
            )
        case "missing_amount":
            .init(title: "No currency amount", detail: "The body did not contain an amount marked with Rs, INR, or ₹.")
        case "missing_account":
            .init(
                title: "No account reference",
                detail: "The body did not contain a supported masked account or card reference.")
        case "missing_transaction_verb":
            .init(
                title: "No completed transaction wording",
                detail: "The body did not contain a supported completed-transaction verb.")
        case "one_time_password":
            .init(
                title: "OTP or verification alert",
                detail: "The deterministic filter found one-time password or verification-code wording.")
        case "collect_request":
            .init(
                title: "Payment request",
                detail: "The deterministic filter found collect-request or mandate-request wording.")
        case "promotion":
            .init(
                title: "Promotional message",
                detail: "The deterministic filter found high-confidence offer or solicitation wording.")
        case "unsuccessful_transaction":
            .init(
                title: "Unsuccessful transaction",
                detail:
                    "The deterministic filter found failed, declined, unsuccessful, or explicitly negated transaction wording."
            )
        case "empty_body":
            .init(title: "Empty alert", detail: "No alert body was available to inspect.")
        case "persistence_failed":
            .init(
                title: "Local save failed",
                detail: "Pocket Financer could not finish a local database update for this attempt.")
        case "automatic_retry_limit_reached":
            .init(
                title: "Automatic retry limit reached",
                detail:
                    "Automatic processing stopped after three attempts. The retained alert can still be retried explicitly."
            )
        case "parser_failed":
            .init(title: "Parser failed", detail: "The parser stopped with an unclassified, privacy-safe failure.")
        case "validation_passed":
            .init(
                title: "Evidence validation passed",
                detail:
                    "The mapped parser draft was grounded against the retained alert before ledger fields were saved.")
        default:
            .init(
                title: "Recorded processing code",
                detail: "Pocket Financer retained this privacy-safe code for inspection.")
        }
    }
}
