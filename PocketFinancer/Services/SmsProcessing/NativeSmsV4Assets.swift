import CryptoKit
import Foundation

/// Exact v4 bundle binding. Kept separate from frozen v3 resources.
nonisolated enum NativeSmsV4Assets {
    static let releaseID = "native-integration-v4"
    static let manifestSHA256 = "0d3bf18f91d0a197c7bb56b5e082fd2851ce072f854452a9647c52d45b3433d8"
    static let processingConfigSHA256 = "257405f8cff35db2131dc2325388cc9845cb1e62775b5df1b45c321908642406"

    static func verify(in hostBundle: Bundle = .main) throws -> NativeSmsV3AssetBinding {
        guard let url = hostBundle.url(forResource: "NativeSmsV4", withExtension: "bundle"),
            let bundle = Bundle(url: url), let root = bundle.resourceURL
        else {
            throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
        }
        let manifestURL = root.appendingPathComponent(
            "configs/sms_processing/contracts/releases/native-integration-v4.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch {
            throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
        }
        guard hash(data) == manifestSHA256,
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            manifest["release_id"] as? String == releaseID,
            let artifacts = manifest["artifacts"] as? [[String: String]]
        else {
            throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
        }
        var result: [String: NativeSmsV3Artifact] = [:]
        for item in artifacts {
            guard let contract = item["contract"], let path = item["path"], let digest = item["sha256"],
                !path.contains(".."),
                path.hasPrefix("configs/sms_processing/") || path.hasPrefix("tests/sms_processing/"),
                result[contract] == nil,
                hash((try? Data(contentsOf: root.appendingPathComponent(path))) ?? Data()) == digest
            else {
                throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
            }
            result[contract] = NativeSmsV3Artifact(contract: contract, path: path, sha256: digest)
        }
        guard result["pocketfinancer.processing-config/4"]?.sha256 == processingConfigSHA256 else {
            throw NativeSmsV3AssetIntegrityError.configurationIntegrityFailure
        }
        return NativeSmsV3AssetBinding(
            releaseID: releaseID, manifestSHA256: manifestSHA256, artifactsByContract: result)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
