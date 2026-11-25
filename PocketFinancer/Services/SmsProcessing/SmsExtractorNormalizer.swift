import Foundation

nonisolated enum SmsExtractorNormalizer {
    static let debitDirectionCues = [
        "debit",
        "debited",
        "deducted",
        "withdrawn",
        "spent",
        "paid",
        "charged",
        "sent",
        "txn",
        "transaction",
        "payment",
        "transfer",
        "transferred",
        "purchase",
        "purchased",
        "autopaid",
        "without otp",
        "dr",
        "used",
    ]

    static let creditDirectionCues = [
        "credit",
        "credited",
        "deposited",
        "deposit",
        "received",
        "refunded",
        "refund",
        "reversed",
        "reversal",
        "cr",
        "cashback",
        "adjusted",
    ]

    static func normalizeAccount(_ value: String) -> String? {
        let normalized = frozenCaseFold(
            value.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let range = normalized.range(
            of: #"[a-z0-9][a-z0-9._-]{1,}@[a-z0-9][a-z0-9.-]+"#,
            options: .regularExpression
        ) {
            return String(normalized[range])
        }
        let values = normalized.matches(of: /(?:[xX*•-]{2,}\s*)?\d{3,8}/)
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
                number: decimal,
                currency: currency,
                provenance: "extractor_explicit_currency"
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
            decimal: String(normalized[valueRange]).replacingOccurrences(of: ",", with: ""),
            currency: currency
        )
    }

    static func direction(_ value: String) -> String? {
        if isDirectionGrounded("debit", in: value) {
            return "debit"
        }
        if isDirectionGrounded("credit", in: value) {
            return "credit"
        }
        return nil
    }

    static func isDirectionGrounded(_ direction: String, in evidence: String) -> Bool {
        let cues: [String]
        switch direction {
        case "debit":
            cues = debitDirectionCues
        case "credit":
            cues = creditDirectionCues
        default:
            return false
        }
        let normalized = normalizeText(evidence)
        return cues.contains {
            normalized.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#,
                options: .regularExpression
            ) != nil
        }
    }

    static func normalizeText(_ value: String) -> String {
        frozenCaseFold(
            value.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func frozenCaseFold(_ value: String) -> String {
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
