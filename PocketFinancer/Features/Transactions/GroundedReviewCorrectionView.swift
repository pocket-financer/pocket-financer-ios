import Foundation
import SwiftData
import SwiftUI

struct GroundedReviewCorrectionView: View {
    let details: SmsReviewDetails
    let accounts: [Account]
    let sourceAlert: InboxAlert?
    let saving: Bool
    let draftSavedMessage: String?
    let onResolve: (ReviewCommandKind, [SmsFieldCorrection], String?) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var working: ReviewWorkingState
    @State private var selections: [SmsReviewField: UnicodeScalarSpan]
    @State private var pendingSelection: UnicodeScalarSpan?
    @State private var assignmentError: String?
    @State private var showTechnicalDetails = false

    @State private var accountMode: ReviewAccountMode
    @State private var selectedExistingAccountID: UUID?
    @State private var newAccountName: String
    @State private var newAccountBank: String
    @State private var newAccountKind: AccountKind
    @State private var newAccountSuffix: String
    @State private var lastAutoAccountName: String
    @State private var lastAutoAccountSuffix: String
    @State private var matchingAccountIDs: [UUID]
    @State private var liveDuplicateMatches: [DuplicateWindowTransactionSummary]

    init(
        details: SmsReviewDetails,
        accounts: [Account],
        sourceAlert: InboxAlert?,
        saving: Bool,
        draftSavedMessage: String?,
        onResolve: @escaping (ReviewCommandKind, [SmsFieldCorrection], String?) -> Void
    ) {
        self.details = details
        self.accounts = accounts
        self.sourceAlert = sourceAlert
        self.saving = saving
        self.draftSavedMessage = draftSavedMessage
        self.onResolve = onResolve

        let seed = ReviewSeedState.build(details: details, accounts: accounts)
        _working = State(initialValue: seed.working)
        _selections = State(initialValue: seed.selections)
        _accountMode = State(initialValue: seed.accountMode)
        _selectedExistingAccountID = State(initialValue: seed.selectedExistingAccountID)
        _newAccountName = State(initialValue: seed.newAccountName)
        _newAccountBank = State(initialValue: seed.newAccountBank)
        _newAccountKind = State(initialValue: seed.newAccountKind)
        _newAccountSuffix = State(initialValue: seed.newAccountSuffix)
        _lastAutoAccountName = State(initialValue: seed.lastAutoAccountName)
        _lastAutoAccountSuffix = State(initialValue: seed.lastAutoAccountSuffix)
        _matchingAccountIDs = State(initialValue: seed.matchingAccountIDs)
        _liveDuplicateMatches = State(initialValue: details.duplicateMatches)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                duplicateBannerSection
                evidenceSelectionCard
                fieldsCard
                accountResolutionCard
                actionsSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review transaction")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: duplicateRefreshKey) {
            await refreshLiveDuplicateMatches()
        }
        .task(id: working.accountReference ?? "") {
            await refreshMatchingAccounts()
        }
    }

    // MARK: - Header & Why Review Disclosure

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    details.sender.isEmpty ? "Saved alert" : details.sender,
                    systemImage: "message.fill"
                )
                .font(.headline)
                Spacer(minLength: 8)
                Text(
                    details.retainedEvidence.receiptTimestamp.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("Receipt time is read-only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                withAnimation {
                    showTechnicalDetails.toggle()
                }
            } label: {
                HStack {
                    Text(showTechnicalDetails ? "Hide processing details" : "Why review?")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: showTechnicalDetails ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.tint)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review-why-toggle")

            if showTechnicalDetails {
                VStack(alignment: .leading, spacing: 10) {
                    if !details.reasonCodes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(details.reasonCodes, id: \.self) { code in
                                let presentation = AlertProcessingDiagnostics.presentation(for: code)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(presentation.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(presentation.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    LabeledContent(
                        "Processing reached",
                        value: details.retainedEvidence.furthestStage.replacingOccurrences(of: "_", with: " ")
                    )
                    .font(.caption)

                    if !distinctAnalyzerHints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Analyzer hints (not model output)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(distinctAnalyzerHints, id: \.self) { hint in
                                Text("\(hint.kind.capitalized): \(hint.summary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let sourceAlert {
                        NavigationLink {
                            AlertProcessingDetailView(
                                alert: sourceAlert,
                                showReviewLink: false
                            )
                        } label: {
                            HStack {
                                Label("Processing details", systemImage: "list.bullet.rectangle")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.tint)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("open-processing-details")
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Duplicate Banners (H-08 / IOS-17)

    @ViewBuilder
    private var duplicateBannerSection: some View {
        if isAlreadyPersisted {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Already saved")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("This source event was already saved as a transaction. Confirmation is blocked.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("review-duplicate-blocked-banner")
        } else if isPossibleDuplicate {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Possible duplicate within 5 minutes")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(
                            "A similar transaction was saved within 5 minutes. "
                                + "Confirm only if this is a separate transaction, or dismiss it as a duplicate."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                if !liveDuplicateMatches.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Matching recent transaction\(liveDuplicateMatches.count == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(liveDuplicateMatches) { match in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.merchant)
                                        .font(.subheadline.weight(.semibold))
                                    Text(
                                        "\(match.direction.rawValue.capitalized) · "
                                            + "\(match.accountLabel ?? "Unknown account") · "
                                            + "\(match.occurredAt.formatted(date: .omitted, time: .shortened))"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(
                                    CurrencyFormatter.string(
                                        minorUnits: match.amountMinorUnits,
                                        currencyCode: match.currencyCode
                                    )
                                )
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .padding(10)
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
            )
            .accessibilityIdentifier("review-duplicate-warning-banner")
        }
    }

    // MARK: - SMS Evidence Selection

    private var evidenceSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source SMS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SmsReviewField.allCases) { field in
                        fieldAssignmentChip(for: field)
                    }
                }
                .padding(.vertical, 2)
            }

            EvidenceSelectionTextView(
                source: details.rawBody,
                selections: selections,
                pendingSelection: pendingSelection,
                onSelectionChanged: { span in
                    pendingSelection = span
                    assignmentError = nil
                }
            )

            if let pendingSelection {
                HStack(spacing: 8) {
                    Text("Selected “\(pendingSelection.text)” — tap a field above")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Cancel selection") {
                        self.pendingSelection = nil
                        assignmentError = nil
                    }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("review-cancel-selection")
                }
            } else {
                Text("Select text in the message, then tap the field it belongs to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let assignmentError {
                Label(assignmentError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("review-assignment-error")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func fieldAssignmentChip(for field: SmsReviewField) -> some View {
        let hasSpan = selections[field] != nil
        let isAssigned = isFieldAssigned(field)
        return Button {
            assignPendingSelection(to: field)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hasSpan ? "checkmark.circle.fill" : field.systemImage)
                    .font(.caption)
                Text(field.label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(hasSpan ? field.accentColor : Color.primary)
            .background(
                hasSpan ? field.highlightBackgroundColor : Color(.tertiarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        pendingSelection != nil
                            ? field.accentColor.opacity(0.75)
                            : (hasSpan ? field.accentColor.opacity(0.5) : Color(.separator)),
                        lineWidth: pendingSelection != nil ? 1.5 : 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAssigned ? "\(field.label), assigned" : "\(field.label), unassigned")
        .accessibilityIdentifier("review-field-chip-\(field.wireName)")
    }

    // MARK: - Per-Field Rows & Quick Choices

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Extracted fields")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Amount
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ReviewFieldSummaryBadge(
                        field: .amount,
                        value: formattedAmountValue,
                        highlighted: selections[.amount] != nil && working.amountMinorUnits != nil,
                        assigned: selections[.amount] != nil && working.amountMinorUnits != nil,
                        onClear: {
                            working.amountMinorUnits = nil
                            selections[.amount] = nil
                        }
                    )
                    .accessibilityIdentifier("review-row-amount")

                    Menu {
                        ForEach(PrimaryCurrencySettings.supportedCodes, id: \.self) { code in
                            Button(code) {
                                updateCurrency(code)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(working.currency)
                                .font(.subheadline.weight(.semibold).monospaced())
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .accessibilityLabel("Currency, \(working.currency)")
                    .accessibilityIdentifier("review-currency-picker")
                }

                if selections[.amount] == nil {
                    quickChoiceRow(for: .amount)
                }
            }

            Divider()

            // Direction
            VStack(alignment: .leading, spacing: 8) {
                ReviewFieldSummaryBadge(
                    field: .direction,
                    value: directionDisplayValue,
                    highlighted: selections[.direction] != nil,
                    assigned: working.direction != nil,
                    onClear: {
                        working.direction = nil
                        selections[.direction] = nil
                    }
                )
                .accessibilityIdentifier("review-row-direction")

                if let directionSpan = selections[.direction],
                    let supported = supportedDirectionsForCurrentSpan(directionSpan),
                    supported.count > 1
                {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This wording supports Debit or Credit:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(
                            "Direction interpretation",
                            selection: Binding(
                                get: { working.direction ?? supported[0] },
                                set: { working.direction = $0 }
                            )
                        ) {
                            Text("Debit").tag("debit")
                            Text("Credit").tag("credit")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("review-direction-span-toggle")
                    }
                }

                if selections[.direction] == nil {
                    quickChoiceRow(for: .direction)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("If the message has no direction wording, choose:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            directionFallbackButton("debit", label: "Debit")
                            directionFallbackButton("credit", label: "Credit")
                        }
                    }
                }
            }

            Divider()

            // Account Evidence
            VStack(alignment: .leading, spacing: 8) {
                ReviewFieldSummaryBadge(
                    field: .account,
                    value: accountEvidenceDisplayValue,
                    highlighted: selections[.account] != nil && working.accountReference != nil,
                    assigned: selections[.account] != nil && working.accountReference != nil,
                    onClear: {
                        working.accountReference = nil
                        selections[.account] = nil
                        matchingAccountIDs = []
                    }
                )
                .accessibilityIdentifier("review-row-account")

                if selections[.account] == nil {
                    quickChoiceRow(for: .account)
                }
            }

            Divider()

            // Counterparty
            VStack(alignment: .leading, spacing: 8) {
                ReviewFieldSummaryBadge(
                    field: .counterparty,
                    value: working.counterparty ?? "Not supplied (optional)",
                    highlighted: selections[.counterparty] != nil && working.counterparty != nil,
                    assigned: working.counterparty != nil,
                    onClear: {
                        working.counterparty = nil
                        selections[.counterparty] = nil
                    }
                )
                .accessibilityIdentifier("review-row-counterparty")

                if selections[.counterparty] == nil {
                    quickChoiceRow(for: .counterparty)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func directionFallbackButton(_ value: String, label: String) -> some View {
        let isSelected = working.direction == value && selections[.direction] == nil
        return Button {
            working.direction = value
            selections[.direction] = nil
            assignmentError = nil
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? SmsReviewField.direction.accentColor : Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review-direction-fallback-\(value)")
    }

    @ViewBuilder
    private func quickChoiceRow(for field: SmsReviewField) -> some View {
        let choices = quickChoiceSpans(for: field)
        if !choices.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Use text:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, span in
                        Button {
                            assignQuickChoice(span, to: field)
                        } label: {
                            Text("“\(span.text)”")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    field.highlightBackgroundColor,
                                    in: Capsule()
                                )
                                .foregroundStyle(field.accentColor)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review-quick-\(field.wireName)-\(index)")
                    }
                }
            }
        }
    }

    // MARK: - Account Resolution (H-07 / IOS-02)

    private var accountResolutionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to local account")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if isAmbiguousAccount {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Multiple local accounts matched \(formattedAccountReference).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                    Text("Choose which account owns this transaction to unblock confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(ambiguousAccounts) { account in
                            let isSelected =
                                accountMode == .existing && selectedExistingAccountID == account.id
                            Button {
                                accountMode = .existing
                                selectedExistingAccountID = account.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(accountSubtitle(account))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(
                                        systemName: isSelected
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                }
                                .padding(10)
                                .background(
                                    isSelected
                                        ? Color.accentColor.opacity(0.12)
                                        : Color(.tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "review-ambiguous-account-\(account.id.uuidString.lowercased())"
                            )
                        }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("review-account-ambiguous-banner")
            }

            if !accounts.isEmpty {
                Picker("Account choice", selection: $accountMode) {
                    Text("Existing account").tag(ReviewAccountMode.existing)
                    Text("Create new").tag(ReviewAccountMode.createNew)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("review-account-mode")
            }

            if accountMode == .existing && !accounts.isEmpty {
                existingAccountPickerSection
            } else {
                createNewAccountSection
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var existingAccountPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(accounts) { account in
                    Button {
                        selectedExistingAccountID = account.id
                    } label: {
                        Text(accountPickerLabel(account))
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selectedExistingAccount?.name ?? "Choose an existing account")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedExistingAccount == nil ? .orange : .primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .accessibilityIdentifier("review-existing-account-picker")

            if let selected = selectedExistingAccount {
                if matchingAccountIDs.count == 1 && matchingAccountIDs.first == selected.id {
                    Label(
                        "Matched \(selected.name) by confirmed alias.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                } else if working.accountReference != nil {
                    Text(
                        "Confirming will link \(formattedAccountReference) to \(selected.name) "
                            + "so future alerts can auto-save."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var createNewAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if accounts.isEmpty {
                Text("A new local account will be created only when you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Account name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. HDFC Savings", text: $newAccountName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("review-new-account-name")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Bank or issuer (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. HDFC Bank", text: $newAccountBank)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("review-new-account-bank")
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Account type", selection: $newAccountKind) {
                        ForEach(AccountKind.allCases) { kind in
                            Text(kind.rawValue.capitalized).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("review-new-account-kind")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Last digits (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("3–8 digits", text: $newAccountSuffix)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("review-new-account-suffix")
                }
            }

            if let suffixError = newAccountSuffixValidationError {
                Label(suffixError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if working.accountReference != nil {
                Text(
                    "Confirming creates this local account and links \(formattedAccountReference) for auto-save."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !missingRequirements.isEmpty && !isAlreadyPersisted {
                Text("To confirm, assign \(missingRequirements.joined(separator: " and ")).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-missing-requirements")
            }

            if let draftSavedMessage {
                Label(draftSavedMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("review-draft-saved-banner")
            }

            Button {
                submitConfirmation()
            } label: {
                Text(isPossibleDuplicate ? "Confirm as separate transaction" : "Confirm transaction")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConfirm || saving)
            .accessibilityIdentifier("review-confirm-transaction")

            Button {
                onResolve(.saveDraft, buildDraftCorrections(), nil)
            } label: {
                Text("Save draft")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(saving)
            .accessibilityIdentifier("review-save-draft")

            HStack(spacing: 12) {
                Button("Retry extraction") {
                    onResolve(.retry, [], "current")
                }
                .disabled(saving)
                .accessibilityIdentifier("review-retry-extraction")

                Spacer()

                Button(
                    isPossibleDuplicate ? "Dismiss as duplicate" : "Not a transaction",
                    role: .destructive
                ) {
                    onResolve(.reject, [], nil)
                }
                .disabled(saving)
                .accessibilityIdentifier("review-reject-alert")
            }
            .font(.subheadline.weight(.medium))
            .padding(.top, 4)
        }
    }

    // MARK: - Derived State

    private var isAlreadyPersisted: Bool {
        details.duplicateStatus == "already_persisted"
            || details.reasonCodes.contains("duplicate_already_persisted")
    }

    private var isPossibleDuplicate: Bool {
        !isAlreadyPersisted
            && (details.duplicateStatus == "possible_duplicate"
                || details.reasonCodes.contains("duplicate_possible")
                || !liveDuplicateMatches.isEmpty)
    }

    private var isAmbiguousAccount: Bool {
        matchingAccountIDs.count >= 2 && ambiguousAccounts.count >= 2
    }

    private var ambiguousAccounts: [Account] {
        let ids = Set(matchingAccountIDs)
        return accounts.filter { ids.contains($0.id) }
    }

    private var selectedExistingAccount: Account? {
        guard let selectedExistingAccountID else { return nil }
        return accounts.first { $0.id == selectedExistingAccountID }
    }

    private var effectiveAccountIDForDuplicateCheck: UUID? {
        guard accountMode == .existing else { return nil }
        return selectedExistingAccountID
    }

    private var duplicateRefreshKey: String {
        [
            effectiveAccountIDForDuplicateCheck?.uuidString ?? "none",
            working.direction ?? "none",
            working.amountMinorUnits.map(String.init) ?? "none",
            working.currency,
        ].joined(separator: "|")
    }

    private var formattedAmountValue: String {
        if selections[.amount] != nil, let amount = working.amountMinorUnits {
            return CurrencyFormatter.string(minorUnits: amount, currencyCode: working.currency)
        }
        return "Unassigned"
    }

    private var directionDisplayValue: String {
        guard let direction = working.direction else { return "Unassigned" }
        let suffix = selections[.direction] == nil ? " (manual)" : ""
        return direction.capitalized + suffix
    }

    private var accountEvidenceDisplayValue: String {
        guard selections[.account] != nil, let ref = working.accountReference else {
            return "Unassigned"
        }
        return ref.contains("@") ? ref : "••\(ref.suffix(4)) (\(ref))"
    }

    private var formattedAccountReference: String {
        guard let ref = working.accountReference else { return "this reference" }
        return ref.contains("@") ? ref : "••\(ref.suffix(4))"
    }

    private var newAccountSuffixValidationError: String? {
        let trimmed = newAccountSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isValid =
            (3...8).contains(trimmed.count)
            && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
        return isValid ? nil : "Last digits must be 3 to 8 digits, or left blank."
    }

    private var accountSelectionIsReady: Bool {
        if accountMode == .existing && !accounts.isEmpty {
            return selectedExistingAccount != nil
        }
        let trimmedName = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && newAccountSuffixValidationError == nil
    }

    private var missingRequirements: [String] {
        var missing: [String] = []
        if selections[.amount] == nil || (working.amountMinorUnits ?? 0) <= 0 {
            missing.append("amount")
        }
        if working.direction == nil {
            missing.append("direction")
        }
        if !accountSelectionIsReady {
            missing.append(accountMode == .existing && !accounts.isEmpty ? "an account" : "an account name")
        }
        return missing
    }

    private var canConfirm: Bool {
        missingRequirements.isEmpty && !isAlreadyPersisted
    }

    private var distinctAnalyzerHints: [SmsReviewAnalyzerHint] {
        var seen = Set<String>()
        var result: [SmsReviewAnalyzerHint] = []
        for hint in details.retainedEvidence.analyzerHints {
            let key = "\(hint.kind)|\(hint.summary)"
            if seen.insert(key).inserted {
                result.append(hint)
            }
        }
        return result
    }

    // MARK: - Selection & Quick Choices Logic

    private func isFieldAssigned(_ field: SmsReviewField) -> Bool {
        switch field {
        case .amount:
            selections[.amount] != nil && working.amountMinorUnits != nil
        case .direction:
            working.direction != nil
        case .account:
            selections[.account] != nil && working.accountReference != nil
        case .counterparty:
            working.counterparty != nil
        }
    }

    private func assignPendingSelection(to field: SmsReviewField) {
        guard let span = pendingSelection else {
            assignmentError = "Select wording in the message first."
            return
        }
        if applySpan(span, to: field, preferredDirection: nil) {
            pendingSelection = nil
            assignmentError = nil
        } else {
            assignmentError = invalidSpanError(for: field, text: span.text)
        }
    }

    private func assignQuickChoice(_ span: UnicodeScalarSpan, to field: SmsReviewField) {
        let preferredDirection: String? =
            if field == .direction,
                details.retainedEvidence.slmFields[.direction]?.sourceSpan == span
            {
                details.retainedEvidence.slmFields[.direction]?.normalizedDirection?.rawValue
            } else {
                nil
            }
        if applySpan(span, to: field, preferredDirection: preferredDirection) {
            pendingSelection = nil
            assignmentError = nil
        }
    }

    @discardableResult
    private func applySpan(
        _ span: UnicodeScalarSpan,
        to field: SmsReviewField,
        preferredDirection: String?
    ) -> Bool {
        switch field {
        case .amount:
            guard
                let minorUnits = try? SmsExtractorNormalizer.minorUnits(
                    evidenceText: span.text,
                    currency: working.currency
                ),
                minorUnits > 0
            else { return false }
            working.amountMinorUnits = minorUnits
            selections[.amount] = span
            return true
        case .direction:
            let supported = SmsExtractorNormalizer.supportedDirections(for: span.text)
            guard !supported.isEmpty else { return false }
            if let preferredDirection, supported.contains(preferredDirection) {
                working.direction = preferredDirection
            } else {
                working.direction = supported[0]
            }
            selections[.direction] = span
            return true
        case .account:
            guard let normalized = SmsExtractorNormalizer.normalizeAccount(span.text) else {
                return false
            }
            working.accountReference = normalized
            selections[.account] = span
            applyDefaultNewAccountFields(for: normalized)
            return true
        case .counterparty:
            guard let normalized = SmsExtractorNormalizer.normalizeCounterparty(span.text) else {
                return false
            }
            working.counterparty = normalized
            selections[.counterparty] = span
            return true
        }
    }

    private func invalidSpanError(for field: SmsReviewField, text: String) -> String {
        switch field {
        case .amount:
            "“\(text)” cannot be parsed as a valid \(working.currency) amount."
        case .direction:
            "“\(text)” does not contain debit or credit wording."
        case .account:
            "“\(text)” is not a valid account suffix (3–8 digits) or UPI ID."
        case .counterparty:
            "“\(text)” cannot be used as a counterparty."
        }
    }

    private func updateCurrency(_ newCode: String) {
        let normalized = newCode.uppercased()
        working.currency = normalized
        if let amountSpan = selections[.amount] {
            if let reparsed = try? SmsExtractorNormalizer.minorUnits(
                evidenceText: amountSpan.text,
                currency: normalized
            ),
                reparsed > 0
            {
                working.amountMinorUnits = reparsed
            } else {
                working.amountMinorUnits = nil
                selections[.amount] = nil
            }
        }
    }

    private func supportedDirectionsForCurrentSpan(_ span: UnicodeScalarSpan) -> [String]? {
        let supported = SmsExtractorNormalizer.supportedDirections(for: span.text)
        return supported.isEmpty ? nil : supported
    }

    private func quickChoiceSpans(for field: SmsReviewField) -> [UnicodeScalarSpan] {
        var candidates: [UnicodeScalarSpan] = []
        if let slmSpan = details.retainedEvidence.slmFields[field]?.sourceSpan {
            candidates.append(slmSpan)
        }
        if field != .counterparty {
            for hint in details.retainedEvidence.analyzerHints where hint.kind == field.wireName {
                if let span = hint.sourceSpan {
                    candidates.append(span)
                }
            }
        }

        var seenKeys = Set<String>()
        var result: [UnicodeScalarSpan] = []
        for span in candidates {
            guard span.text.count <= 40 else { continue }
            guard (try? span.nsRange(in: details.rawBody)) != nil else { continue }
            guard let dedupeKey = quickChoiceDedupeKey(for: field, span: span) else { continue }
            if seenKeys.insert(dedupeKey).inserted {
                result.append(span)
                if result.count == 3 {
                    break
                }
            }
        }
        return result
    }

    private func quickChoiceDedupeKey(for field: SmsReviewField, span: UnicodeScalarSpan) -> String? {
        switch field {
        case .amount:
            guard
                let minor = try? SmsExtractorNormalizer.minorUnits(
                    evidenceText: span.text,
                    currency: working.currency
                ),
                minor > 0
            else { return nil }
            return String(minor)
        case .direction:
            return SmsExtractorNormalizer.inferredDirection(from: span.text)
        case .account:
            return SmsExtractorNormalizer.normalizeAccount(span.text)
        case .counterparty:
            return SmsExtractorNormalizer.normalizeCounterparty(span.text)
        }
    }

    private func applyDefaultNewAccountFields(for normalizedReference: String) {
        let isVPA = normalizedReference.contains("@")
        let generatedName =
            isVPA
            ? "UPI account \(normalizedReference)"
            : "Account ••\(normalizedReference.suffix(4))"
        if newAccountName.isEmpty || newAccountName == lastAutoAccountName {
            newAccountName = generatedName
            lastAutoAccountName = generatedName
        }
        if newAccountBank.isEmpty {
            newAccountBank = details.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        newAccountKind = isVPA ? .account : .card
        let generatedSuffix = isVPA ? "" : normalizedReference
        if newAccountSuffix.isEmpty || newAccountSuffix == lastAutoAccountSuffix {
            newAccountSuffix = generatedSuffix
            lastAutoAccountSuffix = generatedSuffix
        }
    }

    private func accountSubtitle(_ account: Account) -> String {
        var parts = [account.bank]
        if let suffix = account.suffix, !suffix.isEmpty {
            parts.append("••\(suffix.suffix(4))")
        }
        parts.append(account.kind.rawValue.capitalized)
        return parts.joined(separator: " · ")
    }

    private func accountPickerLabel(_ account: Account) -> String {
        if let suffix = account.suffix, !suffix.isEmpty {
            return "\(account.name) (••\(suffix.suffix(4)))"
        }
        return account.name
    }

    // MARK: - Live Store Lookups

    private func refreshMatchingAccounts() async {
        guard let normalizedRef = working.accountReference else {
            matchingAccountIDs = []
            return
        }
        let store = SmsProcessingStore.shared(for: modelContext.container)
        guard let ids = try? await store.matchingAccountIDs(forNormalizedReference: normalizedRef) else {
            return
        }
        matchingAccountIDs = ids
        if ids.count == 1, let onlyID = ids.first, accounts.contains(where: { $0.id == onlyID }) {
            accountMode = .existing
            selectedExistingAccountID = onlyID
        } else if ids.count >= 2 {
            accountMode = .existing
            if let current = selectedExistingAccountID, !ids.contains(current) {
                selectedExistingAccountID = nil
            }
        } else if !accounts.isEmpty,
            let migratedMatch = ReviewSeedState.uniqueSuffixMatch(
                normalizedReference: normalizedRef,
                in: accounts
            ),
            selectedExistingAccountID == nil
        {
            accountMode = .existing
            selectedExistingAccountID = migratedMatch.id
        }
    }

    private func refreshLiveDuplicateMatches() async {
        guard
            let accountID = effectiveAccountIDForDuplicateCheck,
            let direction = working.direction,
            let minorUnits = working.amountMinorUnits,
            minorUnits > 0
        else {
            liveDuplicateMatches = details.duplicateMatches
            return
        }
        let store = SmsProcessingStore.shared(for: modelContext.container)
        let matches = try? await store.matchingDuplicateWindowTransactions(
            sourceID: details.sourceAlertID,
            accountID: accountID,
            direction: direction,
            minorUnits: minorUnits,
            currency: working.currency,
            occurredAt: details.retainedEvidence.receiptTimestamp,
            excludedOperationID: details.operationID
        )
        if let matches {
            liveDuplicateMatches = matches
        }
    }

    // MARK: - Command & Correction Construction

    private func submitConfirmation() {
        if isUnchangedUniquelyResolvedProposal {
            onResolve(.confirm, [], nil)
        } else {
            onResolve(.correct, buildSubmissionCorrections(), nil)
        }
    }

    private var isUnchangedUniquelyResolvedProposal: Bool {
        guard let proposal = details.proposal,
            proposal.accountStatus == "uniquely_resolved",
            let resolvedID = proposal.resolvedAccountID,
            accountMode == .existing,
            selectedExistingAccountID == resolvedID,
            matchingAccountIDs.count == 1,
            matchingAccountIDs.first == resolvedID,
            working.currency == proposal.currency,
            working.amountMinorUnits == proposal.amountMinorUnits,
            selections[.amount] == proposal.amountSpan,
            working.direction == proposal.direction,
            selections[.direction] == proposal.directionSpan,
            working.accountReference == proposal.accountReference,
            selections[.account] == proposal.accountSpan,
            working.counterparty == proposal.counterparty,
            selections[.counterparty] == proposal.counterpartySpan
        else { return false }
        return true
    }

    private func buildSubmissionCorrections() -> [SmsFieldCorrection] {
        var result: [SmsFieldCorrection] = []

        func append(
            _ field: String,
            classification: SmsFieldGroundingClassification,
            span: UnicodeScalarSpan?,
            value: String
        ) {
            result.append(
                SmsFieldCorrection(
                    field: field,
                    classification: classification,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: span,
                    newValue: value
                )
            )
        }

        append(
            "currency",
            classification: .suppliedManualUngroundedValue,
            span: nil,
            value: working.currency
        )

        if let amount = working.amountMinorUnits, let amountSpan = selections[.amount] {
            append(
                "amount",
                classification: .suppliedSourceSupportedCandidateMiss,
                span: amountSpan,
                value: String(amount)
            )
        }

        if let direction = working.direction {
            let directionSpan = selections[.direction]
            append(
                "direction",
                classification: directionSpan == nil
                    ? .suppliedManualUngroundedValue
                    : .suppliedSourceSupportedCandidateMiss,
                span: directionSpan,
                value: direction
            )
        }

        if let accountRef = working.accountReference, let accountSpan = selections[.account] {
            append(
                "account",
                classification: .suppliedSourceSupportedCandidateMiss,
                span: accountSpan,
                value: accountRef
            )
        } else if details.proposal != nil {
            append(
                "account",
                classification: .suppliedManualUngroundedValue,
                span: nil,
                value: ""
            )
        }

        if let counterparty = working.counterparty, let counterpartySpan = selections[.counterparty] {
            append(
                "counterparty",
                classification: .suppliedSourceSupportedCandidateMiss,
                span: counterpartySpan,
                value: counterparty
            )
        } else {
            append(
                "counterparty",
                classification: .suppliedManualUngroundedValue,
                span: nil,
                value: ""
            )
        }

        if accountMode == .existing, let accountID = selectedExistingAccountID {
            append(
                "account_id",
                classification: .suppliedManualUngroundedValue,
                span: nil,
                value: accountID.uuidString.lowercased()
            )
        } else {
            let trimmedName = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                append(
                    "new_account_name",
                    classification: .suppliedManualUngroundedValue,
                    span: nil,
                    value: trimmedName
                )
            }
            let trimmedBank = newAccountBank.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBank.isEmpty {
                append(
                    "new_account_bank",
                    classification: .suppliedManualUngroundedValue,
                    span: nil,
                    value: trimmedBank
                )
            }
            append(
                "new_account_kind",
                classification: .suppliedManualUngroundedValue,
                span: nil,
                value: newAccountKind.rawValue
            )
            let trimmedSuffix = newAccountSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSuffix.isEmpty {
                append(
                    "new_account_suffix",
                    classification: .suppliedManualUngroundedValue,
                    span: nil,
                    value: trimmedSuffix
                )
            }
        }

        return result
    }

    private func buildDraftCorrections() -> [SmsFieldCorrection] {
        var result = buildSubmissionCorrections()
        if selections[.amount] == nil {
            result.append(
                SmsFieldCorrection(
                    field: "amount",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: nil,
                    newValue: ""
                )
            )
        }
        if working.direction == nil {
            result.append(
                SmsFieldCorrection(
                    field: "direction",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: nil,
                    newValue: ""
                )
            )
        }
        if selections[.account] == nil && details.proposal == nil {
            result.append(
                SmsFieldCorrection(
                    field: "account",
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    scalarEvidence: nil,
                    newValue: ""
                )
            )
        }
        return result
    }
}

// MARK: - Supporting Types

private enum ReviewAccountMode: String, CaseIterable, Identifiable {
    case existing
    case createNew

    var id: String { rawValue }
}

private struct ReviewWorkingState: Equatable {
    var amountMinorUnits: Int64?
    var currency: String
    var direction: String?
    var accountReference: String?
    var counterparty: String?
}

private struct ReviewSeedState {
    let working: ReviewWorkingState
    let selections: [SmsReviewField: UnicodeScalarSpan]
    let accountMode: ReviewAccountMode
    let selectedExistingAccountID: UUID?
    let newAccountName: String
    let newAccountBank: String
    let newAccountKind: AccountKind
    let newAccountSuffix: String
    let lastAutoAccountName: String
    let lastAutoAccountSuffix: String
    let matchingAccountIDs: [UUID]

    static func build(details: SmsReviewDetails, accounts: [Account]) -> ReviewSeedState {
        let proposal = details.proposal
        let retained = details.retainedEvidence

        var working = ReviewWorkingState(
            amountMinorUnits: proposal?.amountMinorUnits,
            currency: proposal?.currency ?? details.primaryCurrency,
            direction: proposal?.direction,
            accountReference: proposal?.accountReference,
            counterparty: proposal?.counterparty
        )
        var selections: [SmsReviewField: UnicodeScalarSpan] = [:]
        if let span = proposal?.amountSpan {
            selections[.amount] = span
        }
        if let span = proposal?.directionSpan {
            selections[.direction] = span
        }
        if let span = proposal?.accountSpan {
            selections[.account] = span
        }
        if let span = proposal?.counterpartySpan {
            selections[.counterparty] = span
        }

        for field in SmsReviewField.allCases {
            guard let partial = retained.slmFields[field], partial.validationState == .valid else {
                continue
            }
            switch field {
            case .amount:
                if selections[.amount] == nil, let value = partial.normalizedAmount {
                    working.amountMinorUnits = value.minorUnits
                    working.currency = value.currency
                    selections[.amount] = partial.sourceSpan
                }
            case .direction:
                if selections[.direction] == nil, let value = partial.normalizedDirection {
                    working.direction = value.rawValue
                    selections[.direction] = partial.sourceSpan
                }
            case .account:
                if selections[.account] == nil, let value = partial.normalizedAccount {
                    working.accountReference = value
                    selections[.account] = partial.sourceSpan
                }
            case .counterparty:
                if selections[.counterparty] == nil, let value = partial.normalizedCounterparty {
                    working.counterparty = value
                    selections[.counterparty] = partial.sourceSpan
                }
            }
        }

        let initialMatchingIDs: [UUID]
        if !details.ambiguousAccountIDs.isEmpty {
            initialMatchingIDs = details.ambiguousAccountIDs
        } else if let suggested = details.suggestedAccountID ?? proposal?.resolvedAccountID {
            initialMatchingIDs = [suggested]
        } else {
            initialMatchingIDs = []
        }

        var accountMode: ReviewAccountMode
        var selectedExistingAccountID: UUID?
        if initialMatchingIDs.count >= 2 {
            accountMode = .existing
            selectedExistingAccountID = nil
        } else if let matchedID = initialMatchingIDs.first,
            accounts.contains(where: { $0.id == matchedID })
        {
            accountMode = .existing
            selectedExistingAccountID = matchedID
        } else if let ref = working.accountReference,
            let migrated = uniqueSuffixMatch(normalizedReference: ref, in: accounts)
        {
            accountMode = .existing
            selectedExistingAccountID = migrated.id
        } else {
            accountMode = .createNew
            selectedExistingAccountID = nil
        }

        let initialRef = working.accountReference
        let isVPA = initialRef?.contains("@") == true
        let defaultName =
            initialRef.map {
                $0.contains("@") ? "UPI account \($0)" : "Account ••\($0.suffix(4))"
            } ?? ""
        let defaultSuffix = isVPA ? "" : (initialRef ?? "")
        var newAccountName = defaultName
        var newAccountBank = details.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        var newAccountKind: AccountKind = isVPA ? .account : .card
        var newAccountSuffix = defaultSuffix
        var lastAutoAccountName = defaultName
        var lastAutoAccountSuffix = defaultSuffix

        for correction in details.draftCorrections {
            switch correction.field {
            case "currency":
                let code = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if PrimaryCurrencySettings.supportedCodes.contains(code) {
                    working.currency = code
                }
            case "amount":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    working.amountMinorUnits = nil
                    selections[.amount] = nil
                } else if let span = verify(correction.scalarEvidence, in: details.rawBody),
                    let minor = Int64(correction.newValue),
                    minor > 0
                {
                    working.amountMinorUnits = minor
                    selections[.amount] = span
                }
            case "direction":
                if correction.newValue.isEmpty {
                    working.direction = nil
                    selections[.direction] = nil
                } else if ["debit", "credit"].contains(correction.newValue) {
                    working.direction = correction.newValue
                    selections[.direction] = verify(correction.scalarEvidence, in: details.rawBody)
                }
            case "account":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    working.accountReference = nil
                    selections[.account] = nil
                } else if let span = verify(correction.scalarEvidence, in: details.rawBody),
                    let normalized = SmsExtractorNormalizer.normalizeAccount(span.text)
                {
                    working.accountReference = normalized
                    selections[.account] = span
                }
            case "counterparty":
                if correction.newValue.isEmpty && correction.scalarEvidence == nil {
                    working.counterparty = nil
                    selections[.counterparty] = nil
                } else if let span = verify(correction.scalarEvidence, in: details.rawBody),
                    let normalized = SmsExtractorNormalizer.normalizeCounterparty(span.text)
                {
                    working.counterparty = normalized
                    selections[.counterparty] = span
                }
            case "account_id":
                if let uuid = UUID(uuidString: correction.newValue),
                    accounts.contains(where: { $0.id == uuid })
                {
                    accountMode = .existing
                    selectedExistingAccountID = uuid
                }
            case "new_account_name":
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    accountMode = .createNew
                    selectedExistingAccountID = nil
                    newAccountName = value
                    lastAutoAccountName = ""
                }
            case "new_account_bank":
                newAccountBank = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            case "new_account_kind":
                if let kind = AccountKind(rawValue: correction.newValue) {
                    newAccountKind = kind
                }
            case "new_account_suffix":
                let value = correction.newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                newAccountSuffix = value
                lastAutoAccountSuffix = ""
            default:
                continue
            }
        }

        return ReviewSeedState(
            working: working,
            selections: selections,
            accountMode: accountMode,
            selectedExistingAccountID: selectedExistingAccountID,
            newAccountName: newAccountName,
            newAccountBank: newAccountBank,
            newAccountKind: newAccountKind,
            newAccountSuffix: newAccountSuffix,
            lastAutoAccountName: lastAutoAccountName,
            lastAutoAccountSuffix: lastAutoAccountSuffix,
            matchingAccountIDs: initialMatchingIDs
        )
    }

    static func uniqueSuffixMatch(normalizedReference: String, in accounts: [Account]) -> Account? {
        guard !normalizedReference.contains("@") else { return nil }
        let matches = accounts.filter { account in
            guard let suffix = account.suffix?.filter({ $0.isASCII && $0.isNumber }), !suffix.isEmpty else {
                return false
            }
            if suffix == normalizedReference {
                return true
            }
            return suffix.count >= 4
                && normalizedReference.count >= 4
                && suffix.suffix(4) == normalizedReference.suffix(4)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func verify(_ span: UnicodeScalarSpan?, in source: String) -> UnicodeScalarSpan? {
        guard let span else { return nil }
        return try? UnicodeScalarSpan(
            source: source,
            startScalar: span.startScalar,
            endScalar: span.endScalar,
            text: span.text
        )
    }
}

private struct ReviewFieldSummaryBadge: View {
    let field: SmsReviewField
    let value: String
    let highlighted: Bool
    let assigned: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(highlighted ? field.accentColor : Color.secondary)
                Text(value)
                    .font(.subheadline.weight(assigned ? .semibold : .regular))
                    .foregroundStyle(assigned ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                highlighted ? field.highlightBackgroundColor : Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10)
            )

            if assigned {
                Button("Clear", action: onClear)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-clear-\(field.wireName)")
            }
        }
    }
}
