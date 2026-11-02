import Foundation
import FoundationModels

/// Direct v4 transport. The host always validates the serialized wire output.
protocol FoundationSmsExtracting: Sendable {
    func extract(requestJSON: String) async throws -> DirectSelectorResponse
}

struct FoundationSmsExtractor: FoundationSmsExtracting {
    private let model: SystemLanguageModel
    init(model: SystemLanguageModel = .default) { self.model = model }

    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        guard case .available = model.availability else {
            throw TransactionParserError.modelUnavailable(.modelNotReady)
        }
        let instructions = try Self.instructions()
        let session = LanguageModelSession(model: model) { instructions }
        return try await FoundationModelExecutionGate.shared.withPermit {
            let response = try await session.respond(
                to: requestJSON,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: 512
                )
            )
            return DirectSelectorResponse(
                rawOutput: response.content, runtimeProfileJSON: Self.runtimeProfileJSON, requestJSON: requestJSON,
                completion: response.rawContent.isComplete ? "complete" : "incomplete")
        }
    }

    static func instructions() throws -> String {
        guard let bundleURL = Bundle.main.url(forResource: "NativeSmsV4", withExtension: "bundle"),
            let bundle = Bundle(url: bundleURL),
            let url = bundle.url(
                forResource: "sms-extractor-v1", withExtension: "txt",
                subdirectory: "configs/sms_processing/prompts"
            ),
            let value = try? String(contentsOf: url, encoding: .utf8)
        else { throw SmsProcessingStoreError.configurationMismatch }
        return value
    }
    private nonisolated static let runtimeProfileJSON =
        #"{"generation_mode":"DIRECT_NON_THINKING","decoding":"greedy","answer_token_limit":512,"raw_output_utf8_byte_limit":16384,"deadline_ms":0,"runtime":"Apple Foundation Models","wire_transport":"raw_text"}"#
}
