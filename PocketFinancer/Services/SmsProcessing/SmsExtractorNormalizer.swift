import Foundation

nonisolated enum SmsExtractorNormalizer {
    static func normalizeAccount(_ value: String) -> String? {
        let s = frozenCaseFold(
            value.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let range = s.range(
            of: #"[a-z0-9][a-z0-9._-]{1,}@[a-z0-9][a-z0-9.-]+"#,
            options: .regularExpression
        ) {
            return String(s[range])
        }
        let values = s.matches(of: /(?:[xX*•-]{2,}\s*)?\d{3,8}/)
        guard values.count == 1 else { return nil }
        let digits = values[0].output.filter(\.isNumber)
        return (3...8).contains(digits.count) ? digits : nil
    }

    static func normalizeCounterparty(_ value: String) -> String? {
        let result = frozenCaseFold(
            value.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !result.isEmpty && result.unicodeScalars.count <= 256 ? result : nil
    }

    static func minorUnits(decimal: String, currency: String) throws -> Int64 {
        guard decimal.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw SmsExtractorValidationError.amountInvalid
        }
        guard
            let parsed = CurrencyProfileRegistry.parse(
                number: decimal, currency: currency, provenance: "extractor_explicit_currency"
            )
        else { throw SmsExtractorValidationError.amountInvalid }
        return parsed.minorUnits
    }

    static func minorUnits(evidenceText: String, currency: String) throws -> Int64 {
        let normalized = evidenceText.precomposedStringWithCompatibilityMapping
        let expression =
            #"(?<![\w,])(?:[0-9]{1,3}(?:,[0-9]{2})+,[0-9]{3}|[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?(?![\w,])"#
        let regex = try NSRegularExpression(pattern: expression)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, range: range)
        guard matches.count == 1,
            let valueRange = Range(matches[0].range, in: normalized)
        else { throw SmsExtractorValidationError.amountInvalid }
        return try minorUnits(
            decimal: String(normalized[valueRange]).replacingOccurrences(of: ",", with: ""), currency: currency)
    }

    static func direction(_ value: String) -> String? {
        let normalized = normalizeText(value)
        let debit = ["debit", "debited", "deducted", "withdrawn", "spent", "paid", "charged"]
        let credit = ["credit", "credited", "deposited", "received", "refunded"]
        if debit.contains(where: {
            normalized.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil
        }) {
            return "debit"
        }
        if credit.contains(where: {
            normalized.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil
        }) {
            return "credit"
        }
        return nil
    }

    static func normalizeText(_ value: String) -> String {
        frozenCaseFold(
            value.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func frozenCaseFold(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            var mapped = String(scalar).lowercased()
            if mapped == "ß" { mapped = "ss" }
            if mapped == "ς" { mapped = "σ" }
            result.append(contentsOf: mapped)
        }
        return result
    }
}
