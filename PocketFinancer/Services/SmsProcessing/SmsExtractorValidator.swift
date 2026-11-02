import CoreFoundation
import Foundation

nonisolated struct SmsExtractorValidator {
    static let rawOutputByteLimit = 16_384

    func validate(
        rawOutput: String,
        source: String,
        primaryCurrency: String,
        enabledProfiles: [String] = ["core-en", "india"]
    ) throws -> SmsExtractorResult {
        guard rawOutput.utf8.count <= Self.rawOutputByteLimit else { throw SmsExtractorValidationError.outputTruncated }
        guard !rawOutput.isEmpty, let data = rawOutput.data(using: .utf8) else {
            throw SmsExtractorValidationError.malformedJSON
        }
        try StrictExtractorJSON.validateOneDocument(rawOutput)
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SmsExtractorValidationError.malformedJSON
        }
        guard let object = decoded as? [String: Any] else { throw SmsExtractorValidationError.outputNotObject }
        guard let rawDecision = object["decision"] as? String else {
            throw SmsExtractorValidationError.decisionTypeInvalid
        }
        guard let decision = SmsExtractorDecision(rawValue: rawDecision) else {
            throw SmsExtractorValidationError.unknownDecision
        }
        if decision != .posted {
            guard Set(object.keys) == Set(["decision"]) else { throw SmsExtractorValidationError.nonPostedExtraFields }
            return SmsExtractorResult(decision: decision, transaction: nil)
        }
        let expected: Set<String> = ["decision", "amount", "direction", "account", "counterparty"]
        guard Set(object.keys) == expected else {
            if object["amount"] == nil { throw SmsExtractorValidationError.missingAmount }
            if object["direction"] == nil { throw SmsExtractorValidationError.missingDirection }
            if object["account"] == nil { throw SmsExtractorValidationError.missingAccount }
            throw SmsExtractorValidationError.postedFieldSetInvalid
        }
        let amount = try amount(
            object["amount"], source: source, primaryCurrency: primaryCurrency,
            enabledProfiles: enabledProfiles
        )
        let direction = try direction(object["direction"], source: source)
        let account = try account(object["account"], source: source)
        let counterparty = try counterparty(object["counterparty"], source: source)
        return SmsExtractorResult(
            decision: .posted,
            transaction: SmsExtractedTransaction(
                minorUnits: amount.minor, currency: amount.currency, direction: direction.value,
                accountReference: account.value, counterparty: counterparty.value, amountSpan: amount.span,
                directionSpan: direction.span, accountSpan: account.span, counterpartySpan: counterparty.span))
    }

    private func amount(
        _ raw: Any?, source: String, primaryCurrency: String,
        enabledProfiles: [String]
    ) throws -> (minor: Int64, currency: String, span: UnicodeScalarSpan) {
        guard let value = raw as? [String: Any], Set(value.keys) == Set(["value", "currency", "evidence"]),
            let declared = value["value"] as? String, let currency = value["currency"] as? String
        else { throw SmsExtractorValidationError.amountInvalid }
        guard currency == currency.uppercased(), CurrencyProfileRegistry.scales[currency] != nil else {
            throw SmsExtractorValidationError.currencyInvalid
        }
        let span = try evidence(value["evidence"], source: source)
        let match = try onlyMoney(in: span.text)
        let grounded = try SmsExtractorNormalizer.minorUnits(
            decimal: match.replacingOccurrences(of: ",", with: ""), currency: currency)
        let declaredMinor = try SmsExtractorNormalizer.minorUnits(decimal: declared, currency: currency)
        guard grounded == declaredMinor else { throw SmsExtractorValidationError.amountValueDisagreement }
        try validateCurrencyGrounding(
            span.text, currency: currency, primaryCurrency: primaryCurrency,
            enabledProfiles: enabledProfiles
        )
        return (grounded, currency, span)
    }

    private func validateCurrencyGrounding(
        _ evidence: String,
        currency: String,
        primaryCurrency: String,
        enabledProfiles: [String]
    ) throws {
        guard !enabledProfiles.isEmpty,
            enabledProfiles.allSatisfy({ ["core-en", "india"].contains($0) })
        else { throw SmsExtractorValidationError.currencyInvalid }
        let normalized = evidence.precomposedStringWithCompatibilityMapping.lowercased()
        let codeRegex = try NSRegularExpression(pattern: #"\b[A-Za-z]{3}\b"#)
        let codeRange = NSRange(normalized.startIndex..., in: normalized)
        let supported = Set(CurrencyProfileRegistry.scales.keys)
        let codes = Set(
            codeRegex.matches(in: normalized, range: codeRange).compactMap {
                Range($0.range, in: normalized).map { String(normalized[$0]).uppercased() }
            }.filter { supported.contains($0) })
        if !codes.isEmpty, codes != Set([currency]) {
            throw SmsExtractorValidationError.currencyInvalid
        }
        var markers = Set<String>()
        if enabledProfiles.contains("core-en") {
            if normalized.contains("€") { markers.insert("EUR") }
            if normalized.contains("£") { markers.insert("GBP") }
        }
        if enabledProfiles.contains("india"),
            normalized.contains("₹")
                || normalized.range(
                    of: #"\brs\.?\b"#, options: .regularExpression
                ) != nil || normalized.range(of: #"\binr\b"#, options: .regularExpression) != nil
        {
            markers.insert("INR")
        }
        if !markers.isEmpty, markers != Set([currency]) {
            throw SmsExtractorValidationError.currencyInvalid
        }
        if codes.isEmpty, markers.isEmpty, currency != primaryCurrency {
            throw SmsExtractorValidationError.currencyInvalid
        }
    }

    private func direction(_ raw: Any?, source: String) throws -> (
        value: SmsExtractorDirection, span: UnicodeScalarSpan
    ) {
        guard let value = raw as? [String: Any], Set(value.keys) == Set(["value", "evidence"]),
            let declared = value["value"] as? String, let direction = SmsExtractorDirection(rawValue: declared)
        else { throw SmsExtractorValidationError.directionInvalid }
        let span = try evidence(value["evidence"], source: source)
        let words =
            direction == .debit
            ? ["debit", "debited", "deducted", "withdrawn", "spent", "paid", "charged"]
            : ["credit", "credited", "deposited", "received", "refunded"]
        let evidence = span.text.precomposedStringWithCompatibilityMapping.lowercased()
        guard words.contains(where: { evidence.range(of: #"\b\#($0)\b"#, options: .regularExpression) != nil }) else {
            throw SmsExtractorValidationError.directionInvalid
        }
        return (direction, span)
    }

    private func account(_ raw: Any?, source: String) throws -> (value: String, span: UnicodeScalarSpan) {
        guard let value = raw as? [String: Any], Set(value.keys) == Set(["reference", "evidence"]),
            let declared = value["reference"] as? String
        else { throw SmsExtractorValidationError.accountInvalid }
        let span = try evidence(value["evidence"], source: source)
        guard let normalized = SmsExtractorNormalizer.normalizeAccount(span.text),
            SmsExtractorNormalizer.normalizeAccount(declared) == normalized
        else { throw SmsExtractorValidationError.accountInvalid }
        return (normalized, span)
    }

    private func counterparty(_ raw: Any?, source: String) throws -> (value: String?, span: UnicodeScalarSpan?) {
        guard let raw, !(raw is NSNull) else { return (nil, nil) }
        guard let value = raw as? [String: Any], Set(value.keys) == Set(["value", "evidence"]),
            let declared = value["value"] as? String
        else { throw SmsExtractorValidationError.counterpartyInvalid }
        let span = try evidence(value["evidence"], source: source)
        guard let normalized = SmsExtractorNormalizer.normalizeCounterparty(span.text),
            SmsExtractorNormalizer.normalizeCounterparty(declared) == normalized
        else { throw SmsExtractorValidationError.counterpartyInvalid }
        return (normalized, span)
    }

    private func evidence(_ raw: Any?, source: String) throws -> UnicodeScalarSpan {
        guard let object = raw as? [String: Any],
            Set(object.keys) == Set(["start_scalar", "end_scalar", "text"]),
            let start = exactInteger(object["start_scalar"]),
            let end = exactInteger(object["end_scalar"]),
            let text = object["text"] as? String
        else { throw SmsExtractorValidationError.evidenceInvalid }
        return try UnicodeScalarSpan(source: source, startScalar: start, endScalar: end, text: text)
    }

    private func exactInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value,
            value >= Double(Int.min), value <= Double(Int.max)
        else { return nil }
        return Int(value)
    }

    private func onlyMoney(in text: String) throws -> String {
        let range = try NSRegularExpression(
            pattern: #"(?<![\w,])(?:\d{1,3}(?:,\d{2})+,\d{3}|\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?![\w,])"#
        ).matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard range.count == 1, let value = Range(range[0].range, in: text).map({ String(text[$0]) }) else {
            throw SmsExtractorValidationError.amountInvalid
        }
        return value
    }
}

/// JSONSerialization deliberately accepts duplicate keys; reject them before decoding.
nonisolated private enum StrictExtractorJSON {
    static func validateOneDocument(_ input: String) throws {
        var scanner = Scanner(Array(input.utf8))
        try scanner.value()
        scanner.space()
        guard scanner.atEnd else { throw SmsExtractorValidationError.extraContent }
    }
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { index == bytes.count }
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func value() throws {
            space()
            guard index < bytes.count else { throw SmsExtractorValidationError.malformedJSON }
            switch bytes[index] {
            case 123: try object()
            case 91: try array()
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            case 45, 48...57: try number()
            default: throw SmsExtractorValidationError.malformedJSON
            }
        }
        mutating func object() throws {
            index += 1
            space()
            var keys = Set<String>()
            if consume(125) { return }
            while true {
                space()
                let key = try string()
                guard keys.insert(key).inserted else { throw SmsExtractorValidationError.duplicateJSONKey }
                space()
                guard consume(58) else { throw SmsExtractorValidationError.malformedJSON }
                try value()
                space()
                if consume(125) { return }
                guard consume(44) else { throw SmsExtractorValidationError.malformedJSON }
            }
        }
        mutating func array() throws {
            index += 1
            space()
            if consume(93) { return }
            while true {
                try value()
                space()
                if consume(93) { return }
                guard consume(44) else { throw SmsExtractorValidationError.malformedJSON }
            }
        }
        mutating func string() throws -> String {
            guard consume(34) else { throw SmsExtractorValidationError.malformedJSON }
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let b = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if b == 92 {
                    escaped = true
                    continue
                }
                if b == 34 {
                    let d = Data(bytes[start..<index])
                    guard let s = try? JSONDecoder().decode(String.self, from: d) else {
                        throw SmsExtractorValidationError.malformedJSON
                    }
                    return s
                }
                if b < 32 { throw SmsExtractorValidationError.malformedJSON }
            }
            throw SmsExtractorValidationError.malformedJSON
        }
        mutating func literal(_ value: String) throws {
            let value = Array(value.utf8)
            guard bytes[index...].starts(with: value) else { throw SmsExtractorValidationError.malformedJSON }
            index += value.count
        }
        mutating func number() throws {
            let start = index
            if consume(45) {}
            guard index < bytes.count else { throw SmsExtractorValidationError.malformedJSON }
            if consume(48) {
            } else {
                guard bytes[index] >= 49 && bytes[index] <= 57 else { throw SmsExtractorValidationError.malformedJSON }
                while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
            }
            if index < bytes.count && (bytes[index] == 46 || bytes[index] == 69 || bytes[index] == 101) {
                throw SmsExtractorValidationError.malformedJSON
            }
            guard index > start else { throw SmsExtractorValidationError.malformedJSON }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count && bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
