import Foundation
import FoundationModels

struct DirectSelectorResponse: Equatable, Sendable {
    let rawOutput: String
    let runtimeProfileJSON: String
    let requestJSON: String
    let completion: String
}

protocol DirectCandidateSelecting: Sendable {
    func select(source: String, analysis: SmsAnalysis) async throws -> DirectSelectorResponse
}

@Generable
private enum GeneratedSelectorDecision {
    case none
    case abstain
    case posted
}

@Generable(description: "Select only candidate IDs supplied by the host")
private struct GeneratedCandidateSelection {
    var decision: GeneratedSelectorDecision
    var amount: String?
    var direction: String?
    var account: String?
    var counterparty: String?
}

struct FoundationDirectCandidateSelector: DirectCandidateSelecting {
    private let model: SystemLanguageModel
    private let locale: Locale

    nonisolated init(
        model: SystemLanguageModel = .default,
        locale: Locale = Locale(identifier: "en-US")
    ) {
        self.model = model
        self.locale = locale
    }

    func select(source: String, analysis: SmsAnalysis) async throws -> DirectSelectorResponse {
        guard case .available = model.availability else {
            throw TransactionParserError.modelUnavailable(.modelNotReady)
        }
        guard model.supportsLocale(locale) else {
            throw TransactionParserError.unsupportedLanguageOrLocale
        }
        let session = LanguageModelSession(model: model) {
            Self.selectorInstructions
        }
        let request = try Self.requestJSON(source: source, analysis: analysis)
        return try await FoundationModelExecutionGate.shared.withPermit {
            let response = try await session.respond(
                to: request,
                generating: GeneratedCandidateSelection.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return DirectSelectorResponse(
                rawOutput: response.rawContent.jsonString,
                runtimeProfileJSON: Self.runtimeProfileJSON,
                requestJSON: request,
                completion: response.rawContent.isComplete ? "complete" : "incomplete"
            )
        }
    }

    nonisolated static var selectorInstructions: String {
        let url =
            Bundle.main.url(
                forResource: "selector-prompt-v1", withExtension: "txt", subdirectory: "SmsProcessing"
            ) ?? Bundle.main.url(forResource: "selector-prompt-v1", withExtension: "txt")
        if let url, let value = try? String(contentsOf: url, encoding: .utf8) {
            return value
        }
        return "Pinned selector instructions are unavailable. Return {\"decision\":\"abstain\"}."
    }

    private nonisolated static let runtimeProfileJSON =
        #"{"generation_mode":"DIRECT_NON_THINKING","decoding":"greedy","answer_token_limit":512,"raw_output_utf8_byte_limit":16384,"deadline_ms":0,"runtime":"Apple Foundation Models"}"#

    nonisolated static func requestJSON(source: String, analysis: SmsAnalysis) throws -> String {
        let candidates: [[String: Any]] = analysis.candidates.map { candidate in
            var result: [String: Any] = [
                "id": candidate.id,
                "kind": candidate.kind.rawValue,
                "absent": candidate.explicitlyAbsent,
                "clause": candidate.clauseID as Any? ?? NSNull(),
            ]
            if let evidence = candidate.evidence { result["evidence"] = evidence.text }
            if let direction = candidate.value["direction"] { result["direction"] = direction }
            return result
        }
        let payload: [String: Any] = [
            "contract": "pocketfinancer.grounded-candidate-selector-input/1",
            "analysis_id": analysis.analysisID,
            "message": source,
            "candidates": candidates,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

struct UnavailableDirectCandidateSelector: DirectCandidateSelecting {
    func select(source _: String, analysis _: SmsAnalysis) async throws -> DirectSelectorResponse {
        throw TransactionParserError.modelUnavailable(.modelNotReady)
    }
}
