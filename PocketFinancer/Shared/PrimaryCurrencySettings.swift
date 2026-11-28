import Foundation
import SwiftUI

struct PrimaryCurrencySnapshot: Equatable, Hashable, Sendable {
    let currentCode: String
    let confirmedCode: String?

    nonisolated var isConfirmed: Bool { confirmedCode != nil }
    nonisolated var enabledProfiles: [String] { PrimaryCurrencySettings.enabledProfiles(for: currentCode) }
}

enum PrimaryCurrencySettings {
    nonisolated static let key = "primaryCurrencyCode"
    nonisolated static let confirmationKey = "primaryCurrencyConfirmed"
    nonisolated static let defaultCode = "INR"
    nonisolated static let supportedCodes = [
        "AED", "AUD", "CAD", "CHF", "EUR", "GBP", "INR", "JPY", "SGD", "USD",
    ]

    nonisolated static func normalizedSupportedCode(_ rawCode: String?) -> String? {
        guard
            let normalized = rawCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            supportedCodes.contains(normalized)
        else { return nil }
        return normalized
    }

    nonisolated static func snapshot(
        storedCode: String?,
        isConfirmed: Bool
    ) -> PrimaryCurrencySnapshot {
        let validStored = normalizedSupportedCode(storedCode)
        let currentCode = validStored ?? defaultCode
        let confirmedCode = isConfirmed ? validStored : nil
        return PrimaryCurrencySnapshot(currentCode: currentCode, confirmedCode: confirmedCode)
    }

    nonisolated static func snapshot(in defaults: UserDefaults = .standard) -> PrimaryCurrencySnapshot {
        snapshot(
            storedCode: defaults.string(forKey: key),
            isConfirmed: defaults.bool(forKey: confirmationKey)
        )
    }

    nonisolated static var currentCode: String { snapshot().currentCode }

    nonisolated static var confirmedCode: String? { snapshot().confirmedCode }

    nonisolated static var isConfirmed: Bool { confirmedCode != nil }

    nonisolated static func confirm(_ code: String, in defaults: UserDefaults = .standard) {
        guard let normalized = normalizedSupportedCode(code) else { return }
        defaults.set(normalized, forKey: key)
        defaults.set(true, forKey: confirmationKey)
    }

    nonisolated static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: confirmationKey)
    }

    nonisolated static func enabledProfiles(for code: String) -> [String] {
        normalizedSupportedCode(code) == "INR" ? ["core-en", "india"] : ["core-en"]
    }

    nonisolated static var enabledProfiles: [String] { enabledProfiles(for: currentCode) }
}

@propertyWrapper
struct PrimaryCurrencyState: DynamicProperty {
    @AppStorage(PrimaryCurrencySettings.key) private var storedCode: String?
    @AppStorage(PrimaryCurrencySettings.confirmationKey) private var isConfirmed = false

    var wrappedValue: PrimaryCurrencySnapshot {
        PrimaryCurrencySettings.snapshot(
            storedCode: storedCode,
            isConfirmed: isConfirmed
        )
    }

    var projectedValue: Self { self }

    func confirm(_ code: String) {
        PrimaryCurrencySettings.confirm(code)
    }
}
