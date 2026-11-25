import Foundation
import FoundationModels

struct ModelLocaleSupportProbe: Equatable, Identifiable, Sendable {
    let label: String
    let localeIdentifier: String
    /// `nil` means the locale is shown for context and is not used to gate model work.
    let isSupported: Bool?

    var id: String { label }
}

struct ModelDiagnostic: Equatable, Sendable {
    let isReady: Bool
    let title: String
    let detail: String
    let localeIdentifier: String
    let localeWasSupported: Bool
    let localeSupportProbes: [ModelLocaleSupportProbe]
    let supportedLanguageIdentifiers: [String]

    var supportedLanguageSummary: String {
        supportedLanguageIdentifiers.isEmpty
            ? "Not reported by the system model right now"
            : supportedLanguageIdentifiers.joined(separator: ", ")
    }

    var formattingLocaleIdentifier: String {
        localeSupportProbes.first { $0.isSupported == nil }?.localeIdentifier
            ?? "Not reported"
    }
}

enum ModelAvailabilityDiagnosticState: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknownUnavailable
}

enum ModelDiagnostics {
    nonisolated static let modelProcessingLocale = Locale(identifier: "en-US")

    nonisolated static var modelProcessingLocaleIdentifier: String {
        modelProcessingLocale.identifier
    }

    private final class CurrentLoadAttempt {
        let task: Task<ModelDiagnostic, Never>

        init(processingLocale: Locale, formattingLocale: Locale) {
            task = Task.detached(priority: .utility) {
                ModelDiagnostics.current(
                    processingLocale: processingLocale,
                    formattingLocale: formattingLocale
                )
            }
        }
    }

    private static var currentLoadAttempts: [String: CurrentLoadAttempt] = [:]

    nonisolated static func current(
        processingLocale: Locale = ModelDiagnostics.modelProcessingLocale,
        formattingLocale: Locale = .current
    ) -> ModelDiagnostic {
        let model = SystemLanguageModel.default
        let localeWasSupported = model.supportsLocale(processingLocale)
        return makeDiagnostic(
            availability: availabilityState(model.availability),
            localeIdentifier: processingLocale.identifier,
            localeWasSupported: localeWasSupported,
            localeSupportProbes: makeLocaleSupportProbes(
                modelLocale: processingLocale,
                modelLocaleWasSupported: localeWasSupported,
                formattingLocale: formattingLocale
            ),
            supportedLanguageIdentifiers: languageIdentifiers(model.supportedLanguages)
        )
    }

    @MainActor
    static func loadCurrent(
        processingLocale: Locale = ModelDiagnostics.modelProcessingLocale,
        formattingLocale: Locale = .current
    ) async -> ModelDiagnostic {
        let key = "\(processingLocale.identifier)|\(formattingLocale.identifier)"
        let attempt: CurrentLoadAttempt
        if let currentAttempt = currentLoadAttempts[key] {
            attempt = currentAttempt
        } else {
            attempt = CurrentLoadAttempt(
                processingLocale: processingLocale,
                formattingLocale: formattingLocale
            )
            currentLoadAttempts[key] = attempt
        }

        let diagnostic = await attempt.task.value
        if currentLoadAttempts[key] === attempt {
            currentLoadAttempts.removeValue(forKey: key)
        }
        return diagnostic
    }

    nonisolated static func loadCurrent(
        processingLocale: Locale,
        using load: @escaping @Sendable (Locale) -> ModelDiagnostic
    ) async -> ModelDiagnostic {
        await Task.detached(priority: .utility) {
            load(processingLocale)
        }.value
    }

    nonisolated static func makeLocaleSupportProbes(
        modelLocale: Locale,
        modelLocaleWasSupported: Bool,
        formattingLocale: Locale
    ) -> [ModelLocaleSupportProbe] {
        [
            ModelLocaleSupportProbe(
                label: "Model processing locale",
                localeIdentifier: modelLocale.identifier,
                isSupported: modelLocaleWasSupported
            ),
            ModelLocaleSupportProbe(
                label: "Phone formatting locale",
                localeIdentifier: formattingLocale.identifier,
                isSupported: nil
            ),
        ]
    }

    nonisolated static func languageIdentifiers(
        _ languages: Set<Locale.Language>
    ) -> [String] {
        Array(Set(languages.map(\.minimalIdentifier))).sorted()
    }

    nonisolated static func makeDiagnostic(
        availability: ModelAvailabilityDiagnosticState,
        localeIdentifier: String,
        localeWasSupported: Bool,
        localeSupportProbes: [ModelLocaleSupportProbe],
        supportedLanguageIdentifiers: [String]
    ) -> ModelDiagnostic {
        let normalizedLanguages = Array(Set(supportedLanguageIdentifiers)).sorted()

        switch availability {
        case .available where localeWasSupported:
            return ModelDiagnostic(
                isReady: true,
                title: "On-device model available",
                detail:
                    "Apple's public locale check passed for Pocket Financer's U.S. English model language. "
                    + "Your iPhone can keep its India region for dates, numbers, and currency formatting.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: true,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .available:
            return ModelDiagnostic(
                isReady: false,
                title: "Model processing language unsupported",
                detail:
                    "Apple reports Pocket Financer's U.S. English model locale as unsupported. Confirm that the "
                    + "iPhone and Siri languages use the same supported English language, then reopen the app. "
                    + "The iPhone region can remain India.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: false,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .deviceNotEligible:
            return ModelDiagnostic(
                isReady: false,
                title: "Device not eligible",
                detail:
                    "This iPhone cannot use Apple's on-device Foundation Model. "
                    + "Alerts remain available for review.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .appleIntelligenceNotEnabled:
            return ModelDiagnostic(
                isReady: false,
                title: "Apple Intelligence is off",
                detail:
                    "Enable Apple Intelligence in Settings. Also confirm that the iPhone language and Siri "
                    + "language use the same supported language before retrying.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .modelNotReady:
            return ModelDiagnostic(
                isReady: false,
                title: "Model not ready",
                detail:
                    "Apple reports only that the model is not ready; the public API does not provide download "
                    + "progress or a more specific cause. Keep the iPhone on power and Wi-Fi, then try again later.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        case .unknownUnavailable:
            return ModelDiagnostic(
                isReady: false,
                title: "Model unavailable",
                detail:
                    "Apple reported an availability state this app does not recognize. Eligible alerts stay on "
                    + "this device until local parsing is available.",
                localeIdentifier: localeIdentifier,
                localeWasSupported: localeWasSupported,
                localeSupportProbes: localeSupportProbes,
                supportedLanguageIdentifiers: normalizedLanguages
            )
        }
    }

    private nonisolated static func availabilityState(
        _ availability: SystemLanguageModel.Availability
    ) -> ModelAvailabilityDiagnosticState {
        switch availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .unknownUnavailable
        }
    }
}
