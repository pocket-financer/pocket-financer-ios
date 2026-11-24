import CryptoKit
import Foundation

nonisolated struct SmsContractArtifact: Decodable, Equatable, Sendable {
    let path: String
    let contract: String
    let sha256: String
}

nonisolated struct SmsContractBundle: Equatable, Sendable {
    let releaseID: String
    let manifestSHA256: String
    let duplicateWindowMilliseconds: Int64
    let artifactsByPath: [String: SmsContractArtifact]

    func sha256(forRelativePath path: String) throws -> String {
        guard let artifact = artifactsByPath[path] else {
            throw SmsContractAssetError.configurationIntegrityFailure
        }
        return artifact.sha256
    }
}

nonisolated enum SmsContractAssetError: Error, Equatable, Sendable {
    static let reasonCode = "configuration_integrity"

    case configurationIntegrityFailure
}

/// Verifies and loads canonical SMS pipeline contracts, prompts, schemas, and profiles.
nonisolated enum SmsContractAssets {
    static let releaseID = "pocketfinancer.sms-pipeline/1"
    static let duplicateWindowMilliseconds: Int64 = 300_000
    static let duplicateWindowSeconds: TimeInterval = 300

    static let requiredIOSAssetPaths: [String] = [
        "prompts/apple-fm-sms-extractor.txt",
        "schemas/apple-fm-flat.schema.json",
        "schemas/sms-extractor.schema.json",
        "schemas/sms-extractor-input.schema.json",
        "schemas/sms-analysis.schema.json",
        "schemas/processing-config.schema.json",
        "schemas/processing-result.schema.json",
        "schemas/processing-trace.schema.json",
        "schemas/review-case.schema.json",
        "schemas/user-feedback.schema.json",
        "profiles/currency.json",
        "profiles/account-resolution.json",
        "profiles/extractor-validation.json",
        "profiles/reason-codes.json",
        "profiles/core-en.json",
        "profiles/india.json",
        "profiles/persistence-policy.json",
    ]

    static func verify(in hostBundle: Bundle = .main) throws -> SmsContractBundle {
        let manifestData = try loadData(forRelativePath: "release-manifest.json", in: hostBundle)
        let manifestDigest = sha256(manifestData)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw SmsContractAssetError.configurationIntegrityFailure
        }
        guard
            manifest.contract == "pocketfinancer.contract-release-manifest/1",
            manifest.releaseID == releaseID,
            manifest.duplicateWindowMilliseconds == duplicateWindowMilliseconds,
            manifest.routingPolicy.policyContract == "pocketfinancer.persistence-policy/1",
            manifest.routingPolicy.processingConfigContract == releaseID,
            manifest.routingPolicy.reviewContract == "pocketfinancer.review-case/2",
            manifest.routingPolicy.processingResultContract == "pocketfinancer.processing-result/3",
            manifest.routingPolicy.completePosted == "transactions",
            manifest.routingPolicy.exception == "review",
            manifest.routingPolicy.duplicate == "review",
            manifest.routingPolicy.validNone == "tombstoned_none",
            manifest.routingPolicy.prefilterExcluded == "tombstoned_excluded",
            manifest.runtimePolicy.generationMode == "DIRECT_NON_THINKING",
            manifest.runtimePolicy.decoding == "greedy",
            manifest.runtimePolicy.answerTokenLimit == 512,
            manifest.runtimePolicy.rawOutputUTF8ByteLimit == 16_384,
            manifest.runtimePolicy.parserDeadlineMilliseconds == 0,
            manifest.runtimePolicy.claimLeaseMilliseconds == 120_000,
            manifest.runtimePolicy.claimHeartbeatMilliseconds == 15_000,
            manifest.runtimePolicy.automaticRetryLimit == 3
        else {
            throw SmsContractAssetError.configurationIntegrityFailure
        }

        var artifactsByPath: [String: SmsContractArtifact] = [:]
        for artifact in manifest.artifacts {
            guard
                !artifact.contract.isEmpty,
                isSafeRelativePath(artifact.path),
                artifact.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                artifactsByPath.updateValue(artifact, forKey: artifact.path) == nil
            else {
                throw SmsContractAssetError.configurationIntegrityFailure
            }
        }

        for path in requiredIOSAssetPaths {
            guard let expected = artifactsByPath[path] else {
                throw SmsContractAssetError.configurationIntegrityFailure
            }
            let data = try loadData(forRelativePath: path, in: hostBundle)
            guard sha256(data) == expected.sha256 else {
                throw SmsContractAssetError.configurationIntegrityFailure
            }
        }

        return SmsContractBundle(
            releaseID: manifest.releaseID,
            manifestSHA256: manifestDigest,
            duplicateWindowMilliseconds: manifest.duplicateWindowMilliseconds,
            artifactsByPath: artifactsByPath
        )
    }

    static func extractorPrompt(in hostBundle: Bundle = .main) throws -> String {
        _ = try verify(in: hostBundle)
        return try loadText(forRelativePath: "prompts/apple-fm-sms-extractor.txt", in: hostBundle)
    }

    static func appleFlatSchema(in hostBundle: Bundle = .main) throws -> [String: Any] {
        _ = try verify(in: hostBundle)
        return try loadJSON(forRelativePath: "schemas/apple-fm-flat.schema.json", in: hostBundle)
    }

    static func profileJSON(named name: String, in hostBundle: Bundle = .main) throws -> [String: Any] {
        _ = try verify(in: hostBundle)
        return try loadJSON(forRelativePath: "profiles/\(name).json", in: hostBundle)
    }

    static func currentISO4217CurrencyCodes(in hostBundle: Bundle = .main) throws -> Set<String> {
        let currency = try profileJSON(named: "currency", in: hostBundle)
        guard let codes = currency["current_codes"] as? [String], !codes.isEmpty else {
            throw SmsContractAssetError.configurationIntegrityFailure
        }
        return Set(codes.map { $0.uppercased() })
    }

    static func loadData(forRelativePath relativePath: String, in hostBundle: Bundle = .main) throws -> Data {
        guard isSafeRelativePath(relativePath),
            let url = resourceURL(forRelativePath: relativePath, in: hostBundle),
            let data = try? Data(contentsOf: url)
        else {
            throw SmsContractAssetError.configurationIntegrityFailure
        }
        return data
    }

    static func loadText(forRelativePath relativePath: String, in hostBundle: Bundle = .main) throws -> String {
        let data = try loadData(forRelativePath: relativePath, in: hostBundle)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SmsContractAssetError.configurationIntegrityFailure
        }
        return text
    }

    static func loadJSON(
        forRelativePath relativePath: String,
        in hostBundle: Bundle = .main
    ) throws -> [String: Any] {
        let data = try loadData(forRelativePath: relativePath, in: hostBundle)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmsContractAssetError.configurationIntegrityFailure
        }
        return object
    }

    private static func resourceURL(forRelativePath relativePath: String, in hostBundle: Bundle) -> URL? {
        let nsPath = relativePath as NSString
        let directory = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent as NSString
        let stem = fileName.deletingPathExtension
        let ext = fileName.pathExtension
        let extensionValue: String? = ext.isEmpty ? nil : ext

        let smsSubdir = directory.isEmpty ? "SmsProcessing" : "SmsProcessing/\(directory)"
        if let url = hostBundle.url(forResource: stem, withExtension: extensionValue, subdirectory: smsSubdir) {
            return url
        }
        if let url = hostBundle.url(
            forResource: stem,
            withExtension: extensionValue,
            subdirectory: "SmsProcessing"
        ) {
            return url
        }
        if !directory.isEmpty,
            let url = hostBundle.url(forResource: stem, withExtension: extensionValue, subdirectory: directory)
        {
            return url
        }
        return hostBundle.url(forResource: stem, withExtension: extensionValue)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
        let contract: String
        let releaseID: String
        let duplicateWindowMilliseconds: Int64
        let routingPolicy: RoutingPolicy
        let runtimePolicy: RuntimePolicy
        let artifacts: [SmsContractArtifact]

        enum CodingKeys: String, CodingKey {
            case contract
            case releaseID = "release_id"
            case duplicateWindowMilliseconds = "duplicate_window_ms"
            case routingPolicy = "routing_policy"
            case runtimePolicy = "runtime_policy"
            case artifacts
        }
    }

    private struct RoutingPolicy: Decodable {
        let policyContract: String
        let processingConfigContract: String
        let reviewContract: String
        let processingResultContract: String
        let completePosted: String
        let exception: String
        let duplicate: String
        let validNone: String
        let prefilterExcluded: String

        enum CodingKeys: String, CodingKey {
            case policyContract = "policy_contract"
            case processingConfigContract = "processing_config_contract"
            case reviewContract = "review_contract"
            case processingResultContract = "processing_result_contract"
            case completePosted = "complete_posted"
            case exception
            case duplicate
            case validNone = "valid_none"
            case prefilterExcluded = "prefilter_excluded"
        }
    }

    private struct RuntimePolicy: Decodable {
        let generationMode: String
        let decoding: String
        let answerTokenLimit: Int
        let rawOutputUTF8ByteLimit: Int
        let parserDeadlineMilliseconds: Int
        let claimLeaseMilliseconds: Int
        let claimHeartbeatMilliseconds: Int
        let automaticRetryLimit: Int

        enum CodingKeys: String, CodingKey {
            case generationMode = "generation_mode"
            case decoding
            case answerTokenLimit = "answer_token_limit"
            case rawOutputUTF8ByteLimit = "raw_output_utf8_byte_limit"
            case parserDeadlineMilliseconds = "parser_deadline_ms"
            case claimLeaseMilliseconds = "claim_lease_ms"
            case claimHeartbeatMilliseconds = "claim_heartbeat_ms"
            case automaticRetryLimit = "automatic_retry_limit"
        }
    }
}
