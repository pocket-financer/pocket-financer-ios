import CryptoKit
import Foundation

struct AdmittedMessageRef: Codable, Equatable, Sendable {
    let sourceID: UUID
    let admissionReceiptID: UUID
    let sourceDigest: String
}

nonisolated struct SmsOperationConfiguration: Codable, Equatable, Sendable {
    static let releaseID = "native-integration-v2"

    let contract: String
    let releaseID: String
    let operationID: UUID
    let parentOperationID: UUID?
    let sourceID: UUID
    let sourceReferenceHash: String
    let trigger: String
    let createdAtEpochMilliseconds: Int64
    let primaryCurrency: String
    let enabledProfiles: [String]
    let sourceTimestampEpochMilliseconds: Int64?
    let sourceTimestampProvenance: String
    let admissionTimestampEpochMilliseconds: Int64
    let timezoneIdentifier: String
    let releaseManifestHash: String
    let currencyAssetHash: String
    let profileAssetHashes: [String: String]
    let analyzerVersion: String
    let unicodeVersion: String
    let selectorModelIdentifier: String
    let selectorRuntimeVersion: String
    let promptVersion: String
    let validationProfile: String
    let persistencePolicy: String
    let rolloutMode: String
    let generationMode: String
    let decoding: String
    let answerTokenLimit: Int
    let rawOutputByteLimit: Int
    let parserDeadlineMilliseconds: Int

    init(
        operationID: UUID,
        parentOperationID: UUID? = nil,
        sourceID: UUID,
        trigger: String,
        createdAt: Date,
        primaryCurrency: String,
        enabledProfiles: [String],
        sourceTimestamp: Date?,
        sourceTimestampProvenance: String,
        admissionTimestamp: Date,
        timezoneIdentifier: String,
        selectorModelIdentifier: String,
        selectorRuntimeVersion: String
    ) {
        contract = "pocketfinancer.processing-config/2"
        releaseID = Self.releaseID
        self.operationID = operationID
        self.parentOperationID = parentOperationID
        self.sourceID = sourceID
        sourceReferenceHash = CanonicalJSON.sha256(sourceID.uuidString.lowercased())
        self.trigger = trigger
        createdAtEpochMilliseconds = createdAt.epochMilliseconds
        self.primaryCurrency = primaryCurrency.uppercased()
        self.enabledProfiles = enabledProfiles.sorted()
        sourceTimestampEpochMilliseconds = sourceTimestamp?.epochMilliseconds
        self.sourceTimestampProvenance = sourceTimestampProvenance
        admissionTimestampEpochMilliseconds = admissionTimestamp.epochMilliseconds
        self.timezoneIdentifier = timezoneIdentifier
        releaseManifestHash = "637013f0988a20eb070e10b07f68ddf9172b847262024a50676c90022234019d"
        currencyAssetHash = "cb5d991a5ade283f6b2406e4427a2fd1bf5468f67ab6f573f6eb97b4c5919c78"
        profileAssetHashes = Dictionary(
            uniqueKeysWithValues: enabledProfiles.map { profile in
                switch profile {
                case "core-en":
                    (profile, "c9f7b95ce70528d4b564458e320a8788fdf2076ffb55d1d80e80687c48d48b52")
                case "india":
                    (profile, "1cb1a4d7431bb9fe141aa90d45bb3820a115942123668eb4efd6522a73ed0156")
                default:
                    preconditionFailure("Unsupported analyzer profile")
                }
            })
        analyzerVersion = "pocketfinancer.structural-sms-analyzer/2"
        unicodeVersion = "14.0.0-per-code-point-nfkc-casefold"
        self.selectorModelIdentifier = selectorModelIdentifier
        self.selectorRuntimeVersion = selectorRuntimeVersion
        promptVersion = "pocketfinancer.selector-prompt/1"
        validationProfile = "pocketfinancer.selector-validation-profile/3"
        persistencePolicy = "pocketfinancer.persistence-policy/1"
        rolloutMode = "shadow"
        generationMode = "DIRECT_NON_THINKING"
        decoding = "greedy"
        answerTokenLimit = 512
        rawOutputByteLimit = 16_384
        parserDeadlineMilliseconds = 0
    }

    var canonicalJSON: String {
        get throws {
            let payload = payload
            return try CanonicalJSON.string(
                SmsConfigurationDocument(payload: payload, configHash: try CanonicalJSON.sha256(payload))
            )
        }
    }

    var sha256: String {
        get throws { try CanonicalJSON.sha256(payload) }
    }

    private var payload: SmsConfigurationPayload {
        SmsConfigurationPayload(
            contract: contract,
            operationID: operationID.uuidString.lowercased(),
            parentOperationID: parentOperationID?.uuidString.lowercased(),
            sourceRefHash: sourceReferenceHash,
            trigger: trigger,
            createdAtEpochMs: createdAtEpochMilliseconds,
            admissionEpochMs: admissionTimestampEpochMilliseconds,
            contractRelease: .init(releaseID: releaseID, manifestSHA256: releaseManifestHash),
            analyzer: .init(
                behaviorVersion: analyzerVersion,
                unicodeBehaviorVersion: unicodeVersion,
                currencyAssetSHA256: currencyAssetHash,
                profileAssets: enabledProfiles.map {
                    .init(assetID: $0, sha256: profileAssetHashes[$0]!)
                }
            ),
            currencyContext: .init(
                primaryCurrency: primaryCurrency, enabledProfileIDs: enabledProfiles
            ),
            sourceTimestamp: .init(
                epochMs: sourceTimestampEpochMilliseconds,
                provenance: sourceTimestampProvenance,
                timezoneID: timezoneIdentifier,
                policyVersion: "pocketfinancer.timestamp-policy/1"
            ),
            selector: .init(
                eligible: true,
                ineligibilityReason: nil,
                modelIdentifier: selectorModelIdentifier,
                modelFileSHA256: nil,
                runtimeVersion: selectorRuntimeVersion,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceCohort: "apple-system-language-model",
                promptVersion: promptVersion,
                promptSHA256: "3da47ec16b074ddcf2c03526dd968f9f1f668f9bfbed69bc01c4e2b5c613b940",
                validationProfile: validationProfile,
                generationMode: generationMode,
                decoding: decoding,
                answerTokenLimit: answerTokenLimit,
                rawOutputUTF8ByteLimit: rawOutputByteLimit,
                parserDeadlineMs: parserDeadlineMilliseconds
            ),
            persistencePolicy: .init(version: persistencePolicy, rolloutMode: rolloutMode)
        )
    }
}

nonisolated private struct SmsConfigurationPayload: Codable {
    struct ContractRelease: Codable {
        let releaseID: String
        let manifestSHA256: String
        enum CodingKeys: String, CodingKey {
            case releaseID = "release_id"
            case manifestSHA256 = "manifest_sha256"
        }
    }
    struct Asset: Codable {
        let assetID: String
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case sha256
        }
    }
    struct Analyzer: Codable {
        let behaviorVersion: String
        let unicodeBehaviorVersion: String
        let currencyAssetSHA256: String
        let profileAssets: [Asset]
        enum CodingKeys: String, CodingKey {
            case behaviorVersion = "behavior_version"
            case unicodeBehaviorVersion = "unicode_behavior_version"
            case currencyAssetSHA256 = "currency_asset_sha256"
            case profileAssets = "profile_assets"
        }
    }
    struct CurrencyContext: Codable {
        let primaryCurrency: String
        let enabledProfileIDs: [String]
        enum CodingKeys: String, CodingKey {
            case primaryCurrency = "primary_currency"
            case enabledProfileIDs = "enabled_profile_ids"
        }
    }
    struct SourceTimestamp: Codable {
        let epochMs: Int64?
        let provenance: String
        let timezoneID: String
        let policyVersion: String
        enum CodingKeys: String, CodingKey {
            case epochMs = "epoch_ms"
            case provenance
            case timezoneID = "timezone_id"
            case policyVersion = "policy_version"
        }
    }
    struct Selector: Codable {
        let eligible: Bool
        let ineligibilityReason: String?
        let modelIdentifier: String?
        let modelFileSHA256: String?
        let runtimeVersion: String
        let osVersion: String
        let deviceCohort: String
        let promptVersion: String
        let promptSHA256: String
        let validationProfile: String
        let generationMode: String
        let decoding: String
        let answerTokenLimit: Int
        let rawOutputUTF8ByteLimit: Int
        let parserDeadlineMs: Int
        enum CodingKeys: String, CodingKey {
            case eligible
            case ineligibilityReason = "ineligibility_reason"
            case modelIdentifier = "model_identifier"
            case modelFileSHA256 = "model_file_sha256"
            case runtimeVersion = "runtime_version"
            case osVersion = "os_version"
            case deviceCohort = "device_cohort"
            case promptVersion = "prompt_version"
            case promptSHA256 = "prompt_sha256"
            case validationProfile = "validation_profile"
            case generationMode = "generation_mode"
            case decoding
            case answerTokenLimit = "answer_token_limit"
            case rawOutputUTF8ByteLimit = "raw_output_utf8_byte_limit"
            case parserDeadlineMs = "parser_deadline_ms"
        }
    }
    struct PersistencePolicy: Codable {
        let version: String
        let rolloutMode: String
        enum CodingKeys: String, CodingKey {
            case version
            case rolloutMode = "rollout_mode"
        }
    }
    let contract: String
    let operationID: String
    let parentOperationID: String?
    let sourceRefHash: String
    let trigger: String
    let createdAtEpochMs: Int64
    let admissionEpochMs: Int64
    let contractRelease: ContractRelease
    let analyzer: Analyzer
    let currencyContext: CurrencyContext
    let sourceTimestamp: SourceTimestamp
    let selector: Selector
    let persistencePolicy: PersistencePolicy
    enum CodingKeys: String, CodingKey {
        case contract
        case operationID = "operation_id"
        case parentOperationID = "parent_operation_id"
        case sourceRefHash = "source_ref_hash"
        case trigger
        case createdAtEpochMs = "created_at_epoch_ms"
        case admissionEpochMs = "admission_epoch_ms"
        case contractRelease = "contract_release"
        case analyzer
        case currencyContext = "currency_context"
        case sourceTimestamp = "source_timestamp"
        case selector
        case persistencePolicy = "persistence_policy"
    }
}

nonisolated private struct SmsConfigurationDocument: Codable {
    let contract: String
    let operationID: String
    let parentOperationID: String?
    let sourceRefHash: String
    let trigger: String
    let createdAtEpochMs: Int64
    let admissionEpochMs: Int64
    let contractRelease: SmsConfigurationPayload.ContractRelease
    let analyzer: SmsConfigurationPayload.Analyzer
    let currencyContext: SmsConfigurationPayload.CurrencyContext
    let sourceTimestamp: SmsConfigurationPayload.SourceTimestamp
    let selector: SmsConfigurationPayload.Selector
    let persistencePolicy: SmsConfigurationPayload.PersistencePolicy
    let configHash: String

    init(payload: SmsConfigurationPayload, configHash: String) {
        contract = payload.contract
        operationID = payload.operationID
        parentOperationID = payload.parentOperationID
        sourceRefHash = payload.sourceRefHash
        trigger = payload.trigger
        createdAtEpochMs = payload.createdAtEpochMs
        admissionEpochMs = payload.admissionEpochMs
        contractRelease = payload.contractRelease
        analyzer = payload.analyzer
        currencyContext = payload.currencyContext
        sourceTimestamp = payload.sourceTimestamp
        selector = payload.selector
        persistencePolicy = payload.persistencePolicy
        self.configHash = configHash
    }

    enum CodingKeys: String, CodingKey {
        case contract
        case operationID = "operation_id"
        case parentOperationID = "parent_operation_id"
        case sourceRefHash = "source_ref_hash"
        case trigger
        case createdAtEpochMs = "created_at_epoch_ms"
        case admissionEpochMs = "admission_epoch_ms"
        case contractRelease = "contract_release"
        case analyzer
        case currencyContext = "currency_context"
        case sourceTimestamp = "source_timestamp"
        case selector
        case persistencePolicy = "persistence_policy"
        case configHash = "config_hash"
    }
}

struct SmsOperationSnapshot: Equatable, Sendable {
    let operationID: UUID
    let parentOperationID: UUID?
    let stableEventID: UUID
    let configuration: SmsOperationConfiguration
    let configurationJSON: String
    let configurationHash: String
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

enum SelectorDecision: String, Codable, Sendable {
    case none
    case abstain
    case posted
}

struct SelectorPostedSelection: Codable, Equatable, Sendable {
    let amountCandidateID: String
    let directionCandidateID: String
    let accountCandidateID: String
    let counterpartyCandidateID: String
}

struct GroundedSelectorResult: Codable, Equatable, Sendable {
    let decision: SelectorDecision
    let posted: SelectorPostedSelection?
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
