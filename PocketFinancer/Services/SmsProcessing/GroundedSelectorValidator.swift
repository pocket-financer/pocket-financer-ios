import Foundation

enum GroundedSelectorValidationError: String, Error, Sendable {
    case outputTooLarge = "runtime_output_truncated"
    case malformedJSON = "selector_malformed_json"
    case duplicateKey = "selector_duplicate_json_key"
    case outputNotObject = "selector_output_not_object"
    case decisionTypeInvalid = "selector_decision_type_invalid"
    case unknownDecision = "selector_unknown_decision"
    case nonPostedExtraFields = "selector_non_posted_extra_fields"
    case postedFieldSetInvalid = "selector_posted_field_set_invalid"
    case candidateIDInvalid = "selector_candidate_id_invalid"
    case ambiguousCandidateIDs = "selector_candidate_ids_ambiguous"
    case unknownCandidate = "selector_unknown_or_cross_message_candidate"
    case candidateKindMismatch = "selector_candidate_kind_mismatch"
    case requiredCandidateAbsent = "selector_required_candidate_absent"
    case requiredEvidenceMissing = "selector_required_evidence_missing"
    case crossClauseCoreSelection = "selector_cross_clause_core_selection"
    case candidateMetadataInvalid = "selector_candidate_metadata_invalid"
    case absentCandidateMetadataInvalid = "selector_absent_candidate_metadata_invalid"
    case optionalEvidenceMissing = "selector_optional_evidence_missing"
}

struct GroundedSelectorValidator: Sendable {
    nonisolated func validate(
        rawOutput: String,
        analysis: SmsAnalysis,
        byteLimit: Int = 16_384
    ) throws -> GroundedSelectorResult {
        guard rawOutput.utf8.count <= byteLimit else {
            throw GroundedSelectorValidationError.outputTooLarge
        }
        guard let data = rawOutput.data(using: .utf8) else {
            throw GroundedSelectorValidationError.malformedJSON
        }
        let knownKeys = ["decision", "amount", "direction", "account", "counterparty"]
        if hasDuplicateJSONKey(rawOutput) {
            throw GroundedSelectorValidationError.duplicateKey
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GroundedSelectorValidationError.malformedJSON
        }
        guard let object = value as? [String: Any] else {
            throw GroundedSelectorValidationError.outputNotObject
        }
        guard let decisionValue = object["decision"] as? String else {
            throw GroundedSelectorValidationError.decisionTypeInvalid
        }
        guard let decision = SelectorDecision(rawValue: decisionValue) else {
            throw GroundedSelectorValidationError.unknownDecision
        }
        if decision != .posted {
            guard Set(object.keys) == Set(["decision"]) else {
                throw GroundedSelectorValidationError.nonPostedExtraFields
            }
            return GroundedSelectorResult(decision: decision, posted: nil)
        }
        let expected = Set(knownKeys)
        guard Set(object.keys) == expected else {
            throw GroundedSelectorValidationError.postedFieldSetInvalid
        }
        let ids = try ["amount", "direction", "account", "counterparty"].map { field -> String in
            guard let id = object[field] as? String, !id.isEmpty else {
                throw GroundedSelectorValidationError.candidateIDInvalid
            }
            return id
        }
        let grouped = Dictionary(grouping: analysis.candidates, by: \SmsCandidate.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw GroundedSelectorValidationError.ambiguousCandidateIDs
        }
        let kinds: [SmsCandidateKind] = [.amount, .direction, .account, .counterparty]
        let resolved = try zip(ids, kinds).map { id, kind -> SmsCandidate in
            guard let candidate = grouped[id]?.first else {
                throw GroundedSelectorValidationError.unknownCandidate
            }
            guard candidate.kind == kind else {
                throw GroundedSelectorValidationError.candidateKindMismatch
            }
            return candidate
        }
        guard !resolved[0].explicitlyAbsent, !resolved[1].explicitlyAbsent else {
            throw GroundedSelectorValidationError.requiredCandidateAbsent
        }
        guard resolved[0].evidence != nil, resolved[1].evidence != nil else {
            throw GroundedSelectorValidationError.requiredEvidenceMissing
        }
        guard resolved[0].clauseID == resolved[1].clauseID else {
            throw GroundedSelectorValidationError.crossClauseCoreSelection
        }
        guard
            let minorUnits = resolved[0].value["minor_units"].flatMap(Int64.init),
            minorUnits > 0,
            let currency = resolved[0].value["currency"],
            CurrencyProfileRegistry.scales[currency] != nil,
            let provenance = resolved[0].value["currency_provenance"],
            [
                "explicit_code",
                "explicit_unambiguous_symbol_or_marker",
                "user_primary_default",
            ].contains(provenance),
            let direction = resolved[1].value["direction"],
            ["debit", "credit"].contains(direction)
        else { throw GroundedSelectorValidationError.candidateMetadataInvalid }
        try validateOptional(resolved[2])
        try validateOptional(resolved[3])
        return GroundedSelectorResult(
            decision: .posted,
            posted: SelectorPostedSelection(
                amountCandidateID: ids[0], directionCandidateID: ids[1],
                accountCandidateID: ids[2], counterpartyCandidateID: ids[3]
            )
        )
    }

    private nonisolated func validateOptional(_ candidate: SmsCandidate) throws {
        if candidate.explicitlyAbsent {
            guard candidate.evidence == nil, candidate.clauseID == nil,
                candidate.value == ["state": "absent"]
            else { throw GroundedSelectorValidationError.absentCandidateMetadataInvalid }
            return
        }
        guard candidate.evidence != nil, candidate.clauseID != nil else {
            throw GroundedSelectorValidationError.optionalEvidenceMissing
        }
        if candidate.kind == .account {
            guard let accountType = candidate.value["account_type"],
                ["bank_account", "card", "vpa"].contains(accountType),
                candidate.value["identifier"]?.isEmpty == false
            else { throw GroundedSelectorValidationError.candidateMetadataInvalid }
        } else if candidate.kind == .counterparty,
            candidate.value["surface"]?.isEmpty != false
        {
            throw GroundedSelectorValidationError.candidateMetadataInvalid
        }
    }

    private nonisolated func hasDuplicateJSONKey(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var keys = Set<String>()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x22 else {
                index += 1
                continue
            }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    break
                }
                index += 1
            }
            guard index < bytes.count else { return false }
            let end = index
            var next = end + 1
            while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) {
                next += 1
            }
            guard next < bytes.count, bytes[next] == 0x3A else {
                index += 1
                continue
            }
            let encoded = Data(bytes[start...end])
            guard
                let decoded = try? JSONSerialization.jsonObject(
                    with: encoded, options: [.fragmentsAllowed]),
                let key = decoded as? String
            else { return false }
            if !keys.insert(key).inserted { return true }
            index += 1
        }
        return false
    }
}
