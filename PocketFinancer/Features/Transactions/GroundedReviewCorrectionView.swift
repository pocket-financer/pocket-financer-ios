import SwiftUI

struct GroundedReviewCorrectionView: View {
    let original: SmsReviewProposal
    let source: String
    let sender: String
    let reasonCodes: [String]
    let resolvedAccountName: String?
    let saving: Bool
    let onResolve: (ReviewCommandKind, [SmsFieldCorrection], String?) -> Void

    @State private var working: SmsReviewProposal
    @State private var selections: [SmsReviewField: UnicodeScalarSpan?]
    @State private var activeField = SmsReviewField.amount

    init(
        original: SmsReviewProposal,
        initial: SmsReviewProposal,
        source: String,
        sender: String,
        reasonCodes: [String],
        resolvedAccountName: String?,
        draftCorrections: [SmsFieldCorrection]?,
        saving: Bool,
        onResolve: @escaping (ReviewCommandKind, [SmsFieldCorrection], String?) -> Void
    ) {
        self.original = original
        self.source = source
        self.sender = sender
        self.reasonCodes = reasonCodes
        self.resolvedAccountName = resolvedAccountName
        self.saving = saving
        self.onResolve = onResolve
        _working = State(initialValue: initial)
        var values: [SmsReviewField: UnicodeScalarSpan?] = [
            .amount: initial.amountSpan,
            .direction: initial.directionSpan,
            .account: initial.accountSpan,
            .counterparty: initial.counterpartySpan,
        ]
        for correction in draftCorrections ?? [] where correction.scalarEvidence == nil {
            if let field = SmsReviewField(rawValue: correction.field) { values[field] = nil }
        }
        _selections = State(initialValue: values)
    }

    var body: some View {
        Form {
            Section {
                Label("Check the proposed transaction", systemImage: "checkmark.shield")
                    .font(.headline)
                Text(
                    "The SMS stays unchanged. Select a field, then drag the native text handles over its exact wording."
                )
                .foregroundStyle(.secondary)
                LabeledContent("Sender", value: sender)
                LabeledContent(
                    "Receipt time",
                    value: working.receiptTimestamp.formatted(date: .abbreviated, time: .shortened)
                )
                Text("Receipt time is read-only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Source evidence") {
                Picker("Active field", selection: $activeField) {
                    ForEach(SmsReviewField.allCases) { field in
                        Text(field.label)
                            .tag(field)
                            .accessibilityLabel(fieldAccessibility(field))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("review-active-field")

                EvidenceSelectionTextView(
                    source: source,
                    selections: selections,
                    activeField: activeField,
                    onSelectionChanged: updateSelection
                )
                .accessibilityIdentifier("review-source-evidence")

                HStack {
                    Button("Clear \(activeField.label)") { clearActiveField() }
                    Spacer()
                    Button("Reselect") { resetActiveField() }
                }
            }

            Section("Normalized preview") {
                LabeledContent(
                    "Amount",
                    value: CurrencyFormatter.string(
                        minorUnits: working.amountMinorUnits,
                        currencyCode: working.currency
                    )
                )
                LabeledContent("Direction", value: working.direction.capitalized)
                LabeledContent("Account evidence", value: working.accountReference)
                LabeledContent("Counterparty", value: working.counterparty ?? "Not supplied")
                Text(accountPreview)
                    .foregroundStyle(working.accountStatus == "ambiguous" ? .red : .secondary)
            }

            if working.duplicateStatus == "already_persisted" {
                Section {
                    Label("This source event was already saved.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Confirm transaction") {
                    let revisions = corrections
                    onResolve(revisions.isEmpty ? .confirm : .correct, revisions, nil)
                }
                .disabled(!canConfirm || saving)
                .accessibilityIdentifier("review-confirm-transaction")

                Button("Save draft") { onResolve(.saveDraft, corrections, nil) }
                    .disabled(saving)
                    .accessibilityIdentifier("review-save-draft")
            }

            Section("Other options") {
                Button("Retry extraction") { onResolve(.retry, [], "current") }
                    .disabled(saving)
                Button("Not a transaction", role: .destructive) { onResolve(.reject, [], nil) }
                    .disabled(saving)
            }

            Section("Why review is needed") {
                ForEach(reasonCodes, id: \.self) { reason in
                    Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
        }
        .navigationTitle("Review transaction")
    }

    private var canConfirm: Bool {
        (selections[.amount] ?? nil) != nil
            && (selections[.direction] ?? nil) != nil
            && (selections[.account] ?? nil) != nil
            && working.accountStatus != "ambiguous"
            && working.duplicateStatus != "already_persisted"
    }

    private var accountPreview: String {
        if working.accountStatus == "ambiguous" {
            return "More than one owned account matches. Confirmation is blocked."
        }
        if working.accountStatus == "unresolved" {
            return
                "Owned-account aliases will be rechecked when you confirm; one match is reused, otherwise a new local account is created."
        }
        if working.resolvedAccountID != nil, let resolvedAccountName {
            return "Will reuse \(resolvedAccountName)."
        }
        return "A new local account will be created only when you confirm."
    }

    private func fieldAccessibility(_ field: SmsReviewField) -> String {
        guard let span = selections[field] ?? nil else { return "\(field.label), missing" }
        return "\(field.label), selected: \(span.text)"
    }

    private func updateSelection(_ span: UnicodeScalarSpan) {
        do {
            switch activeField {
            case .amount:
                working.amountMinorUnits = try SmsExtractorNormalizer.minorUnits(
                    evidenceText: span.text,
                    currency: working.currency
                )
                working.amountSpan = span
            case .direction:
                guard let value = SmsExtractorNormalizer.direction(span.text) else { return }
                working.direction = value
                working.directionSpan = span
            case .account:
                guard let value = SmsExtractorNormalizer.normalizeAccount(span.text) else { return }
                working.accountReference = value
                working.accountSpan = span
                working.accountStatus = "unresolved"
                working.resolvedAccountID = nil
            case .counterparty:
                guard let value = SmsExtractorNormalizer.normalizeCounterparty(span.text) else { return }
                working.counterparty = value
                working.counterpartySpan = span
            }
            selections[activeField] = span
        } catch {
            return
        }
    }

    private func clearActiveField() {
        selections[activeField] = nil
        if activeField == .counterparty {
            working.counterparty = nil
            working.counterpartySpan = nil
        }
    }

    private func resetActiveField() {
        switch activeField {
        case .amount:
            working.amountMinorUnits = original.amountMinorUnits
            working.amountSpan = original.amountSpan
            selections[.amount] = original.amountSpan
        case .direction:
            working.direction = original.direction
            working.directionSpan = original.directionSpan
            selections[.direction] = original.directionSpan
        case .account:
            working.accountReference = original.accountReference
            working.accountSpan = original.accountSpan
            working.accountStatus = original.accountStatus
            working.resolvedAccountID = original.resolvedAccountID
            selections[.account] = original.accountSpan
        case .counterparty:
            working.counterparty = original.counterparty
            working.counterpartySpan = original.counterpartySpan
            selections[.counterparty] = original.counterpartySpan
        }
    }

    private var corrections: [SmsFieldCorrection] {
        var result: [SmsFieldCorrection] = []
        func append(_ field: SmsReviewField, span: UnicodeScalarSpan?, value: String) {
            result.append(
                SmsFieldCorrection(
                    field: field.rawValue,
                    classification: .suppliedSourceSupportedCandidateMiss,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: span,
                    newValue: value
                )
            )
        }
        let amount = selections[.amount] ?? nil
        if amount == nil || amount != original.amountSpan || working.amountMinorUnits != original.amountMinorUnits {
            append(.amount, span: amount, value: amount == nil ? "" : String(working.amountMinorUnits))
        }
        let direction = selections[.direction] ?? nil
        if direction == nil || direction != original.directionSpan || working.direction != original.direction {
            append(.direction, span: direction, value: direction == nil ? "" : working.direction)
        }
        let account = selections[.account] ?? nil
        if account == nil || account != original.accountSpan || working.accountReference != original.accountReference {
            append(.account, span: account, value: account == nil ? "" : working.accountReference)
        }
        let counterparty = selections[.counterparty] ?? nil
        if counterparty != original.counterpartySpan || working.counterparty != original.counterparty {
            append(.counterparty, span: counterparty, value: working.counterparty ?? "")
        }
        return result
    }
}
