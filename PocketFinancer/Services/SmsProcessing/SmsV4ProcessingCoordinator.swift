import Foundation

/// One direct Foundation Models call per v4 operation; all successful postings remain review-only.
actor SmsV4ProcessingCoordinator {
    private let store: SmsProcessingStore
    private let extractor: any FoundationSmsExtracting
    private let analyzer = StructuralSmsAnalyzer()
    private let accountResolver: @MainActor @Sendable (String?) throws -> SmsAccountResolution

    init(
        store: SmsProcessingStore,
        extractor: any FoundationSmsExtracting,
        accountResolver: @escaping @MainActor @Sendable (String?) throws -> SmsAccountResolution
    ) {
        self.store = store
        self.extractor = extractor
        self.accountResolver = accountResolver
    }

    func process(
        source: AdmittedMessageRef,
        operation: SmsV4OperationSnapshot,
        observer: any SmsProcessingObserver = NoOpSmsProcessingObserver()
    ) async -> SmsProcessingOutcome {
        guard source.sourceID == operation.sourceID,
            operation.operationID.uuidString.lowercased() == operation.configuration.operationID,
            operation.parentOperationID?.uuidString.lowercased()
                == operation.configuration.parentOperationID,
            CanonicalJSON.sha256(source.sourceID.uuidString.lowercased())
                == operation.configuration.sourceRefHash,
            operation.configuration.contract == "pocketfinancer.processing-config/4",
            operation.configuration.contractRelease.releaseID == NativeSmsV4Assets.releaseID,
            operation.configuration.contractRelease.manifestSHA256
                == NativeSmsV4Assets.manifestSHA256,
            operation.configuration.extractor.modelIdentityKind == "system_managed_runtime",
            operation.configuration.extractor.modelFileSHA256 == nil,
            operation.configuration.persistencePolicy.rolloutMode == "review_only",
            SmsV4ProcessingJSON.configurationMatches(operation)
        else {
            return await retainWithoutClaim(
                operation.operationID,
                reasons: ["persistence_configuration_hash_mismatch"]
            )
        }
        do {
            if let settled = try await store.settledOutcome(operationID: operation.operationID) {
                return settled
            }
            var claim = try await store.claim(operationID: operation.operationID)
            let heartbeatTask = Task { [store, initialClaim = claim] in
                var renewableClaim = initialClaim
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled else { return }
                        renewableClaim = try await store.heartbeat(renewableClaim)
                    } catch { return }
                }
            }
            defer { heartbeatTask.cancel() }
            try await trace(&claim, "claim", "completed", [], observer)
            let evidence = try await store.sourceEvidence(sourceID: source.sourceID)
            guard evidence.admissionReceiptID == source.admissionReceiptID,
                CanonicalJSON.sha256(evidence.body) == source.sourceDigest
            else {
                return try await retain(
                    &claim, operation: operation,
                    reasons: ["persistence_configuration_hash_mismatch"], observer: observer
                )
            }
            let analysis = try analyzer.analyze(source: evidence.body, operation: operation)
            try await store.recordAnalysis(analysis, operationID: operation.operationID)
            try await store.transition(claim, expected: .claimed, to: .analyzed)
            try await trace(&claim, "analysis", "completed", analysis.reasonCodes, observer)
            // Advisory only: no deterministic triage result can bypass the extractor.
            try await store.transition(claim, expected: .analyzed, to: .triaged)
            try await trace(&claim, "triage", "completed", analysis.reasonCodes, observer)
            guard operation.configuration.extractor.eligible else {
                return try await retain(
                    &claim, operation: operation,
                    reasons: [
                        operation.configuration.extractor.ineligibilityReason
                            ?? "runtime_unavailable"
                    ], observer: observer
                )
            }
            let request = try SmsV4ProcessingJSON.request(
                source: evidence.body, sender: evidence.sender, analysis: analysis,
                configuration: operation.configuration
            )
            try await store.transition(claim, expected: .triaged, to: .selectorRunning)
            try await trace(&claim, "selector_execution", "running", [], observer)
            let startedAt = Date.now
            let response: DirectSelectorResponse
            do {
                // Exactly one invocation. Invalid output is never retried automatically.
                response = try await extractor.extract(requestJSON: request)
            } catch is CancellationError {
                let receipt = try await store.stop(operationID: operation.operationID)
                return .stopped(
                    operationID: operation.operationID,
                    reviewCaseID: receipt.reviewCaseID,
                    reason: "operation_interrupted"
                )
            } catch {
                try await store.recordSelectorFailure(
                    operationID: operation.operationID,
                    runtimeProfileJSON: Self.runtimeProfileJSON,
                    requestJSON: request,
                    safeErrorCode: "runtime_unavailable",
                    startedAt: startedAt
                )
                try await trace(
                    &claim, "selector_execution", "failed", ["runtime_unavailable"], observer
                )
                return try await retain(
                    &claim, operation: operation,
                    reasons: ["runtime_unavailable"], observer: observer
                )
            }
            try await store.recordSelectorResponse(
                operationID: operation.operationID, response: response, startedAt: startedAt
            )
            guard response.completion == "complete" else {
                try await store.markSelectorInvalid(
                    operationID: operation.operationID,
                    safeErrorCode: "runtime_output_truncated"
                )
                return try await retain(
                    &claim, operation: operation,
                    reasons: ["runtime_output_truncated"], observer: observer
                )
            }
            try await store.transition(claim, expected: .selectorRunning, to: .selectorRecorded)
            try await trace(&claim, "selector_execution", "completed", [], observer)
            let extraction: SmsExtractorResult
            do {
                extraction = try SmsExtractorValidator().validate(
                    rawOutput: response.rawOutput,
                    source: evidence.body,
                    primaryCurrency: operation.configuration.currencyContext.primaryCurrency,
                    enabledProfiles: operation.configuration.currencyContext.enabledProfileIDs
                )
            } catch let error as SmsExtractorValidationError {
                try await store.markSelectorInvalid(
                    operationID: operation.operationID, safeErrorCode: error.reasonCode
                )
                try await trace(
                    &claim, "selector_validation", "failed", [error.reasonCode], observer
                )
                return try await retain(
                    &claim, operation: operation,
                    reasons: [error.reasonCode], observer: observer
                )
            }
            try await store.transition(claim, expected: .selectorRecorded, to: .validated)
            try await trace(&claim, "selector_validation", "completed", [], observer)
            claim = try await store.heartbeat(claim)
            switch extraction.decision {
            case .none:
                return try await settleNone(
                    &claim, extraction: extraction, operation: operation, observer: observer
                )
            case .abstain:
                return try await settleAbstain(
                    &claim, extraction: extraction, operation: operation, observer: observer
                )
            case .posted:
                return try await settlePosted(
                    &claim, extraction: extraction, operation: operation, observer: observer
                )
            }
        } catch is CancellationError {
            if let receipt = try? await store.stop(operationID: operation.operationID) {
                return .stopped(
                    operationID: operation.operationID,
                    reviewCaseID: receipt.reviewCaseID,
                    reason: "operation_interrupted"
                )
            }
            return .retryableFailure(
                operationID: operation.operationID, reviewCaseID: nil,
                reason: "operation_interrupted"
            )
        } catch {
            return await retainWithoutClaim(
                operation.operationID, reasons: ["operation_interrupted"]
            )
        }
    }

    private static let runtimeProfileJSON =
        #"{"generation_mode":"DIRECT_NON_THINKING","decoding":"greedy","answer_token_limit":512,"raw_output_utf8_byte_limit":16384,"parser_deadline_ms":0}"#

    private func settleNone(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        operation: SmsV4OperationSnapshot,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let reasons = ["extractor_none"]
        let accountReason = "account_resolution_unresolved"
        let gate = SmsV4ProcessingJSON.gate(
            posted: false, accountReason: accountReason, duplicateStatus: "clear"
        )
        let account = SmsV4ProcessingJSON.account(.missing, reference: "")
        let duplicate = SmsV4ProcessingJSON.duplicate(
            status: "clear", operation: operation, fingerprint: nil
        )
        try await recordResult(
            &claim, extraction: extraction, status: "not_posted", operation: operation,
            account: account, duplicate: duplicate, gate: gate, reasons: reasons
        )
        try await store.recordV4GateDecision(
            claim, result: "not_posted", primaryReason: "persistence_not_posted",
            checksJSON: try SmsV4ProcessingJSON.checksJSON(
                posted: false, accountReason: accountReason, duplicateStatus: "clear"
            ),
            accountResolutionJSON: try SmsV4ProcessingJSON.canonical(account)
        )
        try await trace(&claim, "persistence_gate", "completed", reasons, observer)
        try await trace(&claim, "settlement", "completed", reasons, observer)
        try await store.settleDiscarded(claim, reason: reasons[0])
        return .terminallyDiscarded(operationID: operation.operationID, reason: reasons[0])
    }

    private func settleAbstain(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        operation: SmsV4OperationSnapshot,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let reasons = ["extractor_abstained"]
        try await recordResult(
            &claim, extraction: extraction, status: "review", operation: operation,
            account: nil, duplicate: nil, gate: nil, reasons: reasons
        )
        return try await retain(
            &claim, operation: operation, reasons: reasons, observer: observer
        )
    }

    private func settlePosted(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        operation: SmsV4OperationSnapshot,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        guard let transaction = extraction.transaction else {
            throw SmsProcessingStoreError.configurationMismatch
        }
        let resolution = try await accountResolver(transaction.accountReference)
        let accountReasons = SmsV4ProcessingJSON.accountReasons(resolution)
        try await trace(&claim, "account_resolution", "completed", accountReasons, observer)
        let accountID: UUID?
        if case .unique(let value) = resolution { accountID = value } else { accountID = nil }
        let fingerprint = CanonicalJSON.sha256(
            "\(transaction.minorUnits)\0\(transaction.currency)\0"
                + "\(transaction.direction.rawValue)\0\(accountID?.uuidString.lowercased() ?? "")\0"
                + "\(operation.configuration.receivedTimestamp.epochMs)"
        )
        let duplicateStatus = try await store.v4DuplicateStatus(
            operationID: operation.operationID,
            sourceID: operation.sourceID,
            stableEventID: operation.stableEventID,
            transactionFingerprint: fingerprint
        )
        var reasons = accountReasons
        switch duplicateStatus {
        case "already_persisted": reasons.append("duplicate_already_persisted")
        case "clear": break
        default: reasons.append("duplicate_possible")
        }
        reasons.append("persistence_blocked_by_rollout_mode")
        reasons = Array(Set(reasons)).sorted()
        let account = SmsV4ProcessingJSON.account(
            resolution, reference: transaction.accountReference
        )
        let duplicate = SmsV4ProcessingJSON.duplicate(
            status: duplicateStatus, operation: operation, fingerprint: fingerprint
        )
        let accountReason = accountReasons.first
        let gate = SmsV4ProcessingJSON.gate(
            posted: true, accountReason: accountReason,
            duplicateStatus: duplicateStatus
        )
        guard let gateResult = gate["result"] as? String,
            let gateReason = gate["primary_reason"] as? String
        else { throw SmsProcessingStoreError.configurationMismatch }
        try await recordResult(
            &claim, extraction: extraction,
            status: gateResult == "blocked_by_mode" ? "blocked" : "review",
            operation: operation,
            account: account, duplicate: duplicate, gate: gate, reasons: reasons
        )
        try await trace(&claim, "reconstruction", "completed", [], observer)
        try await store.recordV4GateDecision(
            claim, result: gateResult,
            primaryReason: gateReason,
            checksJSON: try SmsV4ProcessingJSON.checksJSON(
                posted: true, accountReason: accountReason,
                duplicateStatus: duplicateStatus
            ),
            accountResolutionJSON: try SmsV4ProcessingJSON.canonical(account)
        )
        try await trace(&claim, "persistence_gate", "completed", reasons, observer)
        return try await retain(
            &claim, operation: operation, reasons: reasons, observer: observer
        )
    }

    private func recordResult(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        status: String,
        operation: SmsV4OperationSnapshot,
        account: [String: Any]?,
        duplicate: [String: Any]?,
        gate: [String: Any]?,
        reasons: [String]
    ) async throws {
        let result = try SmsV4ProcessingJSON.result(
            status: status, extraction: extraction, operation: operation,
            account: account, duplicate: duplicate, gate: gate, reasons: reasons
        )
        try await store.recordV4NormalizedResult(
            operationID: operation.operationID,
            semanticResultJSON: result,
            decision: extraction.decision.rawValue
        )
        try await store.transition(claim, expected: .validated, to: .reconstructed)
    }

    private func trace(
        _ claim: inout SmsOperationClaim,
        _ stage: String,
        _ status: String,
        _ reasons: [String],
        _ observer: any SmsProcessingObserver
    ) async throws {
        let safeReasons = Array(Set(reasons)).sorted()
        let receipt = try await store.appendTrace(
            claim, stage: stage, status: status, reasonCodes: safeReasons
        )
        await observer.didReceive(
            SmsProcessingObserverEvent(
                operationID: claim.operationID, sequence: receipt.sequence,
                stage: stage, status: status, reasonCodes: safeReasons
            ))
    }

    private func retain(
        _ claim: inout SmsOperationClaim,
        operation: SmsV4OperationSnapshot,
        reasons: [String],
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let safeReasons =
            reasons.isEmpty
            ? ["persistence_triage_requires_review"] : Array(Set(reasons)).sorted()
        try await trace(&claim, "settlement", "retained", safeReasons, observer)
        let reviewID = try await store.retainForReview(claim, reasons: safeReasons)
        return .retainedForReview(
            operationID: operation.operationID,
            reviewCaseID: reviewID,
            reasons: safeReasons
        )
    }

    private func retainWithoutClaim(
        _ operationID: UUID,
        reasons: [String]
    ) async -> SmsProcessingOutcome {
        do {
            if let settled = try await store.settledOutcome(operationID: operationID) {
                return settled
            }
        } catch {
            // Best-effort lookup: continue to the durable review fallback below.
        }
        if let reviewID = try? await store.retainUnownedForReview(
            operationID: operationID, reasons: reasons
        ) {
            return .retainedForReview(
                operationID: operationID, reviewCaseID: reviewID, reasons: reasons
            )
        }
        return .retryableFailure(
            operationID: operationID,
            reviewCaseID: nil,
            reason: reasons.first ?? "operation_interrupted"
        )
    }
}
