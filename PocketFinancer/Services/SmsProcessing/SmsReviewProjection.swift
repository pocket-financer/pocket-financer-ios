import CoreFoundation
import Foundation

nonisolated struct SmsReviewProposal: Equatable, Sendable {
    var amountMinorUnits: Int64
    let currency: String
    var direction: String
    var accountReference: String
    var counterparty: String?
    var amountSpan: UnicodeScalarSpan
    var directionSpan: UnicodeScalarSpan
    var accountSpan: UnicodeScalarSpan
    var counterpartySpan: UnicodeScalarSpan?
    let receiptTimestamp: Date
    var accountStatus: String
    var resolvedAccountID: UUID?
    let duplicateStatus: String
    let duplicateIdempotencyKey: String
    let duplicateSourceEventKey: String
    let transactionFingerprint: String
}

nonisolated enum SmsReviewProjection {
    static func parse(resultJSON: String?, source: String) -> SmsReviewProposal? {
        guard
            let resultJSON,
            let root = try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any],
            root["contract"] as? String == "pocketfinancer.processing-result/3",
            let status = root["status"] as? String,
            ["review", "blocked"].contains(status),
            root["recognition_decision"] as? String == "posted",
            let semantic = root["semantic_result"] as? [String: Any],
            let money = semantic["money"] as? [String: Any],
            let amount = exactInt64(money["minor_units"]),
            amount > 0,
            let currency = money["currency"] as? String,
            CurrencyProfileRegistry.scales[currency] != nil,
            let direction = semantic["direction"] as? String,
            ["debit", "credit"].contains(direction),
            let accountReference = semantic["account_reference"] as? String,
            let evidence = semantic["evidence"] as? [String: Any],
            let amountSpan = span(evidence["amount"], source: source),
            let directionSpan = span(evidence["direction"], source: source),
            let accountSpan = span(evidence["account"], source: source),
            let receipt = root["receipt_timestamp"] as? [String: Any],
            receipt["read_only"] as? Bool == true,
            let receiptProvenance = receipt["provenance"] as? String,
            ["platform_received", "acquisition_supplied_message_time"].contains(receiptProvenance),
            let epochMilliseconds = exactInt64(receipt["epoch_ms"]),
            epochMilliseconds >= 0
        else { return nil }
        let counterparty = semantic["counterparty"] as? String
        let counterpartySpan = span(evidence["counterparty"], source: source)
        guard (counterparty == nil) == (counterpartySpan == nil) else { return nil }
        guard
            (try? SmsExtractorNormalizer.minorUnits(
                evidenceText: amountSpan.text,
                currency: currency
            )) == amount,
            SmsExtractorNormalizer.direction(directionSpan.text) == direction,
            SmsExtractorNormalizer.normalizeAccount(accountSpan.text)
                == SmsExtractorNormalizer.normalizeAccount(accountReference),
            counterparty == nil
                || SmsExtractorNormalizer.normalizeCounterparty(
                    counterpartySpan?.text ?? ""
                ) == SmsExtractorNormalizer.normalizeCounterparty(counterparty ?? "")
        else { return nil }
        guard
            let account = root["account_resolution"] as? [String: Any],
            let duplicate = root["duplicate_assessment"] as? [String: Any],
            let accountStatus = account["status"] as? String,
            let duplicateStatus = duplicate["status"] as? String,
            let accountMatchCount = exactInt(account["match_count"]),
            accountMatchCount >= 0,
            let accountIDField = nullableString(account, key: "account_id"),
            let normalizedReferenceField = nullableString(account, key: "normalized_reference"),
            let matchedAliasHashField = nullableString(account, key: "matched_alias_hash"),
            account["provenance"] as? String == "pocketfinancer.account-resolution-profile/1",
            let idempotencyKey = duplicate["idempotency_key"] as? String,
            !idempotencyKey.isEmpty,
            let sourceEventKey = duplicate["source_event_key"] as? String,
            !sourceEventKey.isEmpty,
            let transactionFingerprint = duplicate["transaction_fingerprint"] as? String,
            isSHA256(transactionFingerprint)
        else { return nil }
        guard
            ["unresolved", "ambiguous", "uniquely_resolved"].contains(accountStatus),
            ["clear", "possible_duplicate", "already_persisted"].contains(duplicateStatus)
        else { return nil }
        let resolvedAccountID = accountIDField.flatMap(UUID.init(uuidString:))
        guard let normalizedSemanticAccount = SmsExtractorNormalizer.normalizeAccount(accountReference)
        else { return nil }
        let semanticAliasKey =
            normalizedSemanticAccount.contains("@")
            ? "vpa:\(normalizedSemanticAccount)"
            : "suffix:\(normalizedSemanticAccount)"
        guard normalizedReferenceField == semanticAliasKey else { return nil }
        switch accountStatus {
        case "unresolved":
            guard
                accountMatchCount == 0,
                accountIDField == nil,
                matchedAliasHashField == nil
            else { return nil }
        case "ambiguous":
            guard
                accountMatchCount >= 2,
                accountIDField == nil,
                matchedAliasHashField == nil
            else { return nil }
        case "uniquely_resolved":
            guard
                accountMatchCount == 1,
                resolvedAccountID != nil,
                normalizedReferenceField?.isEmpty == false,
                isSHA256(matchedAliasHashField),
                matchedAliasHashField == CanonicalJSON.sha256(semanticAliasKey)
            else { return nil }
        default:
            return nil
        }
        guard
            transactionFingerprint
                == CanonicalJSON.sha256(
                    "\(amount)\0\(currency)\0\(direction)\0" + "\(accountIDField ?? "")\0\(epochMilliseconds)"
                )
        else { return nil }
        return SmsReviewProposal(
            amountMinorUnits: amount,
            currency: currency,
            direction: direction,
            accountReference: accountReference,
            counterparty: counterparty,
            amountSpan: amountSpan,
            directionSpan: directionSpan,
            accountSpan: accountSpan,
            counterpartySpan: counterpartySpan,
            receiptTimestamp: Date(timeIntervalSince1970: Double(epochMilliseconds) / 1_000),
            accountStatus: accountStatus,
            resolvedAccountID: resolvedAccountID,
            duplicateStatus: duplicateStatus,
            duplicateIdempotencyKey: idempotencyKey,
            duplicateSourceEventKey: sourceEventKey,
            transactionFingerprint: transactionFingerprint
        )
    }

    static func applying(
        _ corrections: [SmsFieldCorrection],
        to base: SmsReviewProposal,
        source: String
    ) throws -> SmsReviewProposal {
        var result = base
        for correction in corrections {
            switch correction.field {
            case "amount":
                guard let evidence = correction.scalarEvidence else { throw SmsProcessingStoreError.invalidCommand }
                let verified = try UnicodeScalarSpan(
                    source: source,
                    startScalar: evidence.startScalar,
                    endScalar: evidence.endScalar,
                    text: evidence.text
                )
                guard
                    let amount = try? SmsExtractorNormalizer.minorUnits(
                        evidenceText: verified.text,
                        currency: result.currency
                    ), let declaredAmount = Int64(correction.newValue), amount == declaredAmount
                else { throw SmsProcessingStoreError.invalidCommand }
                result.amountMinorUnits = amount
                result.amountSpan = verified
            case "direction":
                guard let rawEvidence = correction.scalarEvidence,
                    let evidence = try? UnicodeScalarSpan(
                        source: source,
                        startScalar: rawEvidence.startScalar,
                        endScalar: rawEvidence.endScalar,
                        text: rawEvidence.text
                    ),
                    let direction = SmsExtractorNormalizer.direction(evidence.text),
                    direction == correction.newValue
                else { throw SmsProcessingStoreError.invalidCommand }
                result.direction = direction
                result.directionSpan = evidence
            case "account":
                guard let rawEvidence = correction.scalarEvidence,
                    let evidence = try? UnicodeScalarSpan(
                        source: source,
                        startScalar: rawEvidence.startScalar,
                        endScalar: rawEvidence.endScalar,
                        text: rawEvidence.text
                    ),
                    let account = SmsExtractorNormalizer.normalizeAccount(evidence.text),
                    account == SmsExtractorNormalizer.normalizeAccount(correction.newValue)
                else { throw SmsProcessingStoreError.invalidCommand }
                result.accountReference = account
                result.accountSpan = evidence
                result.accountStatus = "unresolved"
                result.resolvedAccountID = nil
            case "counterparty":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    result.counterparty = nil
                    result.counterpartySpan = nil
                } else {
                    guard let rawEvidence = correction.scalarEvidence,
                        let evidence = try? UnicodeScalarSpan(
                            source: source,
                            startScalar: rawEvidence.startScalar,
                            endScalar: rawEvidence.endScalar,
                            text: rawEvidence.text
                        ),
                        let value = SmsExtractorNormalizer.normalizeCounterparty(evidence.text),
                        value == SmsExtractorNormalizer.normalizeCounterparty(correction.newValue)
                    else { throw SmsProcessingStoreError.invalidCommand }
                    result.counterparty = value
                    result.counterpartySpan = evidence
                }
            default:
                continue
            }
        }
        return result
    }

    private static func span(_ value: Any?, source: String) -> UnicodeScalarSpan? {
        guard let object = value as? [String: Any],
            let start = exactInt(object["start_scalar"]),
            let end = exactInt(object["end_scalar"]),
            let text = object["text"] as? String
        else { return nil }
        return try? UnicodeScalarSpan(source: source, startScalar: start, endScalar: end, text: text)
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, isIntegerNumber(number) else { return nil }
        let decimal = number.decimalValue
        guard decimal >= Decimal(Int.min), decimal <= Decimal(Int.max) else { return nil }
        return number.intValue
    }

    private static func exactInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, isIntegerNumber(number) else { return nil }
        let decimal = number.decimalValue
        guard decimal >= Decimal(Int64.min), decimal <= Decimal(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func nullableString(
        _ object: [String: Any],
        key: String
    ) -> String?? {
        guard let raw = object[key] else { return nil }
        if raw is NSNull { return .some(nil) }
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return .some(value)
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let bytes = value?.utf8, bytes.count == 64 else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isIntegerNumber(_ number: NSNumber) -> Bool {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !["f", "d"].contains(String(cString: number.objCType))
    }
}
