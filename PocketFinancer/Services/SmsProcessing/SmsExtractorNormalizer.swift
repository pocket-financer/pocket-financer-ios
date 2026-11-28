import Foundation

nonisolated enum SmsExtractorNormalizer {
    static let explicitDebitDirectionCues = [
        "debit",
        "debited",
        "deducted",
        "withdrawn",
        "spent",
        "paid",
        "charged",
        "sent",
        "purchase",
        "purchased",
        "autopaid",
        "without otp",
        "dr",
        "used",
    ]

    static let neutralDebitDirectionCues = [
        "txn",
        "transaction",
        "payment",
        "transfer",
        "transferred",
    ]

    static let debitDirectionCues = explicitDebitDirectionCues + neutralDebitDirectionCues

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
        let normalized = normalizeText(value)
        if let range = normalized.range(
            of: #"[a-z0-9][a-z0-9._-]{1,}@[a-z0-9][a-z0-9.-]+"#,
            options: .regularExpression
        ) {
            return String(normalized[range])
        }
        let values = normalized.matches(of: /(?:[xX*•-]{2,}\s*)?[0-9]{3,8}/)
        guard values.count == 1 else { return nil }
        let digits = values[0].output.filter { $0.isASCII && $0.isNumber }
        return (3...8).contains(digits.count) ? String(digits) : nil
    }

    static func normalizeCounterparty(_ value: String) -> String? {
        let result = normalizeText(value)
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
        let rawNumber = String(normalized[valueRange]).replacingOccurrences(of: ",", with: "")
        let canonical = canonicalEvidenceDecimal(rawNumber)
        guard
            let parsed = CurrencyProfileRegistry.parse(
                number: canonical,
                currency: currency,
                provenance: "extractor_evidence"
            )
        else { throw SmsExtractorValidationError.amountInvalid }
        return parsed.minorUnits
    }

    static func directionGrounded(direction: String, text: String) -> Bool {
        let cues: [String]
        switch direction {
        case "debit":
            cues = debitDirectionCues
        case "credit":
            cues = creditDirectionCues
        default:
            return false
        }
        let normalized = normalizeText(text)
        return matchesAnyCue(cues, in: normalized)
    }

    static func isDirectionGrounded(_ direction: String, in evidence: String) -> Bool {
        directionGrounded(direction: direction, text: evidence)
    }

    static func inferredDirection(from text: String) -> String? {
        let normalized = normalizeText(text)
        let hasExplicitDebit = matchesAnyCue(explicitDebitDirectionCues, in: normalized)
        if hasExplicitDebit {
            return "debit"
        }
        let withoutCreditCard = normalized.replacingOccurrences(
            of: #"\bcredit\s+cards?\b"#,
            with: " ",
            options: .regularExpression
        )
        if matchesAnyCue(creditDirectionCues, in: withoutCreditCard) {
            return "credit"
        }
        if matchesAnyCue(neutralDebitDirectionCues, in: normalized) {
            return "debit"
        }
        if matchesAnyCue(creditDirectionCues, in: normalized) {
            return "credit"
        }
        return nil
    }

    static func supportedDirections(for text: String) -> [String] {
        var directions: [String] = []
        if let preferred = inferredDirection(from: text),
            directionGrounded(direction: preferred, text: text)
        {
            directions.append(preferred)
        }
        for candidate in ["debit", "credit"] where !directions.contains(candidate) {
            if directionGrounded(direction: candidate, text: text) {
                directions.append(candidate)
            }
        }
        return directions
    }

    static func direction(_ value: String) -> String? {
        inferredDirection(from: value)
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

    private static func matchesAnyCue(_ cues: [String], in normalized: String) -> Bool {
        cues.contains {
            normalized.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func canonicalEvidenceDecimal(_ number: String) -> String {
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2 else { return number }
        let strippedWhole = parts[0].drop(while: { $0 == "0" })
        let whole = strippedWhole.isEmpty ? "0" : String(strippedWhole)
        if parts.count == 2 {
            return "\(whole).\(parts[1])"
        }
        return whole
    }
}
