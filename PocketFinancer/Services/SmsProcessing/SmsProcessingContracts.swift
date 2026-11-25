import CryptoKit
import Foundation

struct AdmittedMessageRef: Codable, Equatable, Sendable {
    let sourceID: UUID
    let admissionReceiptID: UUID
    let sourceDigest: String
}

enum SmsProcessingOutcome: Equatable, Sendable {
    case terminallyDiscarded(operationID: UUID, reason: String)
    case retainedForReview(operationID: UUID, reviewCaseID: UUID, reasons: [String])
    case persisted(operationID: UUID, transactionIDs: [UUID], alreadyCommitted: Bool)
    case retryableFailure(operationID: UUID, reviewCaseID: UUID?, reason: String)
    case stopped(operationID: UUID, reviewCaseID: UUID?, reason: String)
}

struct StopReceipt: Equatable, Sendable {
    let operationID: UUID
    let reviewCaseID: UUID?
    let state: SmsOperationState
    let committed: Bool
}

enum SmsFieldGroundingClassification: String, Codable, Sendable {
    case selectedExistingCandidate = "selected_existing_candidate"
    case changedInterpretationAmongCandidates = "changed_interpretation_among_candidates"
    case suppliedSourceSupportedCandidateMiss = "supplied_source_supported_candidate_miss"
    case suppliedManualUngroundedValue = "supplied_manual_ungrounded_value"
}

struct SmsFieldCorrection: Codable, Equatable, Sendable {
    let field: String
    let classification: SmsFieldGroundingClassification
    let previousRevisionID: UUID?
    let candidateID: String?
    let evidence: SmsEvidenceSpan?
    let scalarEvidence: UnicodeScalarSpan?
    let newValue: String

    init(
        field: String,
        classification: SmsFieldGroundingClassification,
        previousRevisionID: UUID?,
        candidateID: String?,
        evidence: SmsEvidenceSpan?,
        scalarEvidence: UnicodeScalarSpan? = nil,
        newValue: String
    ) {
        self.field = field
        self.classification = classification
        self.previousRevisionID = previousRevisionID
        self.candidateID = candidateID
        self.evidence = evidence
        self.scalarEvidence = scalarEvidence
        self.newValue = newValue
    }
}

enum ReviewCommandKind: String, Codable, Sendable {
    case confirm
    case correct
    case reject
    case resolveMultipleEvents = "resolve_multiple_events"
    case saveDraft = "save_draft"
    case retry
}

struct ReviewCommand: Codable, Equatable, Sendable {
    let actionID: UUID
    let reviewCaseID: UUID
    let expectedRevision: Int
    let kind: ReviewCommandKind
    let corrections: [SmsFieldCorrection]
    let retryConfiguration: String?
}

struct ReviewReceipt: Equatable, Sendable {
    let actionID: UUID
    let reviewCaseID: UUID
    let resultingRevision: Int
    let replayed: Bool
}

struct TransactionProjectionEditCommand: Equatable, Sendable {
    let actionID: UUID
    let transactionID: UUID
    let expectedRevision: Int
    let amountMinorUnits: Int64
    let currencyCode: String
    let direction: TransactionDirection
    let merchant: String
    let accountID: UUID
    let occurredAt: Date
    let corrections: [SmsFieldCorrection]
}

struct TransactionProjectionEditReceipt: Equatable, Sendable {
    let actionID: UUID
    let transactionID: UUID
    let resultingRevision: Int
    let replayed: Bool
}

enum SmsCandidateKind: String, Codable, Sendable {
    case amount
    case direction
    case account
    case counterparty
}

nonisolated struct SmsEvidenceSpan: Codable, Equatable, Sendable {
    let startCharacter: Int
    let endCharacter: Int
    let startUTF8: Int
    let endUTF8: Int
    let text: String
}

nonisolated struct SmsCandidate: Codable, Equatable, Sendable {
    let id: String
    let kind: SmsCandidateKind
    let clauseID: String?
    let evidence: SmsEvidenceSpan?
    let explicitlyAbsent: Bool
    let value: [String: String]
    let context: [String]
}

nonisolated struct SmsClause: Codable, Equatable, Sendable {
    let id: String
    let evidence: SmsEvidenceSpan
    let states: [String]
    let financialFamilies: [String]
}

nonisolated struct SmsCue: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let clauseID: String
    let evidence: SmsEvidenceSpan
    let reasonCode: String
}

nonisolated struct SmsFinancialFamily: Codable, Equatable, Sendable {
    let family: String
    let evidence: SmsEvidenceSpan
}

nonisolated struct SmsClauseAnnotation: Codable, Equatable, Sendable {
    let clauseID: String
    let states: [String]
    let financialFamilies: [SmsFinancialFamily]
}

nonisolated struct SmsAnalysis: Codable, Equatable, Sendable {
    let contract: String
    let analysisID: String
    let configurationHash: String
    let sourceHash: String
    let source: String
    let clauses: [SmsClause]
    let candidates: [SmsCandidate]
    let cues: [SmsCue]
    let reasonCodes: [String]
    let completedEventCount: Int
    let profileID: String
    let primaryCurrency: String
    let normalizedStructuralFingerprint: String
    let currencyContextHash: String
    let sourceTimestampEpochMilliseconds: Int64?
    let sourceTimestampProvenance: String
    let unicodeDatabaseVersion: String
    let clauseAnnotations: [SmsClauseAnnotation]

    var canonicalJSON: String {
        get throws {
            let object: [String: Any] = [
                "analysis_id": analysisID,
                "candidates": candidates.map(candidateJSONObject),
                "clauses": clauses.map {
                    ["clause_id": $0.id, "evidence": evidenceJSONObject($0.evidence)]
                },
                "config_hash": configurationHash,
                "contract": contract,
                "cues": cues.map {
                    [
                        "clause_id": $0.clauseID,
                        "cue_id": $0.id,
                        "evidence": evidenceJSONObject($0.evidence),
                        "kind": $0.kind,
                        "reason_code": $0.reasonCode,
                    ] as [String: Any]
                },
                "metadata": [
                    "analyzer_behavior_version": "pocketfinancer.structural-sms-analyzer/2",
                    "clause_annotations": clauseAnnotations.map {
                        [
                            "clause_id": $0.clauseID,
                            "financial_families": $0.financialFamilies.map {
                                [
                                    "evidence": evidenceJSONObject($0.evidence),
                                    "family": $0.family,
                                ] as [String: Any]
                            },
                            "states": $0.states,
                        ] as [String: Any]
                    },
                    "completed_event_candidate_count": completedEventCount,
                    "completed_event_clause_count": Set(
                        candidates.compactMap { $0.kind == .direction ? $0.clauseID : nil }
                    ).count,
                    "currency_context_hash": currencyContextHash,
                    "input_valid": !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "is_outgoing": false,
                    "normalized_structural_fingerprint": normalizedStructuralFingerprint,
                    "source_timestamp": [
                        "epoch_ms": sourceTimestampEpochMilliseconds as Any? ?? NSNull(),
                        "provenance": sourceTimestampProvenance,
                    ],
                    "unicode_behavior": [
                        "normalization": "per_code_point_nfkc_casefold",
                        "unicode_database_version": unicodeDatabaseVersion,
                        "whitespace": "collapse_unicode_whitespace",
                    ],
                ] as [String: Any],
                "primary_currency": primaryCurrency,
                "profile_id": profileID,
                "reason_codes": reasonCodes,
                "source_fingerprint": sourceHash,
                "source_length_chars": source.unicodeScalars.count,
                "source_length_utf8": source.utf8.count,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard let result = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return result
        }
    }

    private func candidateJSONObject(_ candidate: SmsCandidate) -> [String: Any] {
        var value: [String: Any] = candidate.value
        if candidate.kind == .amount,
            let rawMinorUnits = candidate.value["minor_units"],
            let minorUnits = Int64(rawMinorUnits)
        {
            value["minor_units"] = minorUnits
        }
        return [
            "candidate_id": candidate.id,
            "clause_id": candidate.clauseID as Any? ?? NSNull(),
            "context": candidate.context,
            "evidence": candidate.evidence.map(evidenceJSONObject) as Any? ?? NSNull(),
            "explicit_absence": candidate.explicitlyAbsent,
            "kind": candidate.kind.rawValue,
            "value": value,
        ]
    }

    private func evidenceJSONObject(_ evidence: SmsEvidenceSpan) -> [String: Any] {
        [
            "end_char": evidence.endCharacter,
            "end_utf8": evidence.endUTF8,
            "start_char": evidence.startCharacter,
            "start_utf8": evidence.startUTF8,
            "text": evidence.text,
        ]
    }
}

enum PersistenceGateResult: String, Codable, Sendable {
    case eligible
    case reviewRequired = "review_required"
    case notPosted = "not_posted"
    case multipleEvents = "multiple_events"
    case blockedByMode = "blocked_by_mode"
    case invalidOperation = "invalid_operation"
}

struct PersistenceGateCheck: Codable, Equatable, Sendable {
    let check: String
    let passed: Bool
    let reasonCode: String?
}

struct PersistenceGateDecision: Codable, Equatable, Sendable {
    let result: PersistenceGateResult
    let primaryReason: String
    let checks: [PersistenceGateCheck]
}

protocol SmsProcessingObserver: Sendable {
    func didReceive(_ event: SmsProcessingObserverEvent) async
}

struct SmsProcessingObserverEvent: Equatable, Sendable {
    let operationID: UUID
    let sequence: Int
    let stage: String
    let status: String
    let reasonCodes: [String]
}

struct SmsTraceReceipt: Equatable, Sendable {
    let eventID: UUID
    let sequence: Int
    let eventHash: String
}

struct NoOpSmsProcessingObserver: SmsProcessingObserver {
    func didReceive(_: SmsProcessingObserverEvent) async {}
}

enum CanonicalJSON {
    nonisolated static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    nonisolated static func string<T: Encodable>(_ value: T) throws -> String {
        guard let result = String(data: try data(value), encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return result
    }

    nonisolated static func sha256<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Date {
    fileprivate nonisolated var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}
