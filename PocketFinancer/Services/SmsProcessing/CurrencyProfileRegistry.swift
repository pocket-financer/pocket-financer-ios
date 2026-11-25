import Foundation

struct SmsParsedMoney: Equatable, Sendable {
    let minorUnits: Int64
    let currency: String
    let scale: Int
    let provenance: String
}

enum CurrencyProfileRegistry {
    nonisolated static let scales: [String: Int] = [
        "AED": 2, "AUD": 2, "CAD": 2, "CHF": 2, "EUR": 2,
        "GBP": 2, "INR": 2, "JPY": 0, "SGD": 2, "USD": 2,
    ]

    nonisolated static func parse(
        number: String,
        currency: String,
        provenance: String
    ) -> SmsParsedMoney? {
        let code = currency.uppercased()
        guard let scale = scales[code] else { return nil }
        let normalized = number.replacingOccurrences(of: ",", with: "")
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let whole = Int64(pieces[0]), whole >= 0 else { return nil }
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard fraction.count <= scale, fraction.allSatisfy(\.isNumber) else { return nil }
        let padded = fraction + String(repeating: "0", count: scale - fraction.count)
        guard let multiplier = powerOfTen(scale),
            whole <= Int64.max / multiplier,
            let fractional = padded.isEmpty ? 0 : Int64(padded),
            whole * multiplier <= Int64.max - fractional
        else { return nil }
        let result = whole * multiplier + fractional
        guard result > 0 else { return nil }
        return SmsParsedMoney(
            minorUnits: result,
            currency: code,
            scale: scale,
            provenance: provenance
        )
    }

    private nonisolated static func powerOfTen(_ scale: Int) -> Int64? {
        (0..<scale).reduce(Optional(Int64(1))) { value, _ in
            value.flatMap { $0 <= Int64.max / 10 ? $0 * 10 : nil }
        }
    }
}
