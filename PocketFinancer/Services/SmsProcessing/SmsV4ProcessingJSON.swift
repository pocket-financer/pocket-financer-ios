import Foundation

nonisolated enum SmsV4ProcessingJSON {
    static func request(
        source: String,
        sender: String,
        analysis: SmsAnalysis,
        configuration: SmsV4OperationConfiguration
    ) throws -> String {
        let candidates: [[String: Any]] = analysis.candidates.map { candidate in
            var interpretation = candidate.value.reduce(into: [String: Any]()) {
                $0[$1.key] = $1.value
            }
            if let value = candidate.value["minor_units"], let integer = Int64(value) {
                interpretation["minor_units"] = integer
            }
            return [
                "kind": candidate.kind.rawValue,
                "source_span": candidate.evidence.map { span($0) as Any } ?? NSNull(),
                "clause": (candidate.clauseID as Any?) ?? NSNull(),
                "suggested_interpretation": interpretation,
                "provenance": [
                    "candidate_id": candidate.id,
                    "analyzer_kind": "candidate",
                ],
                "analyzer_version": analysis.contract,
            ]
        }
        let cues: [[String: Any]] = analysis.cues.map { cue in
            [
                "kind": cue.kind,
                "source_span": span(cue.evidence),
                "clause": cue.clauseID,
                "suggested_interpretation": ["reason_code": cue.reasonCode],
                "provenance": ["cue_id": cue.id, "analyzer_kind": "cue"],
                "analyzer_version": analysis.contract,
            ]
        }
        return try canonical([
            "contract": "pocketfinancer.sms-extractor-input/1",
            "output_contract": "pocketfinancer.sms-extractor/1",
            "message": source,
            "sender_family": senderFamily(sender),
            "primary_currency": configuration.currencyContext.primaryCurrency,
            "enabled_profile_ids": configuration.currencyContext.enabledProfileIDs,
            "advisory_evidence": candidates + cues,
            "output_rules": [
                "one_json_document": true,
                "decisions": ["none", "abstain", "posted"],
                "posted_required_fields": ["amount", "direction", "account", "counterparty"],
                "source_spans": "zero_based_half_open_unicode_scalars",
                "transaction_time_forbidden": true,
            ],
        ])
    }

    static func result(
        status: String,
        extraction: SmsExtractorResult,
        operation: SmsV4OperationSnapshot,
        account: [String: Any]?,
        duplicate: [String: Any]?,
        gate: [String: Any]?,
        reasons: [String]
    ) throws -> String {
        let semantic: Any
        if let transaction = extraction.transaction {
            semantic =
                [
                    "money": [
                        "minor_units": transaction.minorUnits,
                        "currency": transaction.currency,
                    ],
                    "direction": transaction.direction.rawValue,
                    "account_reference": transaction.accountReference,
                    "counterparty": (transaction.counterparty as Any?) ?? NSNull(),
                    "evidence": [
                        "amount": scalarSpan(transaction.amountSpan),
                        "direction": scalarSpan(transaction.directionSpan),
                        "account": scalarSpan(transaction.accountSpan),
                        "counterparty": transaction.counterpartySpan.map {
                            scalarSpan($0) as Any
                        } ?? NSNull(),
                    ],
                ] as [String: Any]
        } else {
            semantic = NSNull()
        }
        return try canonical([
            "contract": "pocketfinancer.processing-result/3",
            "status": status,
            "recognition_decision": extraction.decision.rawValue,
            "semantic_result": semantic,
            "receipt_timestamp": [
                "epoch_ms": operation.configuration.receivedTimestamp.epochMs,
                "provenance": operation.configuration.receivedTimestamp.provenance,
                "read_only": true,
            ],
            "account_resolution": (account as Any?) ?? NSNull(),
            "duplicate_assessment": (duplicate as Any?) ?? NSNull(),
            "automatic_persistence": (gate as Any?) ?? NSNull(),
            "reason_codes": reasons,
        ])
    }

    static func account(
        _ resolution: SmsAccountResolution,
        reference: String
    ) -> [String: Any] {
        let aliasKey =
            reference.isEmpty
            ? nil
            : (reference.contains("@") ? "vpa:\(reference)" : "suffix:\(reference)")
        let base: [String: Any]
        switch resolution {
        case .missing:
            base = accountBase("missing", 0, nil, nil, nil)
        case .unresolved:
            base = accountBase("unresolved", 0, nil, aliasKey, nil)
        case .ambiguous(let ids):
            base = accountBase("ambiguous", ids.count, nil, aliasKey, nil)
        case .unique(let id):
            base = accountBase(
                "uniquely_resolved", 1, id.uuidString.lowercased(), aliasKey,
                aliasKey.map { CanonicalJSON.sha256($0) }
            )
        }
        return base
    }

    static func accountReasons(_ resolution: SmsAccountResolution) -> [String] {
        switch resolution {
        case .missing: ["account_resolution_unresolved"]
        case .unresolved: ["account_resolution_unresolved"]
        case .ambiguous: ["account_resolution_ambiguous"]
        case .unique: []
        }
    }

    static func duplicate(
        status: String,
        operation: SmsV4OperationSnapshot,
        fingerprint: String?
    ) -> [String: Any] {
        [
            "status": status,
            "idempotency_key": operation.sourceID.uuidString.lowercased(),
            "source_event_key": operation.stableEventID.uuidString.lowercased(),
            "transaction_fingerprint": (fingerprint as Any?) ?? NSNull(),
        ]
    }

    static func gate(
        posted: Bool,
        accountReason: String?,
        duplicateStatus: String
    ) -> [String: Any] {
        let duplicateFailure = duplicateReason(duplicateStatus)
        let result: String
        let primaryReason: String
        if !posted {
            result = "not_posted"
            primaryReason = "persistence_not_posted"
        } else if let accountReason {
            result = "review_required"
            primaryReason = accountReason
        } else if let duplicateFailure {
            result = "review_required"
            primaryReason = duplicateFailure
        } else {
            result = "blocked_by_mode"
            primaryReason = "persistence_blocked_by_rollout_mode"
        }
        return [
            "result": result,
            "primary_reason": primaryReason,
            "checks": checks(
                posted: posted, accountReason: accountReason,
                duplicateStatus: duplicateStatus
            ),
        ]
    }

    static func checksJSON(
        posted: Bool,
        accountReason: String?,
        duplicateStatus: String
    ) throws -> String {
        try canonical(
            checks(
                posted: posted, accountReason: accountReason,
                duplicateStatus: duplicateStatus
            ))
    }

    static func canonical(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw SmsProcessingStoreError.configurationMismatch
        }
        return String(
            decoding: try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
            ), as: UTF8.self)
    }

    static func configurationMatches(_ operation: SmsV4OperationSnapshot) -> Bool {
        configurationMatches(
            configurationJSON: operation.configurationJSON,
            configurationHash: operation.configurationHash
        )
    }

    static func configurationMatches(
        configurationJSON: String,
        configurationHash: String
    ) -> Bool {
        guard
            var value = try? JSONSerialization.jsonObject(
                with: Data(configurationJSON.utf8)
            ) as? [String: Any],
            value.removeValue(forKey: "config_hash") as? String == configurationHash,
            let payload = try? canonical(value),
            CanonicalJSON.sha256(payload) == configurationHash,
            let document = try? canonical(
                value.merging(["config_hash": configurationHash]) { _, new in new }
            ),
            document == configurationJSON,
            let extractor = value["extractor"] as? [String: Any],
            extractor["model_identity_kind"] as? String == "system_managed_runtime",
            extractor["model_file_sha256"] is NSNull
        else { return false }
        return true
    }

    private static func span(_ value: SmsEvidenceSpan) -> [String: Any] {
        [
            "start_scalar": value.startCharacter,
            "end_scalar": value.endCharacter,
            "text": value.text,
        ]
    }
    private static func scalarSpan(_ value: UnicodeScalarSpan) -> [String: Any] {
        ["start_scalar": value.startScalar, "end_scalar": value.endScalar, "text": value.text]
    }
    private static func senderFamily(_ sender: String) -> String {
        var value = sender.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value = value.replacingOccurrences(
            of: #"^[a-z]{2}-"#, with: "", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"[0-9]+"#, with: "#", options: .regularExpression
        )
        return value.isEmpty ? "unknown" : value
    }
    private static func accountBase(
        _ status: String,
        _ count: Int,
        _ accountID: String?,
        _ reference: String?,
        _ aliasHash: String?
    ) -> [String: Any] {
        [
            "status": status,
            "match_count": count,
            "account_id": (accountID as Any?) ?? NSNull(),
            "normalized_reference": (reference as Any?) ?? NSNull(),
            "matched_alias_hash": (aliasHash as Any?) ?? NSNull(),
            "provenance": "pocketfinancer.account-resolution-profile/1",
        ]
    }
    private static func checks(
        posted: Bool,
        accountReason: String?,
        duplicateStatus: String
    ) -> [[String: Any]] {
        [
            check("operation_integrity", true, nil),
            check("configuration_hash", true, nil),
            check("claim_ownership", true, nil),
            check("extractor_mode", true, nil),
            check("posted_extraction", posted, posted ? nil : "persistence_not_posted"),
            check("grounded_mandatory_fields", posted, posted ? nil : "persistence_grounded_fields_missing"),
            check("valid_money", posted, posted ? nil : "persistence_invalid_money"),
            check("receipt_timestamp", true, nil),
            check("account_resolution", accountReason == nil, accountReason),
            check(
                "duplicate_assessment", duplicateStatus == "clear",
                duplicateReason(duplicateStatus)
            ),
            check("rollout_mode", false, "persistence_blocked_by_rollout_mode"),
        ]
    }
    private static func duplicateReason(_ status: String) -> String? {
        switch status {
        case "clear": nil
        case "already_persisted": "duplicate_already_persisted"
        default: "duplicate_possible"
        }
    }
    private static func check(
        _ name: String, _ passed: Bool, _ reason: String?
    ) -> [String: Any] {
        ["check": name, "passed": passed, "reason_code": (reason as Any?) ?? NSNull()]
    }
}
