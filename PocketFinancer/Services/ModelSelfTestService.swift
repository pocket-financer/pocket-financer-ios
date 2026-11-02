import Foundation
import SwiftData

enum ModelSelfTestOutcome: String, Equatable, Sendable {
    case passed
    case failed
}

struct ModelSelfTestFailure: Equatable, Sendable {
    let safeCode: String
    let ownerMessage: String
    let isRetryable: Bool
}

struct ModelSelfTestAPILimitation: Equatable, Identifiable, Sendable {
    let metric: String
    let explanation: String

    var id: String { metric }
}

/// Ephemeral, owner-visible evidence from one synthetic strict extractor run.
struct ModelSelfTestResult: Equatable, Identifiable, Sendable {
    let id: UUID
    let outcome: ModelSelfTestOutcome
    let startedAt: Date
    let completedAt: Date
    let elapsed: TimeInterval
    let contractVersion: String
    let configurationHash: String
    let generationMode: String
    let exactInstructions: String
    let exactRequest: String
    let exactOutput: String?
    let outputCompletion: String
    let analysisJSON: String?
    let syntheticBody: String
    let syntheticSender: String
    let receivedAt: Date
    let settlement: String
    let failure: ModelSelfTestFailure?
    let apiLimitations: [ModelSelfTestAPILimitation]

    var passed: Bool { outcome == .passed }

    var summary: String {
        if passed {
            return "Apple Foundation Models completed one strict SMS Extractor pass "
                + "and the shadow gate retained it without a ledger write."
        }
        return failure?.ownerMessage ?? "The local synthetic selector test did not pass."
    }

    var message: String { summary }
}

enum ModelSelfTestService {
    nonisolated static let syntheticBody =
        "HDFC Bank: INR 500.00 paid from account XXXXXX0000 on 05-08-2026 at Demo Store."
    static let syntheticSender = "AX-HDFCBK"

    static let apiLimitations = [
        ModelSelfTestAPILimitation(
            metric: "System model build or version",
            explanation: "Not exposed by the public Apple Foundation Models API used by Pocket Financer."
        ),
        ModelSelfTestAPILimitation(
            metric: "Input and output token counts",
            explanation: "Not exposed by the public iOS 26 Foundation Models interface used by this build."
        ),
        ModelSelfTestAPILimitation(
            metric: "Tokens per second",
            explanation: "Not exposed; elapsed wall-clock time is the only performance measurement shown."
        ),
        ModelSelfTestAPILimitation(
            metric: "KV-cache details",
            explanation: "Not exposed by the public Apple Foundation Models API."
        ),
        ModelSelfTestAPILimitation(
            metric: "Confidence, probabilities, or logits",
            explanation: "Not exposed by the public Apple Foundation Models API."
        ),
        ModelSelfTestAPILimitation(
            metric: "Hidden reasoning",
            explanation: "Not exposed. Pocket Financer neither requests nor displays chain-of-thought."
        ),
    ]

    @MainActor
    static func run(
        extractor: any FoundationSmsExtracting = FoundationSmsExtractor(),
        extractorEligibilityOverride: Bool? = nil,
        receivedAt requestedReceivedAt: Date? = nil
    ) async -> ModelSelfTestResult {
        let startedAt = Date.now
        let receivedAt = requestedReceivedAt ?? startedAt
        do {
            let database = try AppDatabase(inMemory: true)
            let context = database.container.mainContext
            let alert = InboxAlert(
                sourceIdentity: "synthetic-self-test-\(UUID().uuidString)",
                contentDigest: CanonicalJSON.sha256(syntheticBody),
                origin: .manual,
                sourceApplication: "Synthetic model test",
                sender: syntheticSender,
                rawBody: syntheticBody,
                receivedAt: receivedAt
            )
            context.insert(alert)
            try context.save()
            let snapshot = try SmsV4OperationSnapshotFactory(context: context).create(
                sourceAlertID: alert.id,
                trigger: "diagnostic",
                primaryCurrency: "INR",
                enabledProfiles: ["core-en", "india"],
                extractorEligibilityOverride: extractorEligibilityOverride,
                now: startedAt
            )
            let coordinator = SmsV4ProcessingCoordinator(
                store: SmsProcessingStore(modelContainer: database.container),
                extractor: extractor,
                accountResolver: { _ in .unique(accountID: UUID()) }
            )
            let outcome = await coordinator.process(
                source: AdmittedMessageRef(
                    sourceID: alert.id,
                    admissionReceiptID: alert.id,
                    sourceDigest: CanonicalJSON.sha256(syntheticBody)
                ),
                operation: snapshot,
                observer: NoOpSmsProcessingObserver()
            )
            let verification = ModelContext(database.container)
            let operationID = snapshot.operationID
            let analysis = try verification.fetch(
                FetchDescriptor<SmsProcessingAnalysis>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ).first
            let attempt = try verification.fetch(
                FetchDescriptor<SmsSelectorAttempt>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ).first
            let storedResult = try verification.fetch(
                FetchDescriptor<SmsReconstructedResult>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ).first
            let reconstruction = storedResult?.semanticResultJSON.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let semantic = reconstruction?["semantic_result"] as? [String: Any]
            let money = semantic?["money"] as? [String: Any]
            let ledgerIsEmpty = try verification.fetch(FetchDescriptor<Transaction>()).isEmpty
            let settlement: String
            let reasons: [String]
            switch outcome {
            case .retainedForReview(_, _, let outcomeReasons):
                settlement = "retained_for_review"
                reasons = outcomeReasons
            case .terminallyDiscarded(_, let reason):
                settlement = "discarded"
                reasons = [reason]
            case .persisted:
                settlement = "unexpected_persisted"
                reasons = ["diagnostic_unexpected_persistence"]
            case .retryableFailure(_, _, let reason), .stopped(_, _, let reason):
                settlement = "failed"
                reasons = [reason]
            }
            let passed =
                (money?["minor_units"] as? NSNumber)?.int64Value == 50_000
                && (money?["currency"] as? String) == "INR"
                && (semantic?["direction"] as? String) == "debit"
                && settlement == "retained_for_review"
                && ledgerIsEmpty
            return result(
                passed: passed,
                startedAt: startedAt,
                receivedAt: receivedAt,
                snapshot: snapshot,
                exactRequest: attempt?.requestJSON ?? "{}",
                exactOutput: attempt?.rawOutput,
                outputCompletion: attempt?.completionRawValue ?? "unavailable",
                analysisJSON: analysis?.canonicalJSON,
                settlement: settlement,
                failure: passed
                    ? nil
                    : ModelSelfTestFailure(
                        safeCode: attempt?.safeErrorCode
                            ?? reasons.first
                            ?? "synthetic_expectation_mismatch",
                        ownerMessage: "The synthetic strict extractor run was retained safely "
                            + "but did not produce the expected INR 500.00 debit.",
                        isRetryable: attempt?.safeErrorCode == "runtime_unavailable"
                    )
            )
        } catch {
            let completedAt = Date.now
            return ModelSelfTestResult(
                id: UUID(),
                outcome: .failed,
                startedAt: startedAt,
                completedAt: completedAt,
                elapsed: max(0, completedAt.timeIntervalSince(startedAt)),
                contractVersion: "pocketfinancer.sms-extractor-input/1",
                configurationHash: "unavailable",
                generationMode: "DIRECT_NON_THINKING",
                exactInstructions: (try? FoundationSmsExtractor.instructions()) ?? "unavailable",
                exactRequest: "{}",
                exactOutput: nil,
                outputCompletion: "unavailable",
                analysisJSON: nil,
                syntheticBody: syntheticBody,
                syntheticSender: syntheticSender,
                receivedAt: receivedAt,
                settlement: "failed",
                failure: ModelSelfTestFailure(
                    safeCode: "self_test_failed",
                    ownerMessage: "The local synthetic selector test stopped safely. No transaction was stored.",
                    isRetryable: false
                ),
                apiLimitations: apiLimitations
            )
        }
    }

    private static func result(
        passed: Bool,
        startedAt: Date,
        receivedAt: Date,
        snapshot: SmsV4OperationSnapshot,
        exactRequest: String,
        exactOutput: String?,
        outputCompletion: String,
        analysisJSON: String?,
        settlement: String,
        failure: ModelSelfTestFailure?
    ) -> ModelSelfTestResult {
        let completedAt = Date.now
        return ModelSelfTestResult(
            id: UUID(),
            outcome: passed ? .passed : .failed,
            startedAt: startedAt,
            completedAt: completedAt,
            elapsed: max(0, completedAt.timeIntervalSince(startedAt)),
            contractVersion: "pocketfinancer.sms-extractor-input/1",
            configurationHash: snapshot.configurationHash,
            generationMode: snapshot.configuration.extractor.generationMode,
            exactInstructions: (try? FoundationSmsExtractor.instructions()) ?? "unavailable",
            exactRequest: exactRequest,
            exactOutput: exactOutput,
            outputCompletion: outputCompletion,
            analysisJSON: analysisJSON,
            syntheticBody: syntheticBody,
            syntheticSender: syntheticSender,
            receivedAt: receivedAt,
            settlement: settlement,
            failure: failure,
            apiLimitations: apiLimitations
        )
    }
}
