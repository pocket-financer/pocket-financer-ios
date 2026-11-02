import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    @Bindable var transaction: Transaction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var sourceAlert: InboxAlert?
    @State private var showingEdit = false
    @State private var showingDelete = false
    @State private var deletionError: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(
                        systemName: transaction.direction == .debit
                            ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill"
                    )
                    .font(.system(size: 50))
                    .foregroundStyle(transaction.direction == .debit ? .orange : .green)
                    Text(
                        CurrencyFormatter.string(
                            minorUnits: transaction.amountMinorUnits,
                            currencyCode: transaction.currencyCode
                        )
                    )
                    .font(.largeTitle.bold().monospacedDigit())
                    Text(transaction.merchant)
                        .font(.title3.weight(.semibold))
                    if transaction.reviewState == .needsReview {
                        Label(transaction.ownerReviewReason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if transaction.reviewState == .needsReview {
                Section {
                    Label(
                        "Already saved to \(transaction.accountLabel ?? "an unknown account")",
                        systemImage: "externaldrive.fill.badge.checkmark"
                    )
                    .font(.subheadline.weight(.semibold))

                    Text(transaction.ownerReviewReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        showingEdit = true
                    } label: {
                        Label("Review & Confirm", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("review-and-confirm-transaction")
                } header: {
                    Text("Review Required")
                } footer: {
                    Text("Confirming keeps the original model output and evidence in the processing history.")
                }
            }

            Section("Details") {
                LabeledContent("Direction", value: transaction.direction.rawValue.capitalized)
                LabeledContent("Account", value: transaction.accountLabel ?? "Unknown")
                LabeledContent("Date") {
                    Text(transaction.occurredAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Parser", value: transaction.parserName)
                if transaction.isEdited {
                    LabeledContent("Correction", value: "Edited manually")
                }
            }

            if let sourceAlert, !sourceAlert.rawBody.isEmpty {
                Section("Local evidence") {
                    if !sourceAlert.sender.isEmpty {
                        LabeledContent("Sender", value: sourceAlert.sender)
                    }
                    Text(sourceAlert.rawBody)
                        .font(.callout)
                        .textSelection(.enabled)
                    LabeledContent(
                        transaction.isEdited ? "Original extracted amount evidence" : "Amount evidence",
                        value: transaction.amountEvidenceText
                    )
                    if let dateEvidenceText = transaction.dateEvidenceText {
                        LabeledContent(
                            transaction.isEdited ? "Original extracted date evidence" : "Date evidence",
                            value: dateEvidenceText
                        )
                    }
                }
            }

            if let sourceAlert {
                Section("Processing") {
                    NavigationLink {
                        AlertProcessingDetailView(
                            alert: sourceAlert,
                            transaction: transaction
                        )
                    } label: {
                        Label("Model & Processing Details", systemImage: "apple.intelligence")
                    }
                }
            }

            Section {
                Button("Delete Transaction", role: .destructive) {
                    showingDelete = true
                }
            }
        }
        .navigationTitle(transaction.reviewState == .needsReview ? "Review Transaction" : "Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(transaction.reviewState == .needsReview ? "Review" : "Edit") { showingEdit = true }
        }
        .sheet(isPresented: $showingEdit) {
            TransactionEditView(transaction: transaction)
        }
        .confirmationDialog(
            "Delete this transaction?",
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Transaction", role: .destructive) { deleteTransaction() }
        } message: {
            Text("Its source alert remains locally available for review.")
        }
        .alert(
            "Transaction Not Deleted",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .task { loadSourceAlert() }
    }

    private func loadSourceAlert() {
        sourceAlert = try? fetchSourceAlert()
    }

    private func deleteTransaction() {
        do {
            if let persistedSourceAlert = try fetchSourceAlert() {
                persistedSourceAlert.transactionID = nil
                persistedSourceAlert.status = .needsReview
                persistedSourceAlert.updatedAt = .now
            }
            modelContext.delete(transaction)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            deletionError = "The change could not be saved. Your transaction is still available."
        }
    }

    private func fetchSourceAlert() throws -> InboxAlert? {
        let sourceAlertID = transaction.sourceAlertID
        var descriptor = FetchDescriptor<InboxAlert>(
            predicate: #Predicate { $0.id == sourceAlertID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

private struct TransactionEditView: View {
    @Bindable var transaction: Transaction
    @Query(sort: \Account.name) private var accounts: [Account]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var amountText: String
    @State private var merchant: String
    @State private var direction: TransactionDirection
    @State private var occurredAt: Date
    @State private var selectedAccountID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(transaction: Transaction) {
        self.transaction = transaction
        _amountText = State(initialValue: NSDecimalNumber(decimal: transaction.decimalAmount).stringValue)
        _merchant = State(initialValue: transaction.merchant)
        _direction = State(initialValue: transaction.direction)
        _occurredAt = State(initialValue: transaction.occurredAt)
        _selectedAccountID = State(initialValue: transaction.accountID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("transaction-amount-field")
                    TextField("Merchant", text: $merchant)
                        .accessibilityIdentifier("transaction-merchant-field")
                    Picker("Direction", selection: $direction) {
                        Text("Debit").tag(TransactionDirection.debit)
                        Text("Credit").tag(TransactionDirection.credit)
                    }
                    DatePicker("Date", selection: $occurredAt)
                }

                Section {
                    Picker("Save against", selection: $selectedAccountID) {
                        Text("Choose an account").tag(nil as UUID?)
                        if let selectedAccountID,
                            !accounts.contains(where: { $0.id == selectedAccountID })
                        {
                            Text("Unavailable — \(transaction.accountLabel ?? "choose another account")")
                                .tag(Optional(selectedAccountID))
                        }
                        ForEach(accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("transaction-account-picker")

                    if accounts.isEmpty {
                        Text("No local account records are available for selection.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("The confirmed amount will be saved against this account.")
                }
            }
            .navigationTitle(transaction.reviewState == .needsReview ? "Review Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("save-transaction-edit")
                }
            }
            .alert(
                "Transaction Not Saved",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .sensitiveSceneCover()
    }

    private func save() {
        guard
            let minorUnits = try? AmountParser.minorUnits(
                from: "\(transaction.currencyCode) \(amountText)",
                currencyCode: transaction.currencyCode
            )
        else {
            errorMessage = "Enter a positive amount with no more than two decimal places."
            return
        }

        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMerchant.isEmpty else {
            errorMessage = "Enter a merchant or counterparty name."
            return
        }

        guard
            let selectedAccountID,
            let selectedAccount = accounts.first(where: { $0.id == selectedAccountID })
        else {
            errorMessage = "Choose an existing account for this transaction."
            return
        }

        do {
            guard try fetchSourceAlert() != nil else {
                errorMessage = "The source alert is missing, so this review cannot be saved safely."
                return
            }
            let transactionID = transaction.id
            let revisions = try modelContext.fetch(
                FetchDescriptor<SmsTransactionRevision>(
                    predicate: #Predicate { $0.transactionID == transactionID }
                )
            )
            let previous = revisions.filter(\.isCurrentProjection).max {
                $0.revision < $1.revision
            }
            let corrections = makeCorrections(
                minorUnits: minorUnits,
                merchant: trimmedMerchant,
                direction: direction,
                occurredAt: occurredAt,
                accountID: selectedAccount.id,
                previousRevisionID: previous?.id
            )
            let command = TransactionProjectionEditCommand(
                actionID: UUID(),
                transactionID: transactionID,
                expectedRevision: previous?.revision ?? -1,
                amountMinorUnits: minorUnits,
                currencyCode: transaction.currencyCode,
                direction: direction,
                merchant: trimmedMerchant,
                accountID: selectedAccount.id,
                occurredAt: occurredAt,
                corrections: corrections
            )
            isSaving = true
            let container = modelContext.container
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    _ = try await SmsProcessingStore(modelContainer: container)
                        .editTransactionProjection(command)
                    dismiss()
                } catch {
                    errorMessage =
                        "The correction could not be saved. The previous transaction remains unchanged."
                }
            }
        } catch {
            errorMessage = "The source or revision history could not be loaded. No changes were saved."
        }
    }

    private func makeCorrections(
        minorUnits: Int64,
        merchant: String,
        direction: TransactionDirection,
        occurredAt: Date,
        accountID: UUID,
        previousRevisionID: UUID?
    ) -> [SmsFieldCorrection] {
        var corrections: [SmsFieldCorrection] = []
        func append(_ field: String, _ value: String) {
            corrections.append(
                SmsFieldCorrection(
                    field: field,
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: previousRevisionID,
                    candidateID: nil,
                    evidence: nil,
                    newValue: value
                )
            )
        }
        if transaction.amountMinorUnits != minorUnits {
            append("amount_minor_units", String(minorUnits))
        }
        if transaction.merchant != merchant { append("counterparty", merchant) }
        if transaction.direction != direction { append("direction", direction.rawValue) }
        if transaction.occurredAt != occurredAt {
            append(
                "occurred_at_epoch_ms",
                String(Int64((occurredAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)))
            )
        }
        if transaction.accountID != accountID { append("account_id", accountID.uuidString) }
        return corrections
    }

    private func fetchSourceAlert() throws -> InboxAlert? {
        let sourceAlertID = transaction.sourceAlertID
        var descriptor = FetchDescriptor<InboxAlert>(
            predicate: #Predicate { $0.id == sourceAlertID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
