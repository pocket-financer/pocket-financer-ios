import CoreFoundation
import Foundation

nonisolated enum SmsReviewFieldKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case amount
    case direction
    case account
    case counterparty

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated enum SmsPartialFieldValidationState: String, Codable, Equatable, Sendable {
    case valid
    case groundedOnly = "grounded_only"
    case suggestion
}

nonisolated enum SmsPartialFieldOrigin: String, Codable, Equatable, Sendable {
    case slm
    case advisoryAnalyzer = "advisory_analyzer"
}

nonisolated struct SmsNormalizedAmountValue: Codable, Equatable, Sendable {
    let minorUnits: Int64
    let currency: String

    enum CodingKeys: String, CodingKey {
        case minorUnits = "minor_units"
        case currency
    }
}

nonisolated enum SmsPartialNormalizedValue: Equatable, Sendable {
    case amount(SmsNormalizedAmountValue)
    case direction(SmsExtractorDirection)
    case account(String)
    case counterparty(String)
}

nonisolated struct SmsReviewPartialField: Codable, Equatable, Sendable {
    let field: SmsReviewFieldKind
    let sourceSpan: UnicodeScalarSpan
    let normalizedValue: SmsPartialNormalizedValue?
    let validationState: SmsPartialFieldValidationState
    let originatingStage: String
    let origin: SmsPartialFieldOrigin

    enum CodingKeys: String, CodingKey {
        case field
        case sourceSpan = "source_span"
        case normalizedValue = "normalized_value"
        case validationState = "validation_state"
        case originatingStage = "originating_stage"
        case origin
    }

    init(
        field: SmsReviewFieldKind,
        sourceSpan: UnicodeScalarSpan,
        normalizedValue: SmsPartialNormalizedValue?,
        validationState: SmsPartialFieldValidationState,
        originatingStage: String,
        origin: SmsPartialFieldOrigin = .slm
    ) {
        self.field = field
        self.sourceSpan = sourceSpan
        self.normalizedValue = normalizedValue
        self.validationState = validationState
        self.originatingStage = originatingStage
        self.origin = origin
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(SmsReviewFieldKind.self, forKey: .field)
        sourceSpan = try container.decode(UnicodeScalarSpan.self, forKey: .sourceSpan)
        validationState = try container.decode(SmsPartialFieldValidationState.self, forKey: .validationState)
        originatingStage = try container.decode(String.self, forKey: .originatingStage)
        origin = try container.decode(SmsPartialFieldOrigin.self, forKey: .origin)
        if try container.decodeNil(forKey: .normalizedValue) {
            normalizedValue = nil
        } else {
            switch field {
            case .amount:
                normalizedValue = .amount(try container.decode(SmsNormalizedAmountValue.self, forKey: .normalizedValue))
            case .direction:
                normalizedValue = .direction(
                    try container.decode(SmsExtractorDirection.self, forKey: .normalizedValue)
                )
            case .account:
                normalizedValue = .account(try container.decode(String.self, forKey: .normalizedValue))
            case .counterparty:
                normalizedValue = .counterparty(try container.decode(String.self, forKey: .normalizedValue))
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(sourceSpan, forKey: .sourceSpan)
        try container.encode(validationState, forKey: .validationState)
        try container.encode(originatingStage, forKey: .originatingStage)
        try container.encode(origin, forKey: .origin)
        switch normalizedValue {
        case .amount(let value):
            try container.encode(value, forKey: .normalizedValue)
        case .direction(let value):
            try container.encode(value.rawValue, forKey: .normalizedValue)
        case .account(let value):
            try container.encode(value, forKey: .normalizedValue)
        case .counterparty(let value):
            try container.encode(value, forKey: .normalizedValue)
        case nil:
            try container.encodeNil(forKey: .normalizedValue)
        }
    }

    var normalizedAmount: SmsNormalizedAmountValue? {
        if case .amount(let value) = normalizedValue { value } else { nil }
    }

    var normalizedDirection: SmsExtractorDirection? {
        if case .direction(let value) = normalizedValue { value } else { nil }
    }

    var normalizedAccount: String? {
        if case .account(let value) = normalizedValue { value } else { nil }
    }

    var normalizedCounterparty: String? {
        if case .counterparty(let value) = normalizedValue { value } else { nil }
    }

    func jsonObject() -> [String: Any] {
        let value: Any =
            switch normalizedValue {
            case .amount(let amount):
                [
                    "currency": amount.currency,
                    "minor_units": amount.minorUnits,
                ] as [String: Any]
            case .direction(let direction):
                direction.rawValue
            case .account(let reference):
                reference
            case .counterparty(let counterparty):
                counterparty
            case nil:
                NSNull()
            }
        return [
            "field": field.rawValue,
            "source_span": [
                "start_scalar": sourceSpan.startScalar,
                "end_scalar": sourceSpan.endScalar,
                "text": sourceSpan.text,
            ] as [String: Any],
            "normalized_value": value,
            "validation_state": validationState.rawValue,
            "originating_stage": originatingStage,
            "origin": origin.rawValue,
        ]
    }
}

nonisolated struct SmsReviewAnalyzerHint: Codable, Equatable, Hashable, Sendable {
    let kind: String
    let sourceSpan: UnicodeScalarSpan?
    let summary: String
    let clauseID: String?
    let suggestedInterpretation: [String: String]

    init(
        kind: String,
        sourceSpan: UnicodeScalarSpan?,
        summary: String,
        clauseID: String? = nil,
        suggestedInterpretation: [String: String] = [:]
    ) {
        self.kind = kind
        self.sourceSpan = sourceSpan
        self.summary = summary
        self.clauseID = clauseID
        self.suggestedInterpretation = suggestedInterpretation
    }
}

nonisolated struct SmsReviewRetainedEvidence: Equatable, Sendable {
    static let contractVersion = "pocketfinancer.review-case/2"

    let contractVersion: String
    let furthestStage: String
    let primaryCurrency: String
    let receiptTimestampEpochMilliseconds: Int64
    let receiptProvenance: String
    let slmFields: [SmsReviewFieldKind: SmsReviewPartialField]
    let analyzerHints: [SmsReviewAnalyzerHint]

    var receiptTimestamp: Date {
        Date(timeIntervalSince1970: Double(receiptTimestampEpochMilliseconds) / 1_000)
    }
}

nonisolated struct SmsReviewProposal: Equatable, Sendable {
    var amountMinorUnits: Int64
    var currency: String
    var direction: String
    var accountReference: String
    var counterparty: String?
    var amountSpan: UnicodeScalarSpan
    var directionSpan: UnicodeScalarSpan?
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

nonisolated struct SmsValidatedReviewSubmission: Equatable, Sendable {
    let amountMinorUnits: Int64
    let currency: String
    let amountSpan: UnicodeScalarSpan
    let direction: SmsExtractorDirection
    let directionSpan: UnicodeScalarSpan?
    let accountReference: String?
    let accountSpan: UnicodeScalarSpan?
    let counterparty: String?
    let counterpartySpan: UnicodeScalarSpan?
    let explicitAccountID: UUID?
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
            SmsExtractorNormalizer.directionGrounded(direction: direction, text: directionSpan.text),
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
        let byField = Dictionary(grouping: corrections, by: \.field)
        guard byField.values.allSatisfy({ $0.count == 1 }) else {
            throw SmsProcessingStoreError.invalidCommand
        }

        if let currencyCorrection = byField["currency"]?.first {
            let normalizedCurrency = currencyCorrection.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard CurrencyProfileRegistry.scales[normalizedCurrency] != nil else {
                throw SmsProcessingStoreError.invalidCommand
            }
            result.currency = normalizedCurrency
        }

        var explicitAccountSelection: SmsFieldCorrection?
        for correction in corrections {
            switch correction.field {
            case "currency":
                continue
            case "amount":
                guard let evidence = correction.scalarEvidence else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let verified = try verifySpan(evidence, source: source)
                guard
                    let amount = try? SmsExtractorNormalizer.minorUnits(
                        evidenceText: verified.text,
                        currency: result.currency
                    ),
                    let declaredAmount = Int64(correction.newValue),
                    amount > 0,
                    amount == declaredAmount
                else { throw SmsProcessingStoreError.invalidCommand }
                result.amountMinorUnits = amount
                result.amountSpan = verified
            case "direction":
                guard ["debit", "credit"].contains(correction.newValue) else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                if let rawEvidence = correction.scalarEvidence {
                    let verified = try verifySpan(rawEvidence, source: source)
                    guard
                        SmsExtractorNormalizer.directionGrounded(
                            direction: correction.newValue,
                            text: verified.text
                        )
                    else { throw SmsProcessingStoreError.invalidCommand }
                    result.direction = correction.newValue
                    result.directionSpan = verified
                } else {
                    guard correction.classification == .suppliedManualUngroundedValue else {
                        throw SmsProcessingStoreError.invalidCommand
                    }
                    result.direction = correction.newValue
                    result.directionSpan = nil
                }
            case "account":
                guard let rawEvidence = correction.scalarEvidence else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let verified = try verifySpan(rawEvidence, source: source)
                guard
                    let account = SmsExtractorNormalizer.normalizeAccount(verified.text),
                    account == SmsExtractorNormalizer.normalizeAccount(correction.newValue)
                else { throw SmsProcessingStoreError.invalidCommand }
                result.accountReference = account
                result.accountSpan = verified
                result.accountStatus = "unresolved"
                result.resolvedAccountID = nil
            case "account_id":
                explicitAccountSelection = correction
            case "counterparty":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    result.counterparty = nil
                    result.counterpartySpan = nil
                } else {
                    guard let rawEvidence = correction.scalarEvidence else {
                        throw SmsProcessingStoreError.invalidCommand
                    }
                    let verified = try verifySpan(rawEvidence, source: source)
                    guard
                        let value = SmsExtractorNormalizer.normalizeCounterparty(verified.text),
                        value == SmsExtractorNormalizer.normalizeCounterparty(correction.newValue)
                    else { throw SmsProcessingStoreError.invalidCommand }
                    result.counterparty = value
                    result.counterpartySpan = verified
                }
            default:
                continue
            }
        }

        if let explicitAccountSelection {
            guard explicitAccountSelection.scalarEvidence == nil,
                [.suppliedManualUngroundedValue, .selectedExistingCandidate].contains(
                    explicitAccountSelection.classification
                )
            else { throw SmsProcessingStoreError.invalidCommand }
            if explicitAccountSelection.newValue.isEmpty || explicitAccountSelection.newValue == "null" {
                result.resolvedAccountID = nil
                if result.accountStatus == "uniquely_resolved" {
                    result.accountStatus = "unresolved"
                }
            } else {
                guard let accountID = UUID(uuidString: explicitAccountSelection.newValue) else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                result.resolvedAccountID = accountID
                result.accountStatus = "uniquely_resolved"
            }
        }

        if byField["currency"] != nil && byField["amount"] == nil {
            guard
                (try? SmsExtractorNormalizer.minorUnits(
                    evidenceText: result.amountSpan.text,
                    currency: result.currency
                )) == result.amountMinorUnits
            else { throw SmsProcessingStoreError.invalidCommand }
        }

        return result
    }

    static func validateSubmission(
        corrections: [SmsFieldCorrection],
        base: SmsReviewProposal?,
        defaultCurrency: String,
        source: String
    ) throws -> SmsValidatedReviewSubmission {
        let allowedFields: Set<String> = [
            "currency",
            "amount",
            "direction",
            "account",
            "counterparty",
            "account_id",
            "new_account_name",
            "new_account_bank",
            "new_account_kind",
            "new_account_suffix",
        ]
        guard corrections.allSatisfy({ allowedFields.contains($0.field) }) else {
            throw SmsProcessingStoreError.invalidCommand
        }
        let grouped = Dictionary(grouping: corrections, by: \.field)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw SmsProcessingStoreError.invalidCommand
        }
        let byField = grouped.compactMapValues(\.first)

        let rawCurrency =
            byField["currency"]?.newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            ?? base?.currency
            ?? defaultCurrency.uppercased()
        guard CurrencyProfileRegistry.scales[rawCurrency] != nil else {
            throw SmsProcessingStoreError.invalidCommand
        }

        let amountMinorUnits: Int64
        let amountSpan: UnicodeScalarSpan
        if let amountCorrection = byField["amount"] {
            guard let rawEvidence = amountCorrection.scalarEvidence else {
                throw SmsProcessingStoreError.invalidCommand
            }
            let verified = try verifySpan(rawEvidence, source: source)
            guard
                let parsed = try? SmsExtractorNormalizer.minorUnits(
                    evidenceText: verified.text,
                    currency: rawCurrency
                ),
                let declared = Int64(amountCorrection.newValue),
                parsed > 0,
                parsed == declared
            else { throw SmsProcessingStoreError.invalidCommand }
            amountMinorUnits = parsed
            amountSpan = verified
        } else if let base {
            guard
                (try? SmsExtractorNormalizer.minorUnits(
                    evidenceText: base.amountSpan.text,
                    currency: rawCurrency
                )) == base.amountMinorUnits
            else { throw SmsProcessingStoreError.invalidCommand }
            amountMinorUnits = base.amountMinorUnits
            amountSpan = base.amountSpan
        } else {
            throw SmsProcessingStoreError.invalidCommand
        }

        let direction: SmsExtractorDirection
        let directionSpan: UnicodeScalarSpan?
        if let directionCorrection = byField["direction"] {
            guard let parsedDirection = SmsExtractorDirection(rawValue: directionCorrection.newValue) else {
                throw SmsProcessingStoreError.invalidCommand
            }
            if let rawEvidence = directionCorrection.scalarEvidence {
                let verified = try verifySpan(rawEvidence, source: source)
                guard
                    SmsExtractorNormalizer.directionGrounded(
                        direction: parsedDirection.rawValue,
                        text: verified.text
                    )
                else { throw SmsProcessingStoreError.invalidCommand }
                direction = parsedDirection
                directionSpan = verified
            } else {
                guard directionCorrection.classification == .suppliedManualUngroundedValue else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                direction = parsedDirection
                directionSpan = nil
            }
        } else if let base, let baseDirection = SmsExtractorDirection(rawValue: base.direction) {
            if let baseSpan = base.directionSpan {
                guard
                    SmsExtractorNormalizer.directionGrounded(
                        direction: baseDirection.rawValue,
                        text: baseSpan.text
                    )
                else { throw SmsProcessingStoreError.invalidCommand }
            }
            direction = baseDirection
            directionSpan = base.directionSpan
        } else {
            throw SmsProcessingStoreError.invalidCommand
        }

        var accountReference: String?
        var accountSpan: UnicodeScalarSpan?
        if let accountCorrection = byField["account"] {
            if accountCorrection.newValue.isEmpty && accountCorrection.scalarEvidence == nil {
                accountReference = nil
                accountSpan = nil
            } else {
                guard let rawEvidence = accountCorrection.scalarEvidence else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let verified = try verifySpan(rawEvidence, source: source)
                guard
                    let normalized = SmsExtractorNormalizer.normalizeAccount(verified.text),
                    normalized == SmsExtractorNormalizer.normalizeAccount(accountCorrection.newValue)
                else { throw SmsProcessingStoreError.invalidCommand }
                accountReference = normalized
                accountSpan = verified
            }
        } else if let base {
            accountReference = base.accountReference
            accountSpan = base.accountSpan
        }

        let explicitAccountID: UUID?
        if let accountIDCorrection = byField["account_id"] {
            guard accountIDCorrection.scalarEvidence == nil,
                [.suppliedManualUngroundedValue, .selectedExistingCandidate].contains(
                    accountIDCorrection.classification
                )
            else { throw SmsProcessingStoreError.invalidCommand }
            if accountIDCorrection.newValue.isEmpty || accountIDCorrection.newValue == "null" {
                explicitAccountID = nil
            } else {
                guard let uuid = UUID(uuidString: accountIDCorrection.newValue) else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                explicitAccountID = uuid
            }
        } else if byField["account"] == nil, byField["new_account_name"] == nil {
            explicitAccountID = base?.resolvedAccountID
        } else {
            explicitAccountID = nil
        }

        let hasNewAccountName =
            byField["new_account_name"]?.newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !(explicitAccountID != nil && hasNewAccountName) else {
            throw SmsProcessingStoreError.invalidCommand
        }
        guard (accountReference != nil && accountSpan != nil) || explicitAccountID != nil || hasNewAccountName else {
            throw SmsProcessingStoreError.invalidCommand
        }

        let counterparty: String?
        let counterpartySpan: UnicodeScalarSpan?
        if let counterpartyCorrection = byField["counterparty"] {
            if counterpartyCorrection.newValue.isEmpty && counterpartyCorrection.scalarEvidence == nil {
                counterparty = nil
                counterpartySpan = nil
            } else {
                guard let rawEvidence = counterpartyCorrection.scalarEvidence else {
                    throw SmsProcessingStoreError.invalidCommand
                }
                let verified = try verifySpan(rawEvidence, source: source)
                guard
                    let normalized = SmsExtractorNormalizer.normalizeCounterparty(verified.text),
                    normalized == SmsExtractorNormalizer.normalizeCounterparty(counterpartyCorrection.newValue)
                else { throw SmsProcessingStoreError.invalidCommand }
                counterparty = normalized
                counterpartySpan = verified
            }
        } else if let base {
            counterparty = base.counterparty
            counterpartySpan = base.counterpartySpan
        } else {
            counterparty = nil
            counterpartySpan = nil
        }

        return SmsValidatedReviewSubmission(
            amountMinorUnits: amountMinorUnits,
            currency: rawCurrency,
            amountSpan: amountSpan,
            direction: direction,
            directionSpan: directionSpan,
            accountReference: accountReference,
            accountSpan: accountSpan,
            counterparty: counterparty,
            counterpartySpan: counterpartySpan,
            explicitAccountID: explicitAccountID
        )
    }

    static func partialFields(from transaction: SmsExtractedTransaction) -> [SmsReviewPartialField] {
        var fields: [SmsReviewPartialField] = [
            SmsReviewPartialField(
                field: .amount,
                sourceSpan: transaction.amountSpan,
                normalizedValue: .amount(
                    SmsNormalizedAmountValue(minorUnits: transaction.minorUnits, currency: transaction.currency)
                ),
                validationState: .valid,
                originatingStage: "normalization",
                origin: .slm
            ),
            SmsReviewPartialField(
                field: .direction,
                sourceSpan: transaction.directionSpan,
                normalizedValue: .direction(transaction.direction),
                validationState: .valid,
                originatingStage: "normalization",
                origin: .slm
            ),
            SmsReviewPartialField(
                field: .account,
                sourceSpan: transaction.accountSpan,
                normalizedValue: .account(transaction.accountReference),
                validationState: .valid,
                originatingStage: "normalization",
                origin: .slm
            ),
        ]
        if let counterparty = transaction.counterparty, let counterpartySpan = transaction.counterpartySpan {
            fields.append(
                SmsReviewPartialField(
                    field: .counterparty,
                    sourceSpan: counterpartySpan,
                    normalizedValue: .counterparty(counterparty),
                    validationState: .valid,
                    originatingStage: "normalization",
                    origin: .slm
                )
            )
        }
        return fields
    }

    static func analyzerHints(
        from analysis: SmsAnalysis,
        source: String
    ) -> [SmsReviewAnalyzerHint] {
        var hints: [SmsReviewAnalyzerHint] = []
        for candidate in analysis.candidates where !candidate.explicitlyAbsent {
            let sourceSpan = candidate.evidence.flatMap { evidence in
                try? UnicodeScalarSpan(
                    source: source,
                    startScalar: evidence.startCharacter,
                    endScalar: evidence.endCharacter,
                    text: evidence.text
                )
            }
            let summary =
                sourceSpan?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? suggestionSummary(from: candidate.value)
            guard !summary.isEmpty else { continue }
            hints.append(
                SmsReviewAnalyzerHint(
                    kind: candidate.kind.rawValue,
                    sourceSpan: sourceSpan,
                    summary: summary,
                    clauseID: candidate.clauseID,
                    suggestedInterpretation: candidate.value
                )
            )
        }
        for cue in analysis.cues {
            let sourceSpan = try? UnicodeScalarSpan(
                source: source,
                startScalar: cue.evidence.startCharacter,
                endScalar: cue.evidence.endCharacter,
                text: cue.evidence.text
            )
            let summary =
                sourceSpan?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? cue.reasonCode
            hints.append(
                SmsReviewAnalyzerHint(
                    kind: cue.kind,
                    sourceSpan: sourceSpan,
                    summary: summary,
                    clauseID: cue.clauseID,
                    suggestedInterpretation: ["reason_code": cue.reasonCode]
                )
            )
        }
        return hints
    }

    static func analyzerHints(
        fromAnalysisJSON analysisJSON: String?,
        source: String
    ) -> [SmsReviewAnalyzerHint] {
        guard
            let analysisJSON,
            let root = try? JSONSerialization.jsonObject(with: Data(analysisJSON.utf8)) as? [String: Any]
        else { return [] }

        var hints: [SmsReviewAnalyzerHint] = []
        if let candidates = root["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                guard
                    candidate["explicit_absence"] as? Bool != true,
                    let kind = candidate["kind"] as? String,
                    !kind.isEmpty
                else { continue }
                let sourceSpan = analysisEvidenceSpan(candidate["evidence"], source: source)
                let interpretation = stringifyDictionary(candidate["value"] as? [String: Any])
                let summary =
                    sourceSpan?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? suggestionSummary(from: interpretation)
                guard !summary.isEmpty else { continue }
                hints.append(
                    SmsReviewAnalyzerHint(
                        kind: kind,
                        sourceSpan: sourceSpan,
                        summary: summary,
                        clauseID: candidate["clause_id"] as? String,
                        suggestedInterpretation: interpretation
                    )
                )
            }
        }
        if let cues = root["cues"] as? [[String: Any]] {
            for cue in cues {
                guard let kind = cue["kind"] as? String, !kind.isEmpty else { continue }
                let sourceSpan = analysisEvidenceSpan(cue["evidence"], source: source)
                let reasonCode = cue["reason_code"] as? String
                let interpretation = reasonCode.map { ["reason_code": $0] } ?? [:]
                let summary =
                    sourceSpan?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? reasonCode
                    ?? ""
                guard !summary.isEmpty else { continue }
                hints.append(
                    SmsReviewAnalyzerHint(
                        kind: kind,
                        sourceSpan: sourceSpan,
                        summary: summary,
                        clauseID: cue["clause_id"] as? String,
                        suggestedInterpretation: interpretation
                    )
                )
            }
        }
        return hints
    }

    static func retainedEvidenceJSONObject(
        furthestStage: String,
        slmFields: [SmsReviewPartialField],
        analysis: SmsAnalysis?,
        source: String
    ) -> [String: Any] {
        var fieldEvidence: [[String: Any]] =
            slmFields
            .filter { $0.origin == .slm }
            .map { $0.jsonObject() }
        var analyzerSuggestions: [[String: Any]] = []

        if let analysis {
            for candidate in analysis.candidates where !candidate.explicitlyAbsent {
                let verifiedSpan = candidate.evidence.flatMap { evidence in
                    try? UnicodeScalarSpan(
                        source: source,
                        startScalar: evidence.startCharacter,
                        endScalar: evidence.endCharacter,
                        text: evidence.text
                    )
                }
                let spanObject: Any = verifiedSpan.map(scalarSpanObject) ?? NSNull()
                var interpretation: [String: Any] = candidate.value
                if candidate.kind == .amount,
                    let rawMinor = candidate.value["minor_units"],
                    let minorUnits = Int64(rawMinor)
                {
                    interpretation["minor_units"] = minorUnits
                }
                analyzerSuggestions.append([
                    "kind": candidate.kind.rawValue,
                    "span": spanObject,
                    "clause": (candidate.clauseID as Any?) ?? NSNull(),
                    "suggested_interpretation": interpretation,
                    "provenance": [
                        "candidate_id": candidate.id,
                        "analyzer_kind": "candidate",
                    ],
                    "analyzer_version": analysis.contract,
                ])
                if let verifiedSpan {
                    fieldEvidence.append([
                        "field": candidate.kind.rawValue,
                        "source_span": scalarSpanObject(verifiedSpan),
                        "normalized_value": interpretation,
                        "validation_state": SmsPartialFieldValidationState.suggestion.rawValue,
                        "originating_stage": "analysis_advisory",
                        "origin": SmsPartialFieldOrigin.advisoryAnalyzer.rawValue,
                    ])
                }
            }
            for cue in analysis.cues {
                let verifiedSpan = try? UnicodeScalarSpan(
                    source: source,
                    startScalar: cue.evidence.startCharacter,
                    endScalar: cue.evidence.endCharacter,
                    text: cue.evidence.text
                )
                analyzerSuggestions.append([
                    "kind": cue.kind,
                    "span": verifiedSpan.map(scalarSpanObject) ?? NSNull(),
                    "clause": cue.clauseID,
                    "suggested_interpretation": ["reason_code": cue.reasonCode],
                    "provenance": [
                        "cue_id": cue.id,
                        "analyzer_kind": "cue",
                    ],
                    "analyzer_version": analysis.contract,
                ])
            }
        }

        return [
            "contract": SmsReviewRetainedEvidence.contractVersion,
            "furthest_stage": furthestStage,
            "field_evidence": fieldEvidence,
            "analyzer_suggestions": analyzerSuggestions,
        ]
    }

    static func parseRetainedEvidence(
        resultJSON: String?,
        analysisJSON: String?,
        operationConfigurationJSON: String?,
        source: String,
        fallbackPrimaryCurrency: String = "INR",
        fallbackReceiptTimestamp: Date = .now,
        fallbackReceiptProvenance: String = "platform_received"
    ) -> SmsReviewRetainedEvidence {
        let resultRoot = resultJSON.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let configRoot = operationConfigurationJSON.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }

        let primaryCurrency =
            (configRoot?["currency_context"] as? [String: Any])?["primary_currency"] as? String
            ?? fallbackPrimaryCurrency
        let receiptObject =
            (resultRoot?["receipt_timestamp"] as? [String: Any])
            ?? (configRoot?["received_timestamp"] as? [String: Any])
        let receiptEpochMilliseconds =
            receiptObject.flatMap { exactInt64($0["epoch_ms"]) }
            ?? Int64((fallbackReceiptTimestamp.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let rawProvenance = receiptObject?["provenance"] as? String
        let receiptProvenance =
            rawProvenance.flatMap {
                ["platform_received", "acquisition_supplied_message_time"].contains($0) ? $0 : nil
            } ?? fallbackReceiptProvenance

        var slmFields: [SmsReviewFieldKind: SmsReviewPartialField] = [:]
        var analyzerHints: [SmsReviewAnalyzerHint] = []
        var furthestStage: String?

        if let retained = resultRoot?["retained_evidence"] as? [String: Any],
            retained["contract"] as? String == SmsReviewRetainedEvidence.contractVersion
        {
            if let stage = retained["furthest_stage"] as? String, !stage.isEmpty {
                furthestStage = stage
            }
            if let items = retained["field_evidence"] as? [[String: Any]] {
                for item in items {
                    guard let field = parsePartialField(item, source: source), field.origin == .slm else {
                        continue
                    }
                    if slmFields[field.field] == nil {
                        slmFields[field.field] = field
                    }
                }
            }
            if let suggestions = retained["analyzer_suggestions"] as? [[String: Any]] {
                for suggestion in suggestions {
                    guard let hint = parseAnalyzerSuggestion(suggestion, source: source) else { continue }
                    analyzerHints.append(hint)
                }
            }
        }

        if slmFields.isEmpty, let proposal = parse(resultJSON: resultJSON, source: source) {
            slmFields[.amount] = SmsReviewPartialField(
                field: .amount,
                sourceSpan: proposal.amountSpan,
                normalizedValue: .amount(
                    SmsNormalizedAmountValue(minorUnits: proposal.amountMinorUnits, currency: proposal.currency)
                ),
                validationState: .valid,
                originatingStage: "normalization",
                origin: .slm
            )
            if let directionSpan = proposal.directionSpan,
                let direction = SmsExtractorDirection(rawValue: proposal.direction)
            {
                slmFields[.direction] = SmsReviewPartialField(
                    field: .direction,
                    sourceSpan: directionSpan,
                    normalizedValue: .direction(direction),
                    validationState: .valid,
                    originatingStage: "normalization",
                    origin: .slm
                )
            }
            slmFields[.account] = SmsReviewPartialField(
                field: .account,
                sourceSpan: proposal.accountSpan,
                normalizedValue: .account(proposal.accountReference),
                validationState: .valid,
                originatingStage: "normalization",
                origin: .slm
            )
            if let counterparty = proposal.counterparty, let counterpartySpan = proposal.counterpartySpan {
                slmFields[.counterparty] = SmsReviewPartialField(
                    field: .counterparty,
                    sourceSpan: counterpartySpan,
                    normalizedValue: .counterparty(counterparty),
                    validationState: .valid,
                    originatingStage: "normalization",
                    origin: .slm
                )
            }
            if furthestStage == nil {
                furthestStage = "persistence_gate"
            }
        }

        if analyzerHints.isEmpty, let analysisJSON {
            analyzerHints = Self.analyzerHints(fromAnalysisJSON: analysisJSON, source: source)
            if furthestStage == nil && !analyzerHints.isEmpty {
                furthestStage = "analysis_advisory"
            }
        }

        return SmsReviewRetainedEvidence(
            contractVersion: SmsReviewRetainedEvidence.contractVersion,
            furthestStage: furthestStage ?? "admission",
            primaryCurrency: primaryCurrency,
            receiptTimestampEpochMilliseconds: max(0, receiptEpochMilliseconds),
            receiptProvenance: receiptProvenance,
            slmFields: slmFields,
            analyzerHints: analyzerHints
        )
    }

    private static func verifySpan(_ span: UnicodeScalarSpan, source: String) throws -> UnicodeScalarSpan {
        do {
            return try UnicodeScalarSpan(
                source: source,
                startScalar: span.startScalar,
                endScalar: span.endScalar,
                text: span.text
            )
        } catch {
            throw SmsProcessingStoreError.invalidCommand
        }
    }

    private static func parsePartialField(_ item: [String: Any], source: String) -> SmsReviewPartialField? {
        guard
            let rawOrigin = item["origin"] as? String,
            let origin = SmsPartialFieldOrigin(rawValue: rawOrigin),
            let rawField = item["field"] as? String,
            let field = SmsReviewFieldKind(rawValue: rawField),
            let rawState = item["validation_state"] as? String,
            let state = SmsPartialFieldValidationState(rawValue: rawState),
            let stage = item["originating_stage"] as? String,
            !stage.isEmpty,
            let sourceSpan = span(item["source_span"], source: source)
        else { return nil }

        let rawValue = item["normalized_value"]
        let normalizedValue: SmsPartialNormalizedValue?
        if rawValue == nil || rawValue is NSNull {
            normalizedValue = nil
        } else {
            switch field {
            case .amount:
                if let object = rawValue as? [String: Any],
                    let minorUnits = exactInt64(object["minor_units"]),
                    minorUnits > 0,
                    let currency = (object["currency"] as? String)?.uppercased(),
                    CurrencyProfileRegistry.scales[currency] != nil,
                    (try? SmsExtractorNormalizer.minorUnits(
                        evidenceText: sourceSpan.text,
                        currency: currency
                    )) == minorUnits
                {
                    normalizedValue = .amount(
                        SmsNormalizedAmountValue(minorUnits: minorUnits, currency: currency)
                    )
                } else {
                    normalizedValue = nil
                }
            case .direction:
                if let text = rawValue as? String,
                    let direction = SmsExtractorDirection(rawValue: text),
                    SmsExtractorNormalizer.directionGrounded(direction: direction.rawValue, text: sourceSpan.text)
                {
                    normalizedValue = .direction(direction)
                } else {
                    normalizedValue = nil
                }
            case .account:
                if let text = rawValue as? String,
                    let normalized = SmsExtractorNormalizer.normalizeAccount(sourceSpan.text),
                    SmsExtractorNormalizer.normalizeAccount(text) == normalized
                {
                    normalizedValue = .account(normalized)
                } else {
                    normalizedValue = nil
                }
            case .counterparty:
                if let text = rawValue as? String,
                    let normalized = SmsExtractorNormalizer.normalizeCounterparty(sourceSpan.text),
                    SmsExtractorNormalizer.normalizeCounterparty(text) == normalized
                {
                    normalizedValue = .counterparty(normalized)
                } else {
                    normalizedValue = nil
                }
            }
        }

        let effectiveState: SmsPartialFieldValidationState =
            if origin == .slm {
                normalizedValue == nil ? .groundedOnly : (state == .valid ? .valid : .groundedOnly)
            } else {
                .suggestion
            }

        return SmsReviewPartialField(
            field: field,
            sourceSpan: sourceSpan,
            normalizedValue: effectiveState == .valid ? normalizedValue : nil,
            validationState: effectiveState,
            originatingStage: stage,
            origin: origin
        )
    }

    private static func parseAnalyzerSuggestion(
        _ item: [String: Any],
        source: String
    ) -> SmsReviewAnalyzerHint? {
        guard let kind = item["kind"] as? String, !kind.isEmpty else { return nil }
        let sourceSpan = span(item["span"], source: source)
        let interpretation = stringifyDictionary(item["suggested_interpretation"] as? [String: Any])
        let summary =
            sourceSpan?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? suggestionSummary(from: interpretation)
        guard !summary.isEmpty else { return nil }
        return SmsReviewAnalyzerHint(
            kind: kind,
            sourceSpan: sourceSpan,
            summary: summary,
            clauseID: item["clause"] as? String,
            suggestedInterpretation: interpretation
        )
    }

    private static func scalarSpanObject(_ value: UnicodeScalarSpan) -> [String: Any] {
        [
            "start_scalar": value.startScalar,
            "end_scalar": value.endScalar,
            "text": value.text,
        ]
    }

    private static func span(_ value: Any?, source: String) -> UnicodeScalarSpan? {
        guard let object = value as? [String: Any],
            let start = exactInt(object["start_scalar"]),
            let end = exactInt(object["end_scalar"]),
            let text = object["text"] as? String
        else { return nil }
        return try? UnicodeScalarSpan(source: source, startScalar: start, endScalar: end, text: text)
    }

    private static func analysisEvidenceSpan(_ value: Any?, source: String) -> UnicodeScalarSpan? {
        guard let object = value as? [String: Any],
            let start = exactInt(object["start_char"]),
            let end = exactInt(object["end_char"]),
            let text = object["text"] as? String
        else { return nil }
        return try? UnicodeScalarSpan(source: source, startScalar: start, endScalar: end, text: text)
    }

    private static func stringifyDictionary(_ dictionary: [String: Any]?) -> [String: String] {
        guard let dictionary else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary where !(value is NSNull) {
            if let text = value as? String {
                result[key] = text
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    private static func suggestionSummary(from interpretation: [String: String]) -> String {
        interpretation.keys.sorted().map { "\($0): \(interpretation[$0] ?? "")" }.joined(separator: ", ")
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

extension String {
    fileprivate nonisolated var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
