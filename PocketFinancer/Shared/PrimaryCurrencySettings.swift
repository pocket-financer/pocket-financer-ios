import Foundation

enum PrimaryCurrencySettings {
    nonisolated static let key = "primaryCurrencyCode"
    nonisolated static let confirmationKey = "primaryCurrencyConfirmed"
    nonisolated static let supportedCodes = [
        "AED", "AUD", "CAD", "CHF", "EUR", "GBP", "INR", "JPY", "SGD", "USD",
    ]

    nonisolated static var currentCode: String {
        let stored = UserDefaults.standard.string(forKey: key)?.uppercased()
        return supportedCodes.contains(stored ?? "") ? stored! : "INR"
    }

    nonisolated static var confirmedCode: String? {
        guard UserDefaults.standard.bool(forKey: confirmationKey) else { return nil }
        let stored = UserDefaults.standard.string(forKey: key)?.uppercased()
        guard let stored, supportedCodes.contains(stored) else { return nil }
        return stored
    }

    nonisolated static func confirm(_ code: String) {
        let normalized = code.uppercased()
        guard supportedCodes.contains(normalized) else { return }
        UserDefaults.standard.set(normalized, forKey: key)
        UserDefaults.standard.set(true, forKey: confirmationKey)
    }

    nonisolated static var enabledProfiles: [String] {
        currentCode == "INR" ? ["core-en", "india"] : ["core-en"]
    }
}
