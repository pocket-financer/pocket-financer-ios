import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Guided flat extraction payload and deterministic canonical `sms-extractor/1` projection.
nonisolated struct FlatSmsExtraction: Codable, Equatable, Sendable {
    let decision: String
    let amountValue: String
    let amountCurrency: String
    let amountStart: Int
    let amountEnd: Int
    let amountText: String
    let directionValue: String
    let directionStart: Int
    let directionEnd: Int
    let directionText: String
    let accountReference: String
    let accountStart: Int
    let accountEnd: Int
    let accountText: String
    let counterpartyValue: String
    let counterpartyStart: Int
    let counterpartyEnd: Int
    let counterpartyText: String

    init(
        decision: String,
        amountValue: String = "",
        amountCurrency: String = "",
        amountStart: Int = 0,
        amountEnd: Int = 0,
        amountText: String = "",
        directionValue: String = "",
        directionStart: Int = 0,
        directionEnd: Int = 0,
        directionText: String = "",
        accountReference: String = "",
        accountStart: Int = 0,
        accountEnd: Int = 0,
        accountText: String = "",
        counterpartyValue: String = "",
        counterpartyStart: Int = 0,
        counterpartyEnd: Int = 0,
        counterpartyText: String = ""
    ) {
        self.decision = decision
        self.amountValue = amountValue
        self.amountCurrency = amountCurrency
        self.amountStart = amountStart
        self.amountEnd = amountEnd
        self.amountText = amountText
        self.directionValue = directionValue
        self.directionStart = directionStart
        self.directionEnd = directionEnd
        self.directionText = directionText
        self.accountReference = accountReference
        self.accountStart = accountStart
        self.accountEnd = accountEnd
        self.accountText = accountText
        self.counterpartyValue = counterpartyValue
        self.counterpartyStart = counterpartyStart
        self.counterpartyEnd = counterpartyEnd
        self.counterpartyText = counterpartyText
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case amountValue = "amount_value"
        case amountCurrency = "amount_currency"
        case amountStart = "amount_start"
        case amountEnd = "amount_end"
        case amountText = "amount_text"
        case directionValue = "direction_value"
        case directionStart = "direction_start"
        case directionEnd = "direction_end"
        case directionText = "direction_text"
        case accountReference = "account_reference"
        case accountStart = "account_start"
        case accountEnd = "account_end"
        case accountText = "account_text"
        case counterpartyValue = "counterparty_value"
        case counterpartyStart = "counterparty_start"
        case counterpartyEnd = "counterparty_end"
        case counterpartyText = "counterparty_text"
    }
}

nonisolated protocol FoundationSmsExtracting: Sendable {
    func extract(requestJSON: String) async throws -> DirectSelectorResponse
}

nonisolated enum SmsFlatExtractionProjector {
    static let runtimeProfileJSON =
        #"{"answer_token_limit":512,"deadline_ms":0,"decoding":"greedy","#
        + #""generation_mode":"DIRECT_NON_THINKING","raw_output_utf8_byte_limit":16384,"#
        + #""runtime":"Apple Foundation Models","wire_transport":"apple_fm_guided_flat"}"#

    static func projectFlatExtraction(_ flat: FlatSmsExtraction) throws -> String {
        switch flat.decision {
        case "none", "abstain":
            let hasExtraFields =
                !flat.amountValue.isEmpty
                || !flat.amountCurrency.isEmpty
                || flat.amountStart != 0
                || flat.amountEnd != 0
                || !flat.amountText.isEmpty
                || !flat.directionValue.isEmpty
                || flat.directionStart != 0
                || flat.directionEnd != 0
                || !flat.directionText.isEmpty
                || !flat.accountReference.isEmpty
                || flat.accountStart != 0
                || flat.accountEnd != 0
                || !flat.accountText.isEmpty
                || !flat.counterpartyValue.isEmpty
                || flat.counterpartyStart != 0
                || flat.counterpartyEnd != 0
                || !flat.counterpartyText.isEmpty
            guard !hasExtraFields else {
                throw SmsExtractorValidationError.nonPostedExtraFields
            }
            return try SmsProcessingJSON.canonical(["decision": flat.decision])
        case "posted":
            let counterpartyEmpty =
                flat.counterpartyValue.isEmpty
                && flat.counterpartyText.isEmpty
                && flat.counterpartyStart == 0
                && flat.counterpartyEnd == 0
            let counterparty: Any =
                counterpartyEmpty
                ? NSNull()
                : [
                    "value": flat.counterpartyValue,
                    "evidence": [
                        "start_scalar": flat.counterpartyStart,
                        "end_scalar": flat.counterpartyEnd,
                        "text": flat.counterpartyText,
                    ] as [String: Any],
                ]
            let payload: [String: Any] = [
                "decision": "posted",
                "amount": [
                    "value": flat.amountValue,
                    "currency": flat.amountCurrency,
                    "evidence": [
                        "start_scalar": flat.amountStart,
                        "end_scalar": flat.amountEnd,
                        "text": flat.amountText,
                    ] as [String: Any],
                ] as [String: Any],
                "direction": [
                    "value": flat.directionValue,
                    "evidence": [
                        "start_scalar": flat.directionStart,
                        "end_scalar": flat.directionEnd,
                        "text": flat.directionText,
                    ] as [String: Any],
                ] as [String: Any],
                "account": [
                    "reference": flat.accountReference,
                    "evidence": [
                        "start_scalar": flat.accountStart,
                        "end_scalar": flat.accountEnd,
                        "text": flat.accountText,
                    ] as [String: Any],
                ] as [String: Any],
                "counterparty": counterparty,
            ]
            return try SmsProcessingJSON.canonical(payload)
        default:
            throw SmsExtractorValidationError.unknownDecision
        }
    }
}

#if canImport(FoundationModels)
@Generable(description: "Flat guided extraction matching apple-fm-flat.schema.json.")
nonisolated struct GeneratedSmsExtraction {
    @Guide(description: "none, abstain, or posted", .anyOf(["none", "abstain", "posted"]))
    var decision: String

    @Guide(description: "Unsigned plain decimal amount for posted, or empty string.")
    var amountValue: String

    @Guide(description: "Three-letter ISO currency code for posted, or empty string.")
    var amountCurrency: String

    @Guide(description: "Zero-based Unicode scalar start of amount evidence, or 0.")
    var amountStart: Int

    @Guide(description: "Exclusive Unicode scalar end of amount evidence, or 0.")
    var amountEnd: Int

    @Guide(description: "Exact verbatim amount evidence text, or empty string.")
    var amountText: String

    @Guide(
        description: "debit or credit for posted, or empty string.",
        .anyOf(["", "debit", "credit"])
    )
    var directionValue: String

    @Guide(description: "Zero-based Unicode scalar start of direction evidence, or 0.")
    var directionStart: Int

    @Guide(description: "Exclusive Unicode scalar end of direction evidence, or 0.")
    var directionEnd: Int

    @Guide(description: "Exact verbatim direction evidence text, or empty string.")
    var directionText: String

    @Guide(description: "Account or VPA reference for posted, or empty string.")
    var accountReference: String

    @Guide(description: "Zero-based Unicode scalar start of account evidence, or 0.")
    var accountStart: Int

    @Guide(description: "Exclusive Unicode scalar end of account evidence, or 0.")
    var accountEnd: Int

    @Guide(description: "Exact verbatim account evidence text, or empty string.")
    var accountText: String

    @Guide(description: "Counterparty name if present, or empty string.")
    var counterpartyValue: String

    @Guide(description: "Zero-based Unicode scalar start of counterparty evidence, or 0.")
    var counterpartyStart: Int

    @Guide(description: "Exclusive Unicode scalar end of counterparty evidence, or 0.")
    var counterpartyEnd: Int

    @Guide(description: "Exact verbatim counterparty evidence text, or empty string.")
    var counterpartyText: String

    func toFlatExtraction() -> FlatSmsExtraction {
        FlatSmsExtraction(
            decision: decision,
            amountValue: amountValue,
            amountCurrency: amountCurrency,
            amountStart: amountStart,
            amountEnd: amountEnd,
            amountText: amountText,
            directionValue: directionValue,
            directionStart: directionStart,
            directionEnd: directionEnd,
            directionText: directionText,
            accountReference: accountReference,
            accountStart: accountStart,
            accountEnd: accountEnd,
            accountText: accountText,
            counterpartyValue: counterpartyValue,
            counterpartyStart: counterpartyStart,
            counterpartyEnd: counterpartyEnd,
            counterpartyText: counterpartyText
        )
    }
}

/// Guided Apple Foundation Models extractor transport; host validates the projected output.
nonisolated struct FoundationSmsExtractor: FoundationSmsExtracting {
    static let runtimeProfileJSON = SmsFlatExtractionProjector.runtimeProfileJSON

    private let model: SystemLanguageModel
    private let processingLocale: Locale

    init(
        model: SystemLanguageModel = .default,
        processingLocale: Locale = ModelDiagnostics.modelProcessingLocale
    ) {
        self.model = model
        self.processingLocale = processingLocale
    }

    static func projectFlatExtraction(_ flat: FlatSmsExtraction) throws -> String {
        try SmsFlatExtractionProjector.projectFlatExtraction(flat)
    }

    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw TransactionParserError.modelUnavailable(Self.map(reason))
        }
        guard model.supportsLocale(processingLocale) else {
            throw TransactionParserError.unsupportedLanguageOrLocale
        }
        let instructions = try Self.instructions()
        let session = LanguageModelSession(model: model) { instructions }
        do {
            return try await FoundationModelExecutionGate.shared.withPermit {
                let response = try await session.respond(
                    to: requestJSON,
                    generating: GeneratedSmsExtraction.self,
                    options: GenerationOptions(
                        sampling: .greedy,
                        maximumResponseTokens: 512
                    )
                )
                let rawOutput = try Self.projectFlatExtraction(response.content.toFlatExtraction())
                return DirectSelectorResponse(
                    rawOutput: rawOutput,
                    runtimeProfileJSON: Self.runtimeProfileJSON,
                    requestJSON: requestJSON,
                    completion: response.rawContent.isComplete ? "complete" : "incomplete"
                )
            }
        } catch let error as TransactionParserError {
            throw error
        } catch let error as SmsExtractorValidationError {
            throw error
        } catch is CancellationError {
            throw TransactionParserError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapGenerationError(error)
        } catch {
            throw TransactionParserError.generationFailed
        }
    }

    static func instructions() throws -> String {
        try SmsContractAssets.extractorPrompt()
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> ModelUnavailabilityReason {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .unknown
        }
    }

    private static func mapGenerationError(
        _ error: LanguageModelSession.GenerationError
    ) -> TransactionParserError {
        switch error {
        case .exceededContextWindowSize: .contextWindowExceeded
        case .assetsUnavailable: .assetsUnavailable
        case .guardrailViolation: .guardrailViolation
        case .unsupportedGuide: .unsupportedGuide
        case .unsupportedLanguageOrLocale: .unsupportedLanguageOrLocale
        case .decodingFailure: .decodingFailure
        case .rateLimited: .rateLimited
        case .concurrentRequests: .concurrentRequests
        case .refusal: .modelRefused
        @unknown default: .generationFailed
        }
    }
}
#else
nonisolated struct FoundationSmsExtractor: FoundationSmsExtracting {
    static let runtimeProfileJSON = SmsFlatExtractionProjector.runtimeProfileJSON

    static func projectFlatExtraction(_ flat: FlatSmsExtraction) throws -> String {
        try SmsFlatExtractionProjector.projectFlatExtraction(flat)
    }

    static func instructions() throws -> String {
        try SmsContractAssets.extractorPrompt()
    }

    func extract(requestJSON _: String) async throws -> DirectSelectorResponse {
        throw TransactionParserError.modelUnavailable(.deviceNotEligible)
    }
}
#endif
