import Foundation

/// Runs prefilter -> structural advice -> flat guided SLM -> validation -> duplicate gate -> persistence.
actor SmsProcessingCoordinator {
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
        operation: SmsOperationSnapshot,
        observer: any SmsProcessingObserver = NoOpSmsProcessingObserver(),
        initialClaim: SmsOperationClaim? = nil
    ) async -> SmsProcessingOutcome {
        guard let binding = try? SmsContractAssets.verify(),
            source.sourceID == operation.sourceID,
            operation.operationID.uuidString.lowercased() == operation.configuration.operationID,
            operation.parentOperationID?.uuidString.lowercased() == operation.configuration.parentOperationID,
            CanonicalJSON.sha256(source.sourceID.uuidString.lowercased()) == operation.configuration.sourceRefHash,
            operation.configuration.contract == SmsContractAssets.releaseID,
            operation.configuration.contractRelease.releaseID == SmsContractAssets.releaseID,
            operation.configuration.contractRelease.manifestSHA256 == binding.manifestSHA256,
            operation.configuration.extractor.modelIdentityKind == "system_managed_runtime",
            operation.configuration.extractor.modelFileSHA256 == nil,
            operation.configuration.extractor.wireTransport == "apple_fm_guided_flat",
            !operation.configuration.extractor.grammarEnabled,
            operation.configuration.extractor.grammarSHA256 == nil,
            operation.configuration.persistencePolicy.rolloutMode == "automatic",
            SmsProcessingJSON.configurationMatches(operation)
        else {
            return await retainWithoutClaim(
                operation.operationID,
                reasons: ["persistence_configuration_hash_mismatch"]
            )
        }
        var activeClaim: SmsOperationClaim?
        var latestAnalysis: SmsAnalysis?
        var latestSourceBody: String?
        var furthestStage = "configuration"
        do {
            if let settled = try await store.settledOutcome(operationID: operation.operationID) {
                return settled
            }
            var claim: SmsOperationClaim
            if let initialClaim {
                guard initialClaim.operationID == operation.operationID else {
                    throw SmsProcessingStoreError.lostOwnership
                }
                claim = try await store.heartbeat(initialClaim)
            } else {
                claim = try await store.claim(operationID: operation.operationID)
            }
            activeClaim = claim
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
            latestSourceBody = evidence.body
            guard evidence.admissionReceiptID == source.admissionReceiptID,
                CanonicalJSON.sha256(evidence.body) == source.sourceDigest
            else {
                let outcome = try await retain(
                    &claim,
                    operation: operation,
                    reasons: ["persistence_configuration_hash_mismatch"],
                    furthestStage: "configuration",
                    slmFields: [],
                    analysis: nil,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            }
            let prefilter = SmsPrefilter.evaluate(evidence.body)
            if prefilter.decision == .exclude {
                let outcome = try await settlePrefilterExcluded(
                    &claim,
                    prefilterReason: prefilter.reason,
                    operation: operation,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            }
            try await trace(&claim, "prefilter", "completed", ["prefilter_eligible"], observer)
            let analysis = try analyzer.analyze(source: evidence.body, operation: operation)
            latestAnalysis = analysis
            furthestStage = "analysis_advisory"
            try await store.recordAnalysis(claim, analysis: analysis)
            try await store.transition(claim, expected: .claimed, to: .analyzed)
            try await trace(&claim, "analysis", "completed", analysis.reasonCodes, observer)
            // Advisory only: no deterministic triage result can bypass the extractor.
            try await store.transition(claim, expected: .analyzed, to: .triaged)
            try await trace(&claim, "triage", "completed", analysis.reasonCodes, observer)
            guard operation.configuration.extractor.eligible else {
                let outcome = try await retain(
                    &claim,
                    operation: operation,
                    reasons: [
                        operation.configuration.extractor.ineligibilityReason
                            ?? "runtime_unavailable"
                    ],
                    furthestStage: "analysis_advisory",
                    slmFields: [],
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            }
            let request = try SmsProcessingJSON.request(
                source: evidence.body,
                sender: evidence.sender,
                analysis: analysis,
                configuration: operation.configuration
            )
            furthestStage = "extractor_execution"
            try await store.transition(claim, expected: .triaged, to: .selectorRunning)
            try await trace(&claim, "selector_execution", "running", [], observer)
            let startedAt = Date.now
            let response: DirectSelectorResponse
            do {
                // Exactly one invocation. Invalid output is never retried automatically.
                response = try await extractor.extract(requestJSON: request)
            } catch TransactionParserError.cancelled {
                activeClaim = nil
                let receipt = try await store.stop(operationID: operation.operationID)
                return .stopped(
                    operationID: operation.operationID,
                    reviewCaseID: receipt.reviewCaseID,
                    reason: "operation_interrupted"
                )
            } catch is CancellationError {
                activeClaim = nil
                let receipt = try await store.stop(operationID: operation.operationID)
                return .stopped(
                    operationID: operation.operationID,
                    reviewCaseID: receipt.reviewCaseID,
                    reason: "operation_interrupted"
                )
            } catch let error as TransactionParserError {
                let outcome = try await failExtractor(
                    &claim,
                    code: error.safeCode,
                    request: request,
                    startedAt: startedAt,
                    operation: operation,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            } catch is SmsContractAssetError {
                let outcome = try await failExtractor(
                    &claim,
                    code: SmsContractAssetError.reasonCode,
                    request: request,
                    startedAt: startedAt,
                    operation: operation,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            } catch let error as SmsExtractorValidationError {
                let outcome = try await failExtractor(
                    &claim,
                    code: error.reasonCode,
                    request: request,
                    startedAt: startedAt,
                    operation: operation,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            } catch {
                let outcome = try await failExtractor(
                    &claim,
                    code: "runtime_unavailable",
                    request: request,
                    startedAt: startedAt,
                    operation: operation,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            }
            try await store.recordSelectorResponse(
                claim,
                response: response,
                startedAt: startedAt
            )
            let validator = SmsExtractorValidator()
            guard response.completion == "complete" else {
                try await store.markSelectorInvalid(
                    claim,
                    safeErrorCode: "runtime_output_truncated"
                )
                let partialFields = validator.collectGroundedFields(
                    rawOutput: response.rawOutput,
                    source: evidence.body,
                    primaryCurrency: operation.configuration.currencyContext.primaryCurrency,
                    enabledProfiles: operation.configuration.currencyContext.enabledProfileIDs
                )
                let outcome = try await retain(
                    &claim,
                    operation: operation,
                    reasons: ["runtime_output_truncated"],
                    furthestStage: "extractor_execution",
                    slmFields: partialFields,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            }
            furthestStage = "extractor_validation"
            try await store.transition(claim, expected: .selectorRunning, to: .selectorRecorded)
            try await trace(&claim, "selector_execution", "completed", [], observer)
            let extraction: SmsExtractorResult
            do {
                extraction = try validator.validate(
                    rawOutput: response.rawOutput,
                    source: evidence.body,
                    primaryCurrency: operation.configuration.currencyContext.primaryCurrency,
                    enabledProfiles: operation.configuration.currencyContext.enabledProfileIDs
                )
            } catch let error as SmsExtractorValidationError {
                try await store.markSelectorInvalid(
                    claim,
                    safeErrorCode: error.reasonCode
                )
                try await trace(&claim, "selector_validation", "failed", [error.reasonCode], observer)
                let partialFields = validator.collectGroundedFields(
                    rawOutput: response.rawOutput,
                    source: evidence.body,
                    primaryCurrency: operation.configuration.currencyContext.primaryCurrency,
                    enabledProfiles: operation.configuration.currencyContext.enabledProfileIDs
                )
                let outcome = try await retain(
                    &claim,
                    operation: operation,
                    reasons: [error.reasonCode],
                    furthestStage: "extractor_validation",
                    slmFields: partialFields,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            }
            try await store.transition(claim, expected: .selectorRecorded, to: .validated)
            try await trace(&claim, "selector_validation", "completed", [], observer)
            claim = try await store.heartbeat(claim)
            activeClaim = claim
            switch extraction.decision {
            case .none:
                let outcome = try await settleNone(
                    &claim,
                    extraction: extraction,
                    operation: operation,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            case .abstain:
                let outcome = try await settleAbstain(
                    &claim,
                    extraction: extraction,
                    operation: operation,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
            case .posted:
                furthestStage = "account_resolution"
                let outcome = try await settlePosted(
                    &claim,
                    extraction: extraction,
                    operation: operation,
                    analysis: analysis,
                    source: evidence.body,
                    observer: observer
                )
                activeClaim = nil
                return outcome
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
                operationID: operation.operationID,
                reviewCaseID: nil,
                reason: "operation_interrupted"
            )
        } catch {
            return await retainAfterFailure(
                activeClaim: activeClaim,
                operation: operation,
                furthestStage: furthestStage,
                analysis: latestAnalysis,
                source: latestSourceBody,
                reasons: ["operation_interrupted"]
            )
        }
    }

    private func failExtractor(
        _ claim: inout SmsOperationClaim,
        code: String,
        request: String,
        startedAt: Date,
        operation: SmsOperationSnapshot,
        analysis: SmsAnalysis,
        source: String,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        try await store.recordSelectorFailure(
            claim,
            runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
            requestJSON: request,
            safeErrorCode: code,
            startedAt: startedAt
        )
        try await trace(&claim, "selector_execution", "failed", [code], observer)
        return try await retain(
            &claim,
            operation: operation,
            reasons: [code],
            furthestStage: "extractor_execution",
            slmFields: [],
            analysis: analysis,
            source: source,
            observer: observer
        )
    }

    private func settlePrefilterExcluded(
        _ claim: inout SmsOperationClaim,
        prefilterReason: SmsPrefilter.Reason,
        operation: SmsOperationSnapshot,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let primaryReason = "prefilter_\(prefilterReason.rawValue)"
        let reasons = [primaryReason, "tombstoned_excluded"]
        try await trace(&claim, "prefilter", "completed", reasons, observer)
        let result = try SmsProcessingJSON.result(
            status: "tombstoned_excluded",
            extraction: nil,
            operation: operation,
            account: nil,
            duplicate: nil,
            gate: nil,
            reasons: reasons
        )
        try await store.recordNormalizedResult(
            claim,
            semanticResultJSON: result,
            decision: nil
        )
        try await trace(&claim, "settlement", "completed", reasons, observer)
        try await store.settleDiscarded(
            claim,
            retentionState: "tombstoned_excluded",
            reason: primaryReason
        )
        return .terminallyDiscarded(operationID: operation.operationID, reason: primaryReason)
    }

    private func settleNone(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        operation: SmsOperationSnapshot,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let reasons = ["extractor_none", "tombstoned_none"]
        let accountReason = "account_resolution_unresolved"
        let rolloutMode = operation.configuration.persistencePolicy.rolloutMode
        let gate = SmsProcessingJSON.gate(
            posted: false,
            accountReason: accountReason,
            duplicateStatus: "clear",
            rolloutMode: rolloutMode
        )
        let account = SmsProcessingJSON.account(.missing, reference: "")
        let duplicate = SmsProcessingJSON.duplicate(
            status: "clear",
            operation: operation,
            fingerprint: nil
        )
        try await recordResult(
            &claim,
            extraction: extraction,
            status: "tombstoned_none",
            operation: operation,
            account: account,
            duplicate: duplicate,
            gate: gate,
            reasons: reasons,
            retainedEvidence: nil
        )
        try await trace(&claim, "reconstruction", "completed", [], observer)
        try await store.recordGateDecision(
            claim,
            result: "not_posted",
            primaryReason: "persistence_not_posted",
            checksJSON: try SmsProcessingJSON.checksJSON(
                posted: false,
                accountReason: accountReason,
                duplicateStatus: "clear",
                rolloutMode: rolloutMode
            ),
            accountResolutionJSON: try SmsProcessingJSON.canonical(account),
            rolloutMode: rolloutMode
        )
        try await trace(&claim, "persistence_gate", "completed", reasons, observer)
        try await trace(&claim, "settlement", "completed", reasons, observer)
        try await store.settleDiscarded(
            claim,
            retentionState: "tombstoned_none",
            reason: "extractor_none"
        )
        return .terminallyDiscarded(operationID: operation.operationID, reason: "extractor_none")
    }

    private func settleAbstain(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        operation: SmsOperationSnapshot,
        analysis: SmsAnalysis,
        source: String,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let reasons = ["extractor_abstained"]
        let retainedEvidence = SmsReviewProjection.retainedEvidenceJSONObject(
            furthestStage: "extractor_validation",
            slmFields: [],
            analysis: analysis,
            source: source
        )
        try await recordResult(
            &claim,
            extraction: extraction,
            status: "review",
            operation: operation,
            account: nil,
            duplicate: nil,
            gate: nil,
            reasons: reasons,
            retainedEvidence: retainedEvidence
        )
        try await trace(&claim, "reconstruction", "completed", [], observer)
        return try await retain(
            &claim,
            operation: operation,
            reasons: reasons,
            furthestStage: "extractor_validation",
            slmFields: [],
            analysis: analysis,
            source: source,
            recordRetainedResult: false,
            observer: observer
        )
    }

    private func settlePosted(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        operation: SmsOperationSnapshot,
        analysis: SmsAnalysis,
        source: String,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        guard let transaction = extraction.transaction else {
            throw SmsProcessingStoreError.configurationMismatch
        }
        let resolution = try await accountResolver(transaction.accountReference)
        let accountReasons = SmsProcessingJSON.accountReasons(resolution)
        try await trace(&claim, "account_resolution", "completed", accountReasons, observer)
        let accountID: UUID? =
            if case .unique(let value) = resolution {
                value
            } else {
                nil
            }
        let fingerprint = CanonicalJSON.sha256(
            "\(transaction.minorUnits)\0\(transaction.currency)\0"
                + "\(transaction.direction.rawValue)\0\(accountID?.uuidString.lowercased() ?? "")\0"
                + "\(operation.configuration.receivedTimestamp.epochMs)"
        )
        let occurredAt = Date(
            timeIntervalSince1970: TimeInterval(operation.configuration.receivedTimestamp.epochMs) / 1_000
        )
        let duplicateStatus = try await store.duplicateStatus(
            operationID: operation.operationID,
            sourceID: operation.sourceID,
            stableEventID: operation.stableEventID,
            accountID: accountID,
            direction: transaction.direction.rawValue,
            minorUnits: transaction.minorUnits,
            currency: transaction.currency,
            occurredAt: occurredAt,
            windowSeconds: SmsContractAssets.duplicateWindowSeconds
        )
        var reasons = accountReasons
        switch duplicateStatus {
        case "already_persisted": reasons.append("duplicate_already_persisted")
        case "clear": break
        default: reasons.append("duplicate_possible")
        }
        let rolloutMode = operation.configuration.persistencePolicy.rolloutMode
        let account = SmsProcessingJSON.account(
            resolution,
            reference: transaction.accountReference
        )
        let duplicate = SmsProcessingJSON.duplicate(
            status: duplicateStatus,
            operation: operation,
            fingerprint: fingerprint
        )
        let accountReason = accountReasons.first
        let gate = SmsProcessingJSON.gate(
            posted: true,
            accountReason: accountReason,
            duplicateStatus: duplicateStatus,
            rolloutMode: rolloutMode
        )
        guard let gateResult = gate["result"] as? String,
            let gateReason = gate["primary_reason"] as? String
        else { throw SmsProcessingStoreError.configurationMismatch }
        let isEligible = gateResult == "eligible" && accountID != nil
        if reasons.isEmpty {
            reasons =
                isEligible
                ? ["persistence_all_gates_passed"]
                : [gateReason]
        } else {
            reasons = Array(Set(reasons)).sorted()
        }
        let partialFields = SmsReviewProjection.partialFields(from: transaction)
        let retainedEvidence = SmsReviewProjection.retainedEvidenceJSONObject(
            furthestStage: "persistence_gate",
            slmFields: partialFields,
            analysis: analysis,
            source: source
        )
        try await recordResult(
            &claim,
            extraction: extraction,
            status: isEligible ? "eligible" : "review",
            operation: operation,
            account: account,
            duplicate: duplicate,
            gate: gate,
            reasons: reasons,
            retainedEvidence: retainedEvidence
        )
        try await trace(&claim, "reconstruction", "completed", [], observer)
        try await store.recordGateDecision(
            claim,
            result: gateResult,
            primaryReason: gateReason,
            checksJSON: try SmsProcessingJSON.checksJSON(
                posted: true,
                accountReason: accountReason,
                duplicateStatus: duplicateStatus,
                rolloutMode: rolloutMode
            ),
            accountResolutionJSON: try SmsProcessingJSON.canonical(account),
            rolloutMode: rolloutMode
        )
        try await trace(&claim, "persistence_gate", "completed", reasons, observer)
        if isEligible, let accountID {
            try await trace(&claim, "settlement", "completed", ["persistence_all_gates_passed"], observer)
            let transactionID = try await store.persistAutomaticTransaction(
                claim,
                extraction: transaction,
                accountID: accountID,
                operation: operation
            )
            return .persisted(
                operationID: operation.operationID,
                transactionIDs: [transactionID],
                alreadyCommitted: false
            )
        }
        return try await retain(
            &claim,
            operation: operation,
            reasons: reasons,
            furthestStage: "persistence_gate",
            slmFields: partialFields,
            analysis: analysis,
            source: source,
            recordRetainedResult: false,
            observer: observer
        )
    }

    private func recordResult(
        _ claim: inout SmsOperationClaim,
        extraction: SmsExtractorResult,
        status: String,
        operation: SmsOperationSnapshot,
        account: [String: Any]?,
        duplicate: [String: Any]?,
        gate: [String: Any]?,
        reasons: [String],
        retainedEvidence: [String: Any]?
    ) async throws {
        let result = try SmsProcessingJSON.result(
            status: status,
            extraction: extraction,
            operation: operation,
            account: account,
            duplicate: duplicate,
            gate: gate,
            reasons: reasons,
            retainedEvidence: retainedEvidence
        )
        try await store.recordNormalizedResult(
            claim,
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
            claim,
            stage: stage,
            status: status,
            reasonCodes: safeReasons
        )
        await observer.didReceive(
            SmsProcessingObserverEvent(
                operationID: claim.operationID,
                sequence: receipt.sequence,
                stage: stage,
                status: status,
                reasonCodes: safeReasons
            )
        )
    }

    private func retain(
        _ claim: inout SmsOperationClaim,
        operation: SmsOperationSnapshot,
        reasons: [String],
        furthestStage: String,
        slmFields: [SmsReviewPartialField],
        analysis: SmsAnalysis?,
        source: String,
        recordRetainedResult: Bool = true,
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        let safeReasons =
            reasons.isEmpty
            ? ["persistence_triage_requires_review"]
            : Array(Set(reasons)).sorted()
        if recordRetainedResult {
            let retainedEvidence = SmsReviewProjection.retainedEvidenceJSONObject(
                furthestStage: furthestStage,
                slmFields: slmFields,
                analysis: analysis,
                source: source
            )
            let result = try SmsProcessingJSON.result(
                status: "review",
                extraction: nil,
                operation: operation,
                account: nil,
                duplicate: nil,
                gate: nil,
                reasons: safeReasons,
                retainedEvidence: retainedEvidence
            )
            try await store.recordNormalizedResult(
                claim,
                semanticResultJSON: result,
                decision: nil
            )
        }
        try await trace(&claim, "settlement", "retained", safeReasons, observer)
        let reviewID = try await store.retainForReview(claim, reasons: safeReasons)
        return .retainedForReview(
            operationID: operation.operationID,
            reviewCaseID: reviewID,
            reasons: safeReasons
        )
    }

    private func retainAfterFailure(
        activeClaim: SmsOperationClaim?,
        operation: SmsOperationSnapshot,
        furthestStage: String,
        analysis: SmsAnalysis?,
        source: String?,
        reasons: [String]
    ) async -> SmsProcessingOutcome {
        if let settled = try? await store.settledOutcome(operationID: operation.operationID) {
            return settled
        }
        if let claim = activeClaim {
            if let source,
                let resultJSON = try? SmsProcessingJSON.result(
                    status: "review",
                    extraction: nil,
                    operation: operation,
                    account: nil,
                    duplicate: nil,
                    gate: nil,
                    reasons: reasons,
                    retainedEvidence: SmsReviewProjection.retainedEvidenceJSONObject(
                        furthestStage: furthestStage,
                        slmFields: [],
                        analysis: analysis,
                        source: source
                    )
                )
            {
                try? await store.recordNormalizedResult(
                    claim,
                    semanticResultJSON: resultJSON,
                    decision: nil
                )
            }
            do {
                let reviewID = try await store.retainForReview(claim, reasons: reasons)
                return .retainedForReview(
                    operationID: operation.operationID,
                    reviewCaseID: reviewID,
                    reasons: reasons
                )
            } catch SmsProcessingStoreError.lostOwnership,
                SmsProcessingStoreError.operationNotFound
            {
                if let settled = try? await store.settledOutcome(operationID: operation.operationID) {
                    return settled
                }
                return .retryableFailure(
                    operationID: operation.operationID,
                    reviewCaseID: nil,
                    reason: reasons.first ?? "operation_interrupted"
                )
            } catch {
                // Fall through to best-effort unowned retention.
            }
        }
        return await retainWithoutClaim(operation.operationID, reasons: reasons)
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
            operationID: operationID,
            reasons: reasons
        ) {
            return .retainedForReview(
                operationID: operationID,
                reviewCaseID: reviewID,
                reasons: reasons
            )
        }
        return .retryableFailure(
            operationID: operationID,
            reviewCaseID: nil,
            reason: reasons.first ?? "operation_interrupted"
        )
    }
}
