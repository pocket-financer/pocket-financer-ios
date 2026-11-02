import CryptoKit
import Foundation
import SwiftData

@MainActor
struct SmsOperationSnapshotFactory {
    let context: ModelContext

    func create(
        sourceAlertID: UUID,
        parentOperationID: UUID? = nil,
        trigger: String,
        primaryCurrency: String,
        enabledProfiles: [String],
        selectorModelIdentifier: String,
        selectorRuntimeVersion: String,
        now: Date = .now
    ) throws -> SmsOperationSnapshot {
        try validatePinnedAssets(enabledProfiles: enabledProfiles)
        let sourceID = sourceAlertID
        let descriptor = FetchDescriptor<InboxAlert>(predicate: #Predicate { $0.id == sourceID })
        guard let alert = try context.fetch(descriptor).first else {
            throw SmsProcessingStoreError.sourceNotFound
        }
        let normalizedTrigger: String =
            switch trigger {
            case "realtime": "realtime"
            case "historical": "historical"
            case "retry": "retry"
            case "diagnostic", "test": "diagnostic"
            case "app_intent": "app_intent"
            case "automatic_recovery": "background_recovery"
            default: "manual"
            }
        let metadata = try context.fetch(
            FetchDescriptor<SmsSourceMetadataEvent>(
                predicate: #Predicate { $0.sourceAlertID == sourceID }
            )
        ).first
        let timestampWasSupplied =
            metadata.flatMap { event -> Bool? in
                guard
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(event.payloadJSON.utf8)
                    ) as? [String: Any]
                else { return nil }
                return object["timestamp_supplied"] as? Bool
            } ?? true
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
            else {
                throw SmsProcessingStoreError.operationNotFound
            }
            stableEventID = parent.stableEventID
        } else {
            stableEventID = UUID()
        }
        let configuration = SmsOperationConfiguration(
            operationID: operationID,
            parentOperationID: parentOperationID,
            sourceID: sourceAlertID,
            trigger: normalizedTrigger,
            createdAt: now,
            primaryCurrency: primaryCurrency,
            enabledProfiles: enabledProfiles,
            sourceTimestamp: timestampWasSupplied ? alert.receivedAt : nil,
            sourceTimestampProvenance: timestampWasSupplied
                ? "acquisition_supplied_message_time" : "unknown",
            admissionTimestamp: alert.createdAt,
            timezoneIdentifier: TimeZone.current.identifier,
            selectorModelIdentifier: selectorModelIdentifier,
            selectorRuntimeVersion: selectorRuntimeVersion
        )
        let configurationJSON = try configuration.canonicalJSON
        let configurationHash = try configuration.sha256
        let operation = SmsProcessingOperation(
            id: operationID,
            sourceAlertID: sourceAlertID,
            parentOperationID: parentOperationID,
            stableEventID: stableEventID,
            trigger: normalizedTrigger,
            configurationJSON: configurationJSON,
            configurationHash: configurationHash,
            contractReleaseID: SmsOperationConfiguration.releaseID,
            state: .ready,
            createdAt: now
        )
        context.insert(operation)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw SmsProcessingStoreError.saveFailed
        }
        return SmsOperationSnapshot(
            operationID: operationID,
            parentOperationID: parentOperationID,
            stableEventID: operation.stableEventID,
            configuration: configuration,
            configurationJSON: configurationJSON,
            configurationHash: configurationHash
        )
    }

    private func validatePinnedAssets(enabledProfiles: [String]) throws {
        var expected: [(name: String, ext: String, hash: String)] = [
            (
                "manifest", "json",
                "637013f0988a20eb070e10b07f68ddf9172b847262024a50676c90022234019d"
            ),
            (
                "currency-v1", "json",
                "cb5d991a5ade283f6b2406e4427a2fd1bf5468f67ab6f573f6eb97b4c5919c78"
            ),
            (
                "selector-prompt-v1", "txt",
                "3da47ec16b074ddcf2c03526dd968f9f1f668f9bfbed69bc01c4e2b5c613b940"
            ),
        ]
        for profile in enabledProfiles {
            switch profile {
            case "core-en":
                expected.append(
                    (
                        "profile-core-en-v1", "json",
                        "c9f7b95ce70528d4b564458e320a8788fdf2076ffb55d1d80e80687c48d48b52"
                    ))
            case "india":
                expected.append(
                    (
                        "profile-india-v1", "json",
                        "1cb1a4d7431bb9fe141aa90d45bb3820a115942123668eb4efd6522a73ed0156"
                    ))
            default:
                throw SmsProcessingStoreError.configurationMismatch
            }
        }
        for asset in expected {
            guard
                let url = Bundle.main.url(
                    forResource: asset.name,
                    withExtension: asset.ext,
                    subdirectory: "SmsProcessing"
                ) ?? Bundle.main.url(forResource: asset.name, withExtension: asset.ext),
                let data = try? Data(contentsOf: url),
                Self.sha256(data) == asset.hash
            else {
                throw SmsProcessingStoreError.configurationMismatch
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
