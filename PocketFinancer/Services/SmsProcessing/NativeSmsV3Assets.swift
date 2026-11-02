import CryptoKit
import Foundation

nonisolated struct NativeSmsV3Artifact: Decodable, Equatable, Sendable {
    let contract: String
    let path: String
    let sha256: String
}

nonisolated struct NativeSmsV3AssetBinding: Equatable, Sendable {
    let releaseID: String
    let manifestSHA256: String
    let artifactsByContract: [String: NativeSmsV3Artifact]
}

nonisolated enum NativeSmsV3AssetIntegrityError: Error, Equatable {
    static let reasonCode = "configuration_integrity"

    case configurationIntegrityFailure
}

/// Verifies the frozen v3 resource bundle before a future v3 operation is admitted.
nonisolated enum NativeSmsV3Assets {
    static let releaseID = "native-integration-v3"
    static let manifestSHA256 =
        "61609c3336374c8b96b1e36cb90b5af01039ceecefcfc1b0091fd9359804436b"
    static let expectedArtifactCount = 44
    static let bundleName = "NativeSmsV3"

    private static let requiredProductionContracts: Set<String> = [
        "pocketfinancer.sms-analysis/2",
        "pocketfinancer.supported-currencies/1",
        "pocketfinancer.analyzer-profile/1:core-en",
        "pocketfinancer.analyzer-profile/1:india",
        "pocketfinancer.persistence-policy/1",
        "pocketfinancer.timestamp-policy/1",
        "pocketfinancer.sms-extractor-input/1",
        "pocketfinancer.sms-extractor/1",
        "pocketfinancer.extractor-validation-profile/1",
        "pocketfinancer.extractor-prompt/1",
        "pocketfinancer.extractor-grammar/1",
        "pocketfinancer.processing-config/3",
        "pocketfinancer.processing-result/3",
        "pocketfinancer.processing-trace/3",
        "pocketfinancer.reason-code-registry/2",
        "pocketfinancer.account-resolution-profile/1",
        "pocketfinancer.review-case/1",
        "pocketfinancer.user-feedback/3",
        "pocketfinancer.canonical-label/2",
    ]

    static func verify(in hostBundle: Bundle = .main) throws -> NativeSmsV3AssetBinding {
        do {
            guard
                let bundleURL = hostBundle.url(forResource: bundleName, withExtension: "bundle"),
                let assetBundle = Bundle(url: bundleURL),
                let resourceURL = assetBundle.resourceURL
            else {
                throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
            }

            let manifestURL = resourceURL.appendingPathComponent(
                "configs/sms_processing/contracts/releases/native-integration-v3.json"
            )
            let manifestData = try Data(contentsOf: manifestURL)
            guard sha256(manifestData) == manifestSHA256 else {
                throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard
                manifest.contract == "pocketfinancer.contract-release-manifest/1",
                manifest.releaseID == releaseID,
                manifest.automaticPersistenceEnabled == false,
                manifest.status == "frozen_for_native_implementation",
                manifest.runtimePolicy.automaticRetryLimit == 3,
                manifest.runtimePolicy.claimHeartbeatMilliseconds == 15_000,
                manifest.runtimePolicy.claimLeaseMilliseconds == 120_000,
                manifest.runtimePolicy.generationMode == "DIRECT_NON_THINKING",
                manifest.runtimePolicy.decoding == "greedy",
                manifest.runtimePolicy.answerTokenLimit == 512,
                manifest.runtimePolicy.rawOutputUTF8ByteLimit == 16_384,
                manifest.runtimePolicy.parserDeadlineMilliseconds == 0,
                manifest.artifacts.count == expectedArtifactCount
            else {
                throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
            }

            var artifactsByContract: [String: NativeSmsV3Artifact] = [:]
            for artifact in manifest.artifacts {
                guard
                    !artifact.contract.isEmpty,
                    isSafeRelativePath(artifact.path),
                    artifact.sha256.range(
                        of: #"^[0-9a-f]{64}$"#, options: .regularExpression
                    ) != nil,
                    artifactsByContract.updateValue(
                        artifact, forKey: artifact.contract
                    ) == nil
                else {
                    throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
                }
                let data = try Data(
                    contentsOf: resourceURL.appendingPathComponent(artifact.path)
                )
                guard sha256(data) == artifact.sha256 else {
                    throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
                }
            }
            guard
                requiredProductionContracts.isSubset(
                    of: Set(artifactsByContract.keys)
                )
            else {
                throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
            }
            return NativeSmsV3AssetBinding(
                releaseID: releaseID,
                manifestSHA256: manifestSHA256,
                artifactsByContract: artifactsByContract
            )
        } catch {
            throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard
            !path.hasPrefix("/"),
            !path.hasPrefix("\\"),
            !path.contains("\\")
        else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return path.hasPrefix("configs/sms_processing/")
            || path.hasPrefix("tests/sms_processing/golden/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
        let contract: String
        let releaseID: String
        let status: String
        let automaticPersistenceEnabled: Bool
        let runtimePolicy: RuntimePolicy
        let artifacts: [NativeSmsV3Artifact]

        enum CodingKeys: String, CodingKey {
            case contract
            case releaseID = "release_id"
            case status
            case automaticPersistenceEnabled = "automatic_persistence_enabled"
            case runtimePolicy = "runtime_policy"
            case artifacts
        }
    }

    private struct RuntimePolicy: Decodable {
        let automaticRetryLimit: Int
        let claimHeartbeatMilliseconds: Int
        let claimLeaseMilliseconds: Int
        let generationMode: String
        let decoding: String
        let answerTokenLimit: Int
        let rawOutputUTF8ByteLimit: Int
        let parserDeadlineMilliseconds: Int

        enum CodingKeys: String, CodingKey {
            case automaticRetryLimit = "automatic_retry_limit"
            case claimHeartbeatMilliseconds = "claim_heartbeat_ms"
            case claimLeaseMilliseconds = "claim_lease_ms"
            case generationMode = "generation_mode"
            case decoding
            case answerTokenLimit = "answer_token_limit"
            case rawOutputUTF8ByteLimit = "raw_output_utf8_byte_limit"
            case parserDeadlineMilliseconds = "parser_deadline_ms"
        }
    }
}
