import Foundation

enum CurrencyFormatter {
    nonisolated static let supportedScales: [String: Int] = [
        "AED": 2,
        "AUD": 2,
        "CAD": 2,
        "CHF": 2,
        "EUR": 2,
        "GBP": 2,
        "INR": 2,
        "JPY": 0,
        "SGD": 2,
        "USD": 2,
    ]

    static func string(minorUnits: Int64, currencyCode: String) -> String {
        string(minorUnits: Decimal(minorUnits), currencyCode: currencyCode)
    }

    static func string(minorUnits: Decimal, currencyCode: String) -> String {
        let normalizedCode = currencyCode.uppercased()
        let scale = supportedScales[normalizedCode] ?? 2
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = normalizedCode
        formatter.locale = Locale(identifier: normalizedCode == "INR" ? "en_IN" : Locale.current.identifier)
        formatter.maximumFractionDigits = scale
        formatter.minimumFractionDigits = scale
        let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(scale), isNegative: false)
        let amount = NSDecimalNumber(decimal: minorUnits).dividing(by: divisor)
        return formatter.string(from: amount) ?? "\(normalizedCode) \(amount)"
    }

    static func minorUnits(
        fromMajorUnitText text: String,
        currencyCode: String,
        locale: Locale = .current
    ) -> Int64? {
        let normalizedCode = currencyCode.uppercased()
        guard let scale = supportedScales[normalizedCode] else { return nil }

        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let groupingSeparator = locale.groupingSeparator, !groupingSeparator.isEmpty {
            normalized = normalized.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if let decimalSeparator = locale.decimalSeparator, decimalSeparator != "." {
            normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        }
        let precision = scale == 0 ? #"^\d+$"# : #"^\d+(?:\.\d{1,\#(scale)})?$"#
        guard
            normalized.range(of: precision, options: .regularExpression) != nil,
            var amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
            amount > 0
        else { return nil }

        var multiplier = (0..<scale).reduce(Decimal(1)) { value, _ in value * 10 }
        var scaled = Decimal()
        NSDecimalMultiply(&scaled, &amount, &multiplier, .plain)
        var integral = Decimal()
        NSDecimalRound(&integral, &scaled, 0, .plain)
        guard integral == scaled, integral <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: integral).int64Value
    }

    static func editableMajorUnits(minorUnits: Int64, currencyCode: String) -> String {
        let scale = supportedScales[currencyCode.uppercased()] ?? 2
        let divisor = (0..<scale).reduce(Decimal(1)) { value, _ in value * 10 }
        return NSDecimalNumber(decimal: Decimal(minorUnits) / divisor).stringValue
    }
}
