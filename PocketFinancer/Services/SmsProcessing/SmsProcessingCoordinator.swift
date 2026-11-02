import Foundation

protocol SmsProcessingCoordinating: Sendable {
    func process(
        source: AdmittedMessageRef,
        operation: SmsOperationSnapshot,
        observer: any SmsProcessingObserver
    ) async -> SmsProcessingOutcome

    func requestStop(operationID: UUID) async -> StopReceipt
    func resolveReview(_ command: ReviewCommand) async throws -> ReviewReceipt
}

actor DefaultSmsProcessingCoordinator: SmsProcessingCoordinating {
    private let store: SmsProcessingStore
    private let selector: any DirectCandidateSelecting
    private let analyzer = StructuralSmsAnalyzer()
    private let triageEvaluator = SmsTriageEvaluator()
    private let validator = GroundedSelectorValidator()
    private let reconstructor = SemanticReconstructor()
    private let gate = AutomaticPersistenceGate()
    private let accountResolver: @MainActor @Sendable (String?) throws -> SmsAccountResolution

    init(
        store: SmsProcessingStore,
        selector: any DirectCandidateSelecting = FoundationDirectCandidateSelector(),
        accountResolver: @escaping @MainActor @Sendable (String?) throws -> SmsAccountResolution
    ) {
        self.store = store
        self.selector = selector
        self.accountResolver = accountResolver
    }

    func process(
        source: AdmittedMessageRef,
        operation: SmsOperationSnapshot,
        observer: any SmsProcessingObserver = NoOpSmsProcessingObserver()
    ) async -> SmsProcessingOutcome {
        guard
            source.sourceID == operation.configuration.sourceID,
            operation.parentOperationID == operation.configuration.parentOperationID,
            CanonicalJSON.sha256(source.sourceID.uuidString.lowercased())
                == operation.configuration.sourceReferenceHash,
            operation.configuration.contract == "pocketfinancer.processing-config/2",
            operation.configuration.releaseID == SmsOperationConfiguration.releaseID,
            operation.configuration.generationMode == "DIRECT_NON_THINKING",
            operation.configuration.decoding == "greedy",
            operation.configuration.answerTokenLimit == 512,
            operation.configuration.rawOutputByteLimit == 16_384,
            operation.configuration.parserDeadlineMilliseconds == 0,
            ["shadow", "review_only"].contains(operation.configuration.rolloutMode),
            operation.operationID == operation.configuration.operationID,
            (try? operation.configuration.sha256) == operation.configurationHash,
            (try? operation.configuration.canonicalJSON) == operation.configurationJSON
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
                    } catch {
                        return
                    }
                }
            }
            defer { heartbeatTask.cancel() }
            try await trace(&claim, "claim", "completed", [], observer)
            let evidence = try await store.sourceEvidence(sourceID: source.sourceID)
            guard evidence.admissionReceiptID == source.admissionReceiptID,
                CanonicalJSON.sha256(evidence.body) == source.sourceDigest
            else {
                return try await retain(
                    &claim,
                    operation: operation,
                    reasons: ["persistence_configuration_hash_mismatch"],
                    observer: observer
                )
            }
            let analysis = try analyzer.analyze(source: evidence.body, operation: operation)
            try await store.recordAnalysis(analysis, operationID: operation.operationID)
            try await store.transition(claim, expected: .claimed, to: .analyzed)
            try await trace(&claim, "analysis", "completed", analysis.reasonCodes, observer)
            let triage = triageEvaluator.evaluate(analysis)
            try await store.transition(claim, expected: .analyzed, to: .triaged)
            try await trace(&claim, "triage", "completed", triage.reasonCodes, observer)

            if triage.disposition == .discard {
                let reason =
                    triage.reasonCodes.first { $0.hasPrefix("discard_") }
                    ?? "discard_unambiguous_standalone_non_event"
                try await trace(&claim, "settlement", "completed", [reason], observer)
                try await store.settleDiscarded(claim, reason: reason)
                return .terminallyDiscarded(
                    operationID: operation.operationID, reason: reason
                )
            }
            let shouldRunSelector = triage.selectorAction != .skip
            guard shouldRunSelector else {
                return try await retain(
                    &claim, operation: operation, reasons: triage.reasonCodes, observer: observer
                )
            }

            try await store.transition(claim, expected: .triaged, to: .selectorRunning)
            try await trace(&claim, "selector_execution", "running", [], observer)
            let startedAt = Date.now
            let response: DirectSelectorResponse
            do {
                response = try await selector.select(source: evidence.body, analysis: analysis)
            } catch is CancellationError {
                let receipt = try await store.stop(operationID: operation.operationID)
                return .stopped(
                    operationID: operation.operationID,
                    reviewCaseID: receipt.reviewCaseID,
                    reason: "operation_interrupted"
                )
            } catch {
                let safeCode = "runtime_unavailable"
                try await store.recordSelectorFailure(
                    operationID: operation.operationID,
                    runtimeProfileJSON: "{}", requestJSON: "{}",
                    safeErrorCode: safeCode, startedAt: startedAt
                )
                try await trace(&claim, "selector_execution", "failed", [safeCode], observer)
                return try await retain(
                    &claim, operation: operation, reasons: [safeCode],
                    observer: observer
                )
            }
            try await store.recordSelectorResponse(
                operationID: operation.operationID, response: response, startedAt: startedAt
            )
            try await store.transition(claim, expected: .selectorRunning, to: .selectorRecorded)
            try await trace(&claim, "selector_execution", "completed", [], observer)

            let selection: GroundedSelectorResult
            do {
                selection = try validator.validate(
                    rawOutput: response.rawOutput, analysis: analysis,
                    byteLimit: operation.configuration.rawOutputByteLimit
                )
            } catch let error as GroundedSelectorValidationError {
                try await store.markSelectorInvalid(
                    operationID: operation.operationID, safeErrorCode: error.rawValue
                )
                try await trace(
                    &claim, "selector_validation", "failed", [error.rawValue], observer
                )
                return try await retain(
                    &claim, operation: operation, reasons: [error.rawValue], observer: observer
                )
            }
            try await store.transition(claim, expected: .selectorRecorded, to: .validated)
            try await trace(&claim, "selector_validation", "completed", [], observer)

            var reconstructed: ReconstructedSmsTransaction?
            if selection.decision == .posted {
                reconstructed = try reconstructor.reconstruct(
                    selection: selection, analysis: analysis, operation: operation
                )
                try await store.recordReconstruction(
                    reconstructed!, operationID: operation.operationID
                )
                try await store.transition(claim, expected: .validated, to: .reconstructed)
                try await trace(&claim, "reconstruction", "completed", [], observer)
            }
            let accountResolution = try await accountResolver(reconstructed?.accountIdentifier)
            try await trace(&claim, "account_resolution", "completed", [], observer)
            claim = try await store.heartbeat(claim)
            let decision = gate.evaluate(
                analysis: analysis, triage: triage, selection: selection,
                transaction: reconstructed,
                accountResolution: accountResolution, operation: operation,
                claimOwnershipCurrent: true
            )
            try await store.recordGateDecision(
                decision, accountResolution: accountResolution,
                claim: claim, rolloutMode: operation.configuration.rolloutMode
            )
            try await trace(
                &claim,
                "persistence_gate",
                "completed",
                [decision.primaryReason],
                observer
            )
            return try await retain(
                &claim, operation: operation,
                reasons: Array(Set(triage.reasonCodes + [decision.primaryReason])).sorted(),
                observer: observer
            )
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
            return await retainWithoutClaim(
                operation.operationID, reasons: ["operation_interrupted"]
            )
        }
    }

    func requestStop(operationID: UUID) async -> StopReceipt {
        (try? await store.stop(operationID: operationID))
            ?? StopReceipt(
                operationID: operationID,
                reviewCaseID: nil,
                state: .interrupted,
                committed: false
            )
    }

    func resolveReview(_ command: ReviewCommand) async throws -> ReviewReceipt {
        try await store.resolveReview(command)
    }

    private func trace(
        _ claim: inout SmsOperationClaim,
        _ stage: String,
        _ status: String,
        _ reasons: [String],
        _ observer: any SmsProcessingObserver
    ) async throws {
        let receipt = try await store.appendTrace(
            claim, stage: stage, status: status, reasonCodes: reasons
        )
        await observer.didReceive(
            SmsProcessingObserverEvent(
                operationID: claim.operationID, sequence: receipt.sequence,
                stage: stage, status: status, reasonCodes: reasons
            ))
    }

    private func retain(
        _ claim: inout SmsOperationClaim,
        operation: SmsOperationSnapshot,
        reasons: [String],
        observer: any SmsProcessingObserver
    ) async throws -> SmsProcessingOutcome {
        try await trace(&claim, "settlement", "retained", reasons, observer)
        let reviewID = try await store.retainForReview(claim, reasons: reasons)
        return .retainedForReview(
            operationID: operation.operationID, reviewCaseID: reviewID, reasons: reasons
        )
    }

    private func retainWithoutClaim(_ operationID: UUID, reasons: [String]) async -> SmsProcessingOutcome {
        if let reviewID = try? await store.retainUnownedForReview(
            operationID: operationID, reasons: reasons
        ) {
            return .retainedForReview(operationID: operationID, reviewCaseID: reviewID, reasons: reasons)
        }
        return .retryableFailure(
            operationID: operationID, reviewCaseID: nil,
            reason: reasons.first ?? "operation_interrupted"
        )
    }
}
