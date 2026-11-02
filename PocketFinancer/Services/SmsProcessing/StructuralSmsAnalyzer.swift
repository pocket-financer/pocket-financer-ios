import Foundation

struct StructuralSmsAnalyzer: Sendable {
    nonisolated func analyze(
        source: String,
        operation: SmsOperationSnapshot
    ) throws -> SmsAnalysis {
        try analyze(
            source: source,
            operationID: operation.operationID,
            configurationHash: operation.configurationHash,
            primaryCurrency: operation.configuration.primaryCurrency,
            enabledProfiles: operation.configuration.enabledProfiles,
            sourceTimestampEpochMilliseconds: operation.configuration.sourceTimestampEpochMilliseconds,
            sourceTimestampProvenance: operation.configuration.sourceTimestampProvenance
        )
    }

    nonisolated func analyze(
        source: String,
        operation: SmsV4OperationSnapshot
    ) throws -> SmsAnalysis {
        try analyze(
            source: source,
            operationID: operation.operationID,
            configurationHash: operation.configurationHash,
            primaryCurrency: operation.configuration.currencyContext.primaryCurrency,
            enabledProfiles: operation.configuration.currencyContext.enabledProfileIDs,
            sourceTimestampEpochMilliseconds: operation.configuration.receivedTimestamp.epochMs,
            sourceTimestampProvenance: operation.configuration.receivedTimestamp.provenance
        )
    }

    private nonisolated func analyze(
        source: String,
        operationID: UUID,
        configurationHash: String,
        primaryCurrency: String,
        enabledProfiles: [String],
        sourceTimestampEpochMilliseconds: Int64?,
        sourceTimestampProvenance: String
    ) throws -> SmsAnalysis {
        let sourceHash = CanonicalJSON.sha256(source)
        let identity = [
            operationID.uuidString.lowercased(), sourceHash,
            configurationHash, "pocketfinancer.structural-sms-analyzer/2",
        ].joined(separator: "\0")
        let analysisID = String(CanonicalJSON.sha256(identity).prefix(24))
        let structuralView = SmsStructuralView(source)
        let clauses = StructuralClauseSegmenter.clauses(in: source)
        var candidates: [SmsCandidate] = []
        var cues: [SmsCue] = []
        var reasons = Set<String>()
        var blockedClauses = Set<String>()

        let cuePatterns: [(kind: String, reason: String, pattern: String)] = [
            (
                "failure", "non_posted_failure",
                #"\b(?:failed|declined|rejected|unsuccessful|could\s+not\s+be\s+processed)\b"#
            ),
            (
                "negation", "negated_movement",
                #"\b(?:not\s+(?:(?:been|be)\s+)?(?:debited|credited|charged|processed)|no\s+money\s+(?:was\s+)?(?:debited|credited))\b"#
            ),
            (
                "pending", "pending_event",
                #"\b(?:pending|processing|in\s+progress|(?:will|may|scheduled\s+to|set\s+to)\s+(?:be\s+)?(?:debited|credited|charged|paid))\b"#
            ),
            (
                "due", "amount_due",
                #"\b(?:amount\s+due|payment\s+due|minimum\s+due|due\s+date)\b"#
            ),
            (
                "request", "request_or_authorization",
                #"\b(?:collect\s+request|payment\s+request|approve|authorize|mandate\s+request)\b"#
            ),
            (
                "balance", "balance_information",
                #"\b(?:available|avail|avl|current|closing)\s+(?:a/?c\s+)?bal(?:ance)?\b"#
            ),
            (
                "promotion", "promotion",
                #"\b(?:offer|cashback\s+offer|discount|sale|apply\s+now|limited\s+time)\b"#
            ),
            (
                "administrative", "administrative",
                #"\b(?:statement\s+generated|kyc|profile\s+updated|nomination|registered)\b"#
            ),
            (
                "credential_otp", "credential_otp",
                #"\b(?:otp|one[- ]time\s+password|verification\s+code|login\s+code|passcode)\b"#
            ),
            (
                "expectation", "expected_refund_not_posted",
                #"\b(?:(?:refund|reversal)(?:\s+of\s+(?:[a-z]{3}\s+)?[\d,.]+)?\s+(?:is\s+|was\s+)?(?:expected|anticipated|promised)|(?:expect|expected|anticipate|anticipated)\s+(?:a\s+)?(?:refund|reversal)|(?:will|may|scheduled\s+to|set\s+to)\s+(?:be\s+)?(?:refunded|reversed))\b"#
            ),
            (
                "authorization_hold", "authorization_or_hold_not_posted",
                #"\b(?:authorization\s+hold|pre[- ]?authori[sz](?:ation|ed)?|(?:payment|charge|transaction|amount)\s+(?:is\s+|was\s+|has\s+been\s+)?authori[sz]ed|(?:temporary\s+)?hold\s+(?:of|for|on)|(?:payment|charge|transaction|amount)\s+(?:is\s+|was\s+|has\s+been\s+)?held)\b"#
            ),
        ]
        let blockingKinds = Set(["negation", "pending", "request", "expectation", "authorization_hold"])
        for item in cuePatterns {
            for evidence in matches(item.pattern, structuralView) {
                let clauseID =
                    StructuralClauseSegmenter.clauseID(
                        containing: evidence, clauses: clauses
                    ) ?? "cl_unknown"
                cues.append(cue(item.kind, item.reason, clauseID, evidence, analysisID))
                if blockingKinds.contains(item.kind), clauseID != "cl_unknown" {
                    let clause = clauseID
                    blockedClauses.insert(clause)
                }
                reasons.insert(item.reason)
            }
        }

        let moneyPattern =
            #"(?<![A-Za-z])(?:(?<code>AED|AUD|CAD|CHF|EUR|GBP|INR|JPY|SGD|USD)|(?<marker>₹|Rs\.?|INR))\s*[:.-]?\s*(?<number>(?:\d{1,3}(?:,\d{2})+,\d{3}|\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,3})?)"#
        let regexMatches = structuralView.matches(moneyPattern)
        for match in regexMatches {
            guard
                let evidence = match.evidence(),
                let number = match.normalizedGroup("number")
            else { continue }
            let explicitCode = match.normalizedGroup("code")
            let currency = explicitCode?.uppercased() ?? primaryCurrency
            let provenance =
                explicitCode == nil
                ? "explicit_unambiguous_symbol_or_marker" : "explicit_code"
            guard
                let money = CurrencyProfileRegistry.parse(
                    number: number, currency: currency, provenance: provenance
                )
            else { continue }
            let value = [
                "currency": money.currency,
                "currency_provenance": money.provenance,
                "minor_units": String(money.minorUnits),
            ]
            candidates.append(candidate(.amount, evidence, value, analysisID, clauses))
        }

        let directionPatterns: [(String, String)] = [
            (#"\b(?:has\s+been\s+|was\s+|is\s+)?(?:debited|deducted|withdrawn|spent|paid|charged)\b"#, "debit"),
            (#"\b(?:has\s+been\s+|was\s+|is\s+)?(?:credited|deposited|received|refunded)\b"#, "credit"),
        ]
        for (pattern, direction) in directionPatterns {
            for evidence in matches(pattern, structuralView) {
                let clause = StructuralClauseSegmenter.clauseID(containing: evidence, clauses: clauses)
                guard clause.map({ !blockedClauses.contains($0) }) ?? true else { continue }
                candidates.append(
                    candidate(
                        .direction, evidence, ["direction": direction], analysisID, clauses
                    ))
            }
        }

        let accountPatterns: [(String, String)] = [
            (
                "bank_account",
                #"\b(?:a/?c|acct|account)\s*(?:no\.?\s*)?(?:ending\s*(?:in|with)?\s*)?(?<identifier>(?:[xX*•-]{2,}\s*)?\d{3,8})\b"#
            ),
            (
                "card",
                #"\b(?:credit\s+|debit\s+)?card\s*(?:ending\s*(?:in|with)?\s*)?(?<identifier>(?:[xX*•-]{2,}\s*)?\d{3,8})\b"#
            ),
            ("vpa", #"\b(?<identifier>[A-Z0-9._-]{2,}@[A-Z][A-Z0-9.-]{1,})\b"#),
        ]
        for (accountType, pattern) in accountPatterns {
            for (evidence, identifier) in namedMatches(
                pattern, group: "identifier", structuralView
            ) {
                candidates.append(
                    candidate(
                        .account, evidence,
                        ["identifier": identifier.text, "account_type": accountType],
                        analysisID, clauses
                    ))
            }
        }
        for match in structuralView.matches(
            #"\b(?:at|to|from|by)\s+(?<name>[A-Z0-9](?:[A-Z0-9&._@/-]*[A-Z0-9&_@/-])?(?:\s+[A-Z0-9](?:[A-Z0-9&._@/-]*[A-Z0-9&_@/-])?){0,4})"#,
        ) {
            let stopWords = Set(["your", "the", "a", "an", "account", "card", "bank"])
            guard let normalizedName = match.normalizedGroup("name"),
                !normalizedName.split(whereSeparator: \Character.isWhitespace).allSatisfy({
                    stopWords.contains(String($0))
                }),
                let name = match.evidence(group: "name")
            else { continue }
            candidates.append(
                candidate(
                    .counterparty, name, ["surface": name.text], analysisID, clauses
                ))
        }
        candidates.append(absence(.account, analysisID))
        candidates.append(absence(.counterparty, analysisID))

        let unique = Dictionary(grouping: candidates, by: \SmsCandidate.id)
        guard unique.values.allSatisfy({ $0.count == 1 }) else {
            throw SmsProcessingStoreError.configurationMismatch
        }
        let directionCount = candidates.filter { $0.kind == .direction }.count
        if candidates.contains(where: { $0.kind == .amount }) {
            reasons.insert("amount_candidate_present")
        }
        if directionCount > 0 { reasons.insert("completed_direction_candidate_present") }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.insert("invalid_input")
        }
        let annotations = clauseAnnotations(
            structuralView: structuralView,
            clauses: clauses,
            candidates: candidates,
            cues: cues
        )
        return SmsAnalysis(
            contract: "pocketfinancer.sms-analysis/2",
            analysisID: analysisID,
            configurationHash: configurationHash,
            sourceHash: sourceHash,
            source: source,
            clauses: clauses,
            candidates: candidates,
            cues: cues,
            reasonCodes: reasons.sorted(),
            completedEventCount: directionCount,
            profileID: enabledProfiles.joined(separator: "+"),
            primaryCurrency: primaryCurrency,
            normalizedStructuralFingerprint: CanonicalJSON.sha256(structuralView.normalized),
            currencyContextHash: currencyContextHash(
                primaryCurrency: primaryCurrency, enabledProfiles: enabledProfiles
            ),
            sourceTimestampEpochMilliseconds: sourceTimestampEpochMilliseconds,
            sourceTimestampProvenance: sourceTimestampProvenance,
            unicodeDatabaseVersion: "14.0.0",
            clauseAnnotations: annotations
        )
    }

    private nonisolated func matches(
        _ pattern: String, _ view: SmsStructuralView
    ) -> [SmsEvidenceSpan] {
        view.matches(pattern).compactMap { $0.evidence() }
    }

    private nonisolated func namedMatches(
        _ pattern: String,
        group: String,
        _ view: SmsStructuralView
    ) -> [(SmsEvidenceSpan, SmsEvidenceSpan)] {
        view.matches(pattern).compactMap { match in
            guard let whole = match.evidence(), let capture = match.evidence(group: group) else {
                return nil
            }
            return (whole, capture)
        }
    }

    private nonisolated func candidate(
        _ kind: SmsCandidateKind,
        _ evidence: SmsEvidenceSpan,
        _ value: [String: String],
        _ analysisID: String,
        _ clauses: [SmsClause]
    ) -> SmsCandidate {
        let span = "\(evidence.startCharacter):\(evidence.endCharacter)"
        let valueJSON = canonicalValue(value, kind: kind)
        let digest = String(
            CanonicalJSON.sha256(
                "\(analysisID)|\(kind.rawValue)|\(span)|\(valueJSON)"
            ).prefix(12))
        let prefix: String =
            switch kind {
            case .amount: "amt"
            case .direction: "dir"
            case .account: "acc"
            case .counterparty: "cp"
            }
        return SmsCandidate(
            id: "\(prefix)_\(digest)", kind: kind,
            clauseID: StructuralClauseSegmenter.clauseID(containing: evidence, clauses: clauses),
            evidence: evidence, explicitlyAbsent: false, value: value, context: []
        )
    }

    private nonisolated func absence(_ kind: SmsCandidateKind, _ analysisID: String) -> SmsCandidate {
        let value = ["state": "absent"]
        let digest = String(
            CanonicalJSON.sha256(
                "\(analysisID)|\(kind.rawValue)|absent|\(canonicalValue(value))"
            ).prefix(12))
        let prefix = kind == .account ? "acc" : "cp"
        return SmsCandidate(
            id: "\(prefix)_\(digest)", kind: kind, clauseID: nil, evidence: nil,
            explicitlyAbsent: true, value: value, context: ["explicit_absence"]
        )
    }

    private nonisolated func cue(
        _ kind: String,
        _ reasonCode: String,
        _ clauseID: String,
        _ evidence: SmsEvidenceSpan,
        _ analysisID: String
    ) -> SmsCue {
        let digest = String(
            CanonicalJSON.sha256(
                "\(analysisID)|cue|\(kind)|\(evidence.startCharacter)|\(evidence.endCharacter)"
            ).prefix(12)
        )
        return SmsCue(
            id: "q_\(digest)", kind: kind, clauseID: clauseID,
            evidence: evidence, reasonCode: reasonCode
        )
    }

    private nonisolated func clauseAnnotations(
        structuralView: SmsStructuralView,
        clauses: [SmsClause],
        candidates: [SmsCandidate],
        cues: [SmsCue]
    ) -> [SmsClauseAnnotation] {
        let stateByCue = [
            "failure": "failed", "negation": "failed", "pending": "pending",
            "due": "due", "request": "request", "expectation": "expectation",
            "authorization_hold": "authorization", "credential_otp": "security",
        ]
        let familyPatterns: [(String, String)] = [
            ("refund", #"\b(?:refund|refunded|reversal|reversed)\b"#),
            ("wallet", #"\bwallet\b"#),
            ("cash_withdrawal", #"\b(?:cash\s+withdrawal|withdrawn|atm)\b"#),
            ("cash_deposit", #"\b(?:cash\s+deposit|deposited)\b"#),
            ("fee_charge", #"\b(?:fee|fees|service\s+charge)\b"#),
            ("salary_income", #"\bsalary\b"#),
            ("upi_transfer", #"\b(?:upi|vpa)\b"#),
            ("bank_transfer", #"\b(?:transfer|imps|neft|rtgs|nach)\b"#),
            ("card_purchase", #"\b(?:card\s+purchase|purchase\s+on\s+(?:your\s+)?card)\b"#),
            ("merchant_payment", #"\b(?:merchant\s+payment|purchase|spent|paid)\b"#),
        ]
        var states = Dictionary(uniqueKeysWithValues: clauses.map { ($0.id, Set<String>()) })
        for cue in cues {
            if let state = stateByCue[cue.kind], states[cue.clauseID] != nil {
                states[cue.clauseID]?.insert(state)
            }
        }
        for candidate in candidates where candidate.kind == .direction {
            if let clauseID = candidate.clauseID { states[clauseID]?.insert("completed") }
        }
        var families = Dictionary(
            uniqueKeysWithValues: clauses.map { ($0.id, [SmsFinancialFamily]()) }
        )
        for (family, pattern) in familyPatterns {
            for evidence in matches(pattern, structuralView) {
                guard
                    let clauseID = StructuralClauseSegmenter.clauseID(
                        containing: evidence, clauses: clauses
                    )
                else { continue }
                families[clauseID]?.append(.init(family: family, evidence: evidence))
            }
        }
        return clauses.map { clause in
            SmsClauseAnnotation(
                clauseID: clause.id,
                states: (states[clause.id] ?? []).isEmpty
                    ? ["unknown"] : (states[clause.id] ?? []).sorted(),
                financialFamilies: families[clause.id] ?? []
            )
        }
    }

    private nonisolated func currencyContextHash(
        primaryCurrency: String,
        enabledProfiles: [String]
    ) -> String {
        let profiles = enabledProfiles.map {
            ["profile_id": $0, "revision": 1] as [String: Any]
        }
        let data = try! JSONSerialization.data(
            withJSONObject: [
                "primary_currency": primaryCurrency,
                "profiles": profiles,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return CanonicalJSON.sha256(String(decoding: data, as: UTF8.self))
    }

    private nonisolated func canonicalValue(
        _ value: [String: String], kind: SmsCandidateKind? = nil
    ) -> String {
        if kind == .amount,
            let currency = value["currency"],
            let provenance = value["currency_provenance"],
            let minorUnits = value["minor_units"]
        {
            let object: [String: Any] = [
                "currency": currency,
                "currency_provenance": provenance,
                "minor_units": Int64(minorUnits) as Any,
            ]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return asciiEscaped(String(decoding: data, as: UTF8.self))
        }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return asciiEscaped(String(decoding: data, as: UTF8.self))
    }

    private nonisolated func asciiEscaped(_ json: String) -> String {
        var output = ""
        for scalar in json.unicodeScalars {
            let value = scalar.value
            if value <= 0x7F {
                output.unicodeScalars.append(scalar)
            } else if value <= 0xFFFF {
                output += String(format: "\\u%04x", value)
            } else {
                let adjusted = value - 0x1_0000
                let high = 0xD800 + (adjusted >> 10)
                let low = 0xDC00 + (adjusted & 0x3FF)
                output += String(format: "\\u%04x\\u%04x", high, low)
            }
        }
        return output
    }
}
