import Foundation

struct AutomaticPersistenceGate: Sendable {
    nonisolated func evaluate(
        analysis: SmsAnalysis,
        triage: SmsTriageDecision,
        selection: GroundedSelectorResult,
        transaction: ReconstructedSmsTransaction?,
        accountResolution: SmsAccountResolution,
        operation: SmsOperationSnapshot,
        claimOwnershipCurrent: Bool
    ) -> PersistenceGateDecision {
        let contractValid = analysis.contract == "pocketfinancer.sms-analysis/2"
        let configurationHashValid = analysis.configurationHash == operation.configurationHash
        let selectorModeValid =
            operation.configuration.generationMode == "DIRECT_NON_THINKING"
            && operation.configuration.decoding == "greedy"
        let posted = selection.decision == .posted && transaction != nil
        let completedEventCandidates = analysis.candidates.filter { $0.kind == .direction }
        let completedEventClauseCount = Set(completedEventCandidates.compactMap(\.clauseID)).count
        let exactlyOneEvent =
            analysis.completedEventCount == 1
            && completedEventCandidates.count == 1
            && completedEventClauseCount == 1
        let normalSelection = triage.selectorAction == .runNormal
        let triageInvokes = triage.disposition == .invoke
        let noNonPostedConflict = !analysis.cues.contains {
            Self.nonPostedConflictCues.contains($0.kind)
        }
        let exactMoney =
            transaction.map {
                $0.minorUnits > 0
                    && CurrencyProfileRegistry.scales[$0.currency] == $0.currencyScale
            } == true
        let currencyProvenanceApproved =
            transaction.map {
                Self.approvedCurrencyProvenance.contains($0.currencyProvenance)
            } == true
        let selectedClauseID = selection.posted.flatMap { selected in
            analysis.candidates.first {
                $0.id == selected.directionCandidateID && $0.kind == .direction
            }?.clauseID
        }
        let supportedFamily = analysis.clauseAnnotations
            .filter { $0.clauseID == selectedClauseID }
            .flatMap(\.financialFamilies)
            .map(\.family)
            .contains { Self.automaticFamilies.contains($0) }
        let accountPresent =
            transaction.map {
                $0.accountEvidence != nil && $0.accountIdentifier != nil
            } == true
        let accountUnique = if case .unique = accountResolution { true } else { false }
        let timestampAccepted =
            transaction.map {
                $0.occurredAtEpochMilliseconds != nil
                    && Self.approvedTimestampProvenance.contains($0.timestampProvenance)
            } == true
        let modeEnabled = operation.configuration.rolloutMode == "automatic"

        let checks = [
            check("analysis_contract_known", contractValid, "persistence_unknown_analysis_contract"),
            check(
                "configuration_hash_valid", configurationHashValid,
                "persistence_configuration_hash_mismatch"),
            check(
                "claim_ownership_current", claimOwnershipCurrent,
                "persistence_claim_ownership_invalid"),
            check(
                "selector_mode_valid", selectorModeValid,
                "persistence_selector_mode_invalid"),
            check("selector_posted", posted, "persistence_not_posted"),
            check(
                "single_completed_event", exactlyOneEvent,
                "persistence_not_exactly_one_event"),
            check("exact_money", exactMoney, "persistence_invalid_money"),
            check(
                "currency_provenance_approved", currencyProvenanceApproved,
                "persistence_currency_provenance_not_approved"),
            check(
                "timestamp_accepted", timestampAccepted,
                "persistence_timestamp_provenance_invalid"),
            check(
                "account_present", accountPresent,
                "persistence_account_not_present"),
            check(
                "account_uniquely_resolved", accountUnique,
                "persistence_account_not_uniquely_resolved"),
            check(
                "supported_family", supportedFamily,
                "persistence_financial_family_not_supported"),
            check(
                "triage_disposition", triageInvokes,
                "persistence_triage_requires_review"),
            check(
                "normal_selection", normalSelection,
                "persistence_assistive_selection_not_eligible"),
            check(
                "non_posted_conflict", noNonPostedConflict,
                "persistence_conflicting_non_posted_evidence"),
            check(
                "automatic_rollout_enabled", modeEnabled,
                "persistence_blocked_by_rollout_mode"),
        ]

        let failed = checks.filter { !$0.passed }
        let primaryReason = failed.first?.reasonCode ?? "persistence_all_gates_passed"
        let integrityChecks = Set([
            "analysis_contract_known",
            "configuration_hash_valid",
            "claim_ownership_current",
        ])
        let result: PersistenceGateResult
        if failed.contains(where: { integrityChecks.contains($0.check) }) {
            result = .invalidOperation
        } else if selection.decision == .none {
            result = .notPosted
        } else if analysis.completedEventCount > 1 || completedEventCandidates.count > 1
            || completedEventClauseCount > 1
        {
            result = .multipleEvents
        } else if failed.contains(where: { $0.check != "automatic_rollout_enabled" }) {
            result = .reviewRequired
        } else if !failed.isEmpty {
            result = .blockedByMode
        } else {
            result = .eligible
        }
        return decision(result, primaryReason, checks)
    }

    private nonisolated func check(
        _ name: String, _ passed: Bool, _ failureReason: String
    ) -> PersistenceGateCheck {
        PersistenceGateCheck(
            check: name, passed: passed, reasonCode: passed ? nil : failureReason)
    }

    private nonisolated func decision(
        _ result: PersistenceGateResult,
        _ reason: String,
        _ checks: [PersistenceGateCheck]
    ) -> PersistenceGateDecision {
        PersistenceGateDecision(result: result, primaryReason: reason, checks: checks)
    }

    private nonisolated static let approvedCurrencyProvenance = Set([
        "explicit_code",
        "explicit_unambiguous_symbol_or_marker",
        "user_primary_default",
    ])
    private nonisolated static let approvedTimestampProvenance = Set([
        "source_supplied_transaction_time",
        "acquisition_supplied_message_time",
    ])
    private nonisolated static let automaticFamilies = Set([
        "bank_transfer",
        "bill_payment",
        "card_purchase",
        "cash_deposit",
        "cash_withdrawal",
        "fee_charge",
        "interest",
        "merchant_payment",
        "refund",
        "salary_income",
        "upi_transfer",
    ])
    private nonisolated static let nonPostedConflictCues = Set([
        "failure",
        "negation",
        "pending",
        "request",
        "expectation",
        "authorization_hold",
    ])
}
