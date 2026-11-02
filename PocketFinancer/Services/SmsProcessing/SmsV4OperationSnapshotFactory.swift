import Foundation
import FoundationModels
import SwiftData

nonisolated struct SmsV4OperationSnapshot: Sendable {
    let operationID: UUID
    let parentOperationID: UUID?
    let stableEventID: UUID
    let sourceID: UUID
    let configuration: SmsV4OperationConfiguration
    let configurationJSON: String
    let configurationHash: String
}

@MainActor
struct SmsV4OperationSnapshotFactory {
    let context: ModelContext

    func create(
        sourceAlertID: UUID,
        parentOperationID: UUID? = nil,
        trigger: String,
        primaryCurrency: String,
        enabledProfiles: [String],
        extractorEligibilityOverride: Bool? = nil,
        now: Date = .now
    ) throws -> SmsV4OperationSnapshot {
        let binding: NativeSmsV3AssetBinding
        do { binding = try NativeSmsV4Assets.verify() } catch { throw SmsProcessingStoreError.configurationMismatch }
        guard CurrencyFormatter.supportedScales[primaryCurrency] != nil,
            !enabledProfiles.isEmpty,
            Set(enabledProfiles).count == enabledProfiles.count,
            enabledProfiles.allSatisfy({ ["core-en", "india"].contains($0) })
        else { throw SmsProcessingStoreError.configurationMismatch }
        let sourceID = sourceAlertID
        guard
            let alert = try context.fetch(
                FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
            ).first
        else { throw SmsProcessingStoreError.sourceNotFound }
        let operationID = UUID()
        let stableEventID: UUID
        if let parentOperationID {
            let parentID = parentOperationID
            guard
                let parent = try context.fetch(
                    FetchDescriptor<SmsProcessingOperation>(
                        predicate: #Predicate { $0.id == parentID }
                    )
                ).first
            else { throw SmsProcessingStoreError.operationNotFound }
            stableEventID = parent.stableEventID
        } else {
            stableEventID = UUID()
        }
        let model = SystemLanguageModel.default
        let eligible: Bool
        if let extractorEligibilityOverride {
            eligible = extractorEligibilityOverride
        } else if case .available = model.availability {
            eligible = true
        } else {
            eligible = false
        }
        let configuration = SmsV4OperationConfiguration(
            operationID: operationID,
            parentOperationID: parentOperationID,
            sourceID: sourceAlertID,
            trigger: Self.normalizedTrigger(trigger),
            primaryCurrency: primaryCurrency,
            enabledProfiles: enabledProfiles,
            receivedAt: alert.receivedAt,
            admissionAt: alert.createdAt,
            timezoneID: TimeZone.current.identifier,
            binding: binding,
            extractorEligible: eligible,
            createdAt: now
        )
        let payloadJSON = try configuration.payloadJSON()
        let hash = CanonicalJSON.sha256(payloadJSON)
        let configurationJSON = try configuration.documentJSON(configHash: hash)
        let operation = SmsProcessingOperation(
            id: operationID,
            sourceAlertID: sourceAlertID,
            parentOperationID: parentOperationID,
            stableEventID: stableEventID,
            trigger: configuration.trigger,
            configurationJSON: configurationJSON,
            configurationHash: hash,
            contractReleaseID: NativeSmsV4Assets.releaseID,
            state: .ready,
            createdAt: now
        )
        context.insert(operation)
        do { try context.save() } catch {
            context.rollback()
            throw SmsProcessingStoreError.saveFailed
        }
        return SmsV4OperationSnapshot(
            operationID: operationID,
            parentOperationID: parentOperationID,
            stableEventID: stableEventID,
            sourceID: sourceAlertID,
            configuration: configuration,
            configurationJSON: configurationJSON,
            configurationHash: hash
        )
    }

    private static func normalizedTrigger(_ trigger: String) -> String {
        switch trigger {
        case "realtime": "realtime"
        case "historical": "historical"
        case "retry": "retry"
        case "diagnostic", "test": "diagnostic"
        case "app_intent": "app_intent"
        case "automatic_recovery": "background_recovery"
        default: "manual"
        }
    }
}

nonisolated struct SmsV4OperationConfiguration: Codable, Sendable {
    let contract = "pocketfinancer.processing-config/4"
    let operationID: String
    let parentOperationID: String?
    let sourceRefHash: String
    let trigger: String
    let createdAtEpochMs: Int64
    let admissionEpochMs: Int64
    let contractRelease: Release
    let analyzer: Analyzer
    let currencyContext: CurrencyContext
    let receivedTimestamp: ReceivedTimestamp
    let extractor: Extractor
    let persistencePolicy = PersistencePolicy()

    struct Release: Codable, Sendable {
        let releaseID: String
        let manifestSHA256: String
        enum CodingKeys: String, CodingKey {
            case releaseID = "release_id"
            case manifestSHA256 = "manifest_sha256"
        }
    }
    struct Asset: Codable, Sendable {
        let assetID: String
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case sha256
        }
    }
    struct Analyzer: Codable, Sendable {
        let behaviorVersion = "pocketfinancer.structural-sms-analyzer/2"
        let unicodeBehaviorVersion = "14.0.0-per-code-point-nfkc-casefold"
        let currencyAssetSHA256: String
        let profileAssets: [Asset]
        enum CodingKeys: String, CodingKey {
            case behaviorVersion = "behavior_version"
            case unicodeBehaviorVersion = "unicode_behavior_version"
            case currencyAssetSHA256 = "currency_asset_sha256"
            case profileAssets = "profile_assets"
        }
    }
    struct CurrencyContext: Codable, Sendable {
        let primaryCurrency: String
        let enabledProfileIDs: [String]
        enum CodingKeys: String, CodingKey {
            case primaryCurrency = "primary_currency"
            case enabledProfileIDs = "enabled_profile_ids"
        }
    }
    struct ReceivedTimestamp: Codable, Sendable {
        let epochMs: Int64
        let provenance = "platform_received"
        let timezoneID: String
        let readOnly = true
        enum CodingKeys: String, CodingKey {
            case epochMs = "epoch_ms"
            case provenance
            case timezoneID = "timezone_id"
            case readOnly = "read_only"
        }
    }
    struct Extractor: Codable, Sendable {
        let eligible: Bool
        let ineligibilityReason: String?
        let modelIdentifier: String?
        let modelFileSHA256: String? = nil
        let modelIdentityKind = "system_managed_runtime"
        let runtimeVersion: String
        let osVersion: String
        let deviceCohort = "apple-system-language-model"
        let promptSHA256: String
        let grammarSHA256: String
        let validationProfileSHA256: String
        let promptVersion = "pocketfinancer.extractor-prompt/1"
        let validationProfile = "pocketfinancer.extractor-validation-profile/1"
        let grammarVersion = "pocketfinancer.extractor-grammar/1"
        let generationMode = "DIRECT_NON_THINKING"
        let decoding = "greedy"
        let answerTokenLimit = 512
        let rawOutputUTF8ByteLimit = 16_384
        let parserDeadlineMs = 0
        enum CodingKeys: String, CodingKey {
            case eligible
            case ineligibilityReason = "ineligibility_reason"
            case modelIdentifier = "model_identifier"
            case modelFileSHA256 = "model_file_sha256"
            case modelIdentityKind = "model_identity_kind"
            case runtimeVersion = "runtime_version"
            case osVersion = "os_version"
            case deviceCohort = "device_cohort"
            case promptSHA256 = "prompt_sha256"
            case grammarSHA256 = "grammar_sha256"
            case validationProfileSHA256 = "validation_profile_sha256"
            case promptVersion = "prompt_version"
            case validationProfile = "validation_profile"
            case grammarVersion = "grammar_version"
            case generationMode = "generation_mode"
            case decoding
            case answerTokenLimit = "answer_token_limit"
            case rawOutputUTF8ByteLimit = "raw_output_utf8_byte_limit"
            case parserDeadlineMs = "parser_deadline_ms"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(eligible, forKey: .eligible)
            if let ineligibilityReason {
                try container.encode(ineligibilityReason, forKey: .ineligibilityReason)
            } else {
                try container.encodeNil(forKey: .ineligibilityReason)
            }
            if let modelIdentifier {
                try container.encode(modelIdentifier, forKey: .modelIdentifier)
            } else {
                try container.encodeNil(forKey: .modelIdentifier)
            }
            try container.encodeNil(forKey: .modelFileSHA256)
            try container.encode(modelIdentityKind, forKey: .modelIdentityKind)
            try container.encode(runtimeVersion, forKey: .runtimeVersion)
            try container.encode(osVersion, forKey: .osVersion)
            try container.encode(deviceCohort, forKey: .deviceCohort)
            try container.encode(promptSHA256, forKey: .promptSHA256)
            try container.encode(grammarSHA256, forKey: .grammarSHA256)
            try container.encode(validationProfileSHA256, forKey: .validationProfileSHA256)
            try container.encode(promptVersion, forKey: .promptVersion)
            try container.encode(validationProfile, forKey: .validationProfile)
            try container.encode(grammarVersion, forKey: .grammarVersion)
            try container.encode(generationMode, forKey: .generationMode)
            try container.encode(decoding, forKey: .decoding)
            try container.encode(answerTokenLimit, forKey: .answerTokenLimit)
            try container.encode(rawOutputUTF8ByteLimit, forKey: .rawOutputUTF8ByteLimit)
            try container.encode(parserDeadlineMs, forKey: .parserDeadlineMs)
        }
    }
    struct PersistencePolicy: Codable, Sendable {
        let version = "pocketfinancer.persistence-policy/1"
        let rolloutMode = "review_only"
        enum CodingKeys: String, CodingKey {
            case version
            case rolloutMode = "rollout_mode"
        }
    }

    init(
        operationID: UUID, parentOperationID: UUID?, sourceID: UUID, trigger: String,
        primaryCurrency: String, enabledProfiles: [String], receivedAt: Date,
        admissionAt: Date, timezoneID: String, binding: NativeSmsV3AssetBinding,
        extractorEligible: Bool, createdAt: Date
    ) {
        self.operationID = operationID.uuidString.lowercased()
        self.parentOperationID = parentOperationID?.uuidString.lowercased()
        sourceRefHash = CanonicalJSON.sha256(sourceID.uuidString.lowercased())
        self.trigger = trigger
        createdAtEpochMs = Self.epoch(createdAt)
        admissionEpochMs = Self.epoch(admissionAt)
        contractRelease = Release(
            releaseID: binding.releaseID, manifestSHA256: binding.manifestSHA256
        )
        func asset(_ contract: String) -> String {
            binding.artifactsByContract[contract]!.sha256
        }
        analyzer = Analyzer(
            currencyAssetSHA256: asset("pocketfinancer.supported-currencies/1"),
            profileAssets: enabledProfiles.map {
                Asset(assetID: $0, sha256: asset("pocketfinancer.analyzer-profile/1:\($0)"))
            }
        )
        currencyContext = CurrencyContext(
            primaryCurrency: primaryCurrency.uppercased(),
            enabledProfileIDs: enabledProfiles
        )
        receivedTimestamp = ReceivedTimestamp(
            epochMs: Self.epoch(receivedAt), timezoneID: timezoneID
        )
        extractor = Extractor(
            eligible: extractorEligible,
            ineligibilityReason: extractorEligible ? nil : "runtime_unavailable",
            modelIdentifier: "apple-system-language-model",
            runtimeVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            promptSHA256: asset("pocketfinancer.extractor-prompt/1"),
            grammarSHA256: asset("pocketfinancer.extractor-grammar/1"),
            validationProfileSHA256: asset("pocketfinancer.extractor-validation-profile/1")
        )
    }

    func payloadJSON() throws -> String { try CanonicalJSON.string(self) }
    func documentJSON(configHash: String) throws -> String {
        guard
            var document = try JSONSerialization.jsonObject(
                with: Data(payloadJSON().utf8)
            ) as? [String: Any]
        else { throw SmsProcessingStoreError.configurationMismatch }
        document["config_hash"] = configHash
        return try SmsV4ProcessingJSON.canonical(document)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contract, forKey: .contract)
        try container.encode(operationID, forKey: .operationID)
        if let parentOperationID {
            try container.encode(parentOperationID, forKey: .parentOperationID)
        } else {
            try container.encodeNil(forKey: .parentOperationID)
        }
        try container.encode(sourceRefHash, forKey: .sourceRefHash)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(createdAtEpochMs, forKey: .createdAtEpochMs)
        try container.encode(admissionEpochMs, forKey: .admissionEpochMs)
        try container.encode(contractRelease, forKey: .contractRelease)
        try container.encode(analyzer, forKey: .analyzer)
        try container.encode(currencyContext, forKey: .currencyContext)
        try container.encode(receivedTimestamp, forKey: .receivedTimestamp)
        try container.encode(extractor, forKey: .extractor)
        try container.encode(persistencePolicy, forKey: .persistencePolicy)
    }

    private static func epoch(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
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
        case receivedTimestamp = "received_timestamp"
        case extractor
        case persistencePolicy = "persistence_policy"
    }
}
