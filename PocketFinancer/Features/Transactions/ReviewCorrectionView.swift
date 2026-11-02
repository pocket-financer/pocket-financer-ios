import SwiftData
import SwiftUI

struct ReviewCorrectionView: View {
    let reviewCase: SmsReviewCase
    var onFinished: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var amount = ""
    @State private var merchant = ""
    @State private var currency = PrimaryCurrencySettings.currentCode
    @State private var direction: TransactionDirection?
    @State private var accountID: UUID?
    @State private var occurredAt = Date.now
    @State private var createNewAccount = false
    @State private var newAccountName = ""
    @State private var newAccountBank = ""
    @State private var newAccountKind = AccountKind.account
    @State private var newAccountSuffix = ""
    @State private var groundedProposal: ReconstructedSmsTransaction?
    @State private var groundedProposalAccountID: UUID?
    @State private var v4OriginalProposal: SmsReviewProposal?
    @State private var v4Proposal: SmsReviewProposal?
    @State private var v4DraftCorrections: [SmsFieldCorrection]?
    @State private var sourceAlert: InboxAlert?
    @State private var invalidV4Proposal = false
    @State private var errorMessage: String?
    @State private var saving = false

    var body: some View {
        Group {
            if let original = v4OriginalProposal,
                let proposal = v4Proposal,
                let sourceAlert
            {
                GroundedReviewCorrectionView(
                    original: original,
                    initial: proposal,
                    source: sourceAlert.rawBody,
                    sender: sourceAlert.sender,
                    reasonCodes: reviewCase.reasonCodesRawValue.split(separator: "\n").map(String.init),
                    resolvedAccountName: proposal.resolvedAccountID.flatMap { id in
                        accounts.first { $0.id == id }?.name
                    },
                    draftCorrections: v4DraftCorrections,
                    saving: saving,
                    onResolve: resolveGrounded
                )
            } else if invalidV4Proposal {
                invalidGroundedBody
            } else {
                legacyBody
            }
        }
        .onAppear(perform: loadInitialState)
        .alert(
            "Could not complete review",
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

    private var invalidGroundedBody: some View {
        Form {
            Section {
                Label("The on-device result could not be verified", systemImage: "exclamationmark.shield")
                    .font(.headline)
                Text(
                    "Nothing can be saved from this result. Retry local extraction or mark the alert as not a transaction."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Button("Retry extraction") { resolve(.retry, retry: "current") }
                    .disabled(saving)
                Button("Not a transaction", role: .destructive) { resolve(.reject) }
                    .disabled(saving)
            }
        }
        .navigationTitle("Review transaction")
    }

    private var legacyBody: some View {
        Form {
            Section {
                Label(outcomeTitle, systemImage: outcomeIcon)
                    .font(.headline)
                    .foregroundStyle(groundedProposal == nil ? .orange : .primary)
                    .accessibilityIdentifier("review-outcome-title")
                Text(outcomeDetail)
                    .foregroundStyle(.secondary)
            }

            if let groundedProposal {
                Section("On-device proposal") {
                    LabeledContent(
                        "Amount",
                        value: CurrencyFormatter.string(
                            minorUnits: groundedProposal.minorUnits,
                            currencyCode: groundedProposal.currency
                        )
                    )
                    LabeledContent("Type", value: groundedProposal.direction.capitalized)
                    LabeledContent(
                        "Counterparty",
                        value: groundedProposal.counterpartyEvidence?.text ?? "Not supplied"
                    )
                    if let accountName = groundedProposalAccountName {
                        LabeledContent("Account", value: accountName)
                    } else {
                        Label(
                            "Choose an account below before adding this transaction.",
                            systemImage: "person.crop.circle.badge.questionmark"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if canConfirmGroundedProposal {
                        Button("Add proposed transaction") { resolve(.confirm) }
                            .disabled(saving)
                            .accessibilityIdentifier("review-confirm-proposal")
                    }
                }
            }

            Section(groundedProposal == nil ? "Enter transaction" : "Edit before adding") {
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("review-manual-amount")
                Picker("Currency", selection: $currency) {
                    ForEach(PrimaryCurrencySettings.supportedCodes, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Picker("Type", selection: $direction) {
                    Text("Choose Credit or Debit").tag(TransactionDirection?.none)
                    ForEach(TransactionDirection.allCases) { value in
                        Text(value.rawValue.capitalized).tag(Optional(value))
                    }
                }
                .accessibilityIdentifier("review-manual-direction")
                TextField("Merchant or counterparty", text: $merchant)
                    .accessibilityIdentifier("review-manual-counterparty")
                DatePicker("Transaction time", selection: $occurredAt)
                Text("Enter the amount normally—for example, 100.00—not in paise or other minor units.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            accountSection

            Section {
                Button(groundedProposal == nil ? "Add transaction manually" : "Add edited transaction") {
                    resolve(.correct)
                }
                .disabled(!manualEntryIsValid || saving)
                .accessibilityIdentifier("review-add-manual-transaction")

                if let manualEntryProblem {
                    Text(manualEntryProblem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Save draft") { resolve(.saveDraft) }
                    .disabled(saving)
            }

            Section("Other options") {
                Button("Try on-device processing again") {
                    resolve(.retry, retry: "current")
                }
                .disabled(saving)
                Button("Retry with original settings") {
                    resolve(.retry, retry: "original")
                }
                .disabled(saving)
                Button("Ignore this alert", role: .destructive) { resolve(.reject) }
                    .disabled(saving)
            }

            Section("Technical details") {
                DisclosureGroup("Reason codes") {
                    ForEach(reviewCase.reasonCodesRawValue.split(separator: "\n"), id: \.self) {
                        Text(String($0))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Review revision", value: "\(reviewCase.revision)")
            }
        }
        .navigationTitle(groundedProposal == nil ? "Add transaction" : "Review transaction")
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if !accounts.isEmpty {
                Toggle("Create a new account", isOn: $createNewAccount)
                if !createNewAccount {
                    Picker("Owned account", selection: $accountID) {
                        Text("Select an account").tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    .accessibilityIdentifier("review-existing-account")
                }
            } else {
                Label(
                    "Create your first account to identify where this transaction belongs.",
                    systemImage: "building.columns"
                )
                .foregroundStyle(.secondary)
            }

            if accounts.isEmpty || createNewAccount {
                TextField("Account name", text: $newAccountName)
                    .accessibilityIdentifier("review-new-account-name")
                TextField("Bank name (optional)", text: $newAccountBank)
                Picker("Account type", selection: $newAccountKind) {
                    ForEach(AccountKind.allCases) { kind in
                        Text(kind.rawValue.capitalized).tag(kind)
                    }
                }
                TextField("Last digits (optional)", text: $newAccountSuffix)
                    .keyboardType(.numberPad)
                Text("The account is created only when you add the transaction.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outcomeTitle: String {
        groundedProposal == nil
            ? "The model result could not be verified"
            : "Check the proposed transaction"
    }

    private var outcomeIcon: String {
        groundedProposal == nil ? "exclamationmark.shield" : "checkmark.shield"
    }

    private var outcomeDetail: String {
        if groundedProposal == nil {
            return
                "Nothing was added. Enter the transaction yourself below, try local processing again, or ignore this alert."
        }
        return "The on-device model produced a grounded proposal. Automatic saving is off, so you remain in control."
    }

    private var groundedProposalAccountName: String? {
        guard let groundedProposalAccountID else { return nil }
        return accounts.first { $0.id == groundedProposalAccountID }?.name
    }

    private var canConfirmGroundedProposal: Bool {
        groundedProposal != nil && groundedProposalAccountName != nil
    }

    private var manualMinorUnits: Int64? {
        CurrencyFormatter.minorUnits(
            fromMajorUnitText: amount,
            currencyCode: currency
        )
    }

    private var manualAccountIsValid: Bool {
        if accounts.isEmpty || createNewAccount {
            let suffix = newAccountSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return !newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (suffix.isEmpty
                    || (suffix.count >= 2 && suffix.count <= 8 && suffix.allSatisfy(\.isNumber)))
        }
        return accountID != nil
    }

    private var manualEntryIsValid: Bool {
        manualMinorUnits != nil
            && direction != nil
            && !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && manualAccountIsValid
    }

    private var manualEntryProblem: String? {
        var missing: [String] = []
        if manualMinorUnits == nil { missing.append("a valid amount") }
        if direction == nil { missing.append("Credit or Debit") }
        if merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("a merchant or counterparty")
        }
        if !manualAccountIsValid {
            missing.append(accounts.isEmpty || createNewAccount ? "an account name" : "an account")
        }
        guard !missing.isEmpty else { return nil }
        return "To add this transaction, provide " + missing.joined(separator: ", ") + "."
    }

    private func resolve(_ kind: ReviewCommandKind, retry: String? = nil) {
        saving = true
        let corrections: [SmsFieldCorrection]
        if kind == .correct {
            guard let minorUnits = manualMinorUnits, let direction else {
                saving = false
                return
            }
            corrections = manualCorrections(
                amountField: "amount_minor_units",
                amountValue: String(minorUnits),
                direction: direction
            )
        } else if kind == .saveDraft {
            corrections = manualCorrections(
                amountField: "amount_major_units",
                amountValue: amount,
                direction: direction
            )
        } else {
            corrections = []
        }
        let command = ReviewCommand(
            actionID: UUID(),
            reviewCaseID: reviewCase.id,
            expectedRevision: reviewCase.revision,
            kind: kind,
            corrections: corrections,
            retryConfiguration: retry
        )
        Task { @MainActor in
            defer { saving = false }
            do {
                let store = SmsProcessingStore(modelContainer: modelContext.container)
                _ = try await store.resolveReview(command)
                if kind == .retry, let retry {
                    _ = try await AlertIngestionService(context: modelContext).retry(
                        alertID: reviewCase.sourceAlertID,
                        parentOperationID: reviewCase.currentOperationID,
                        configurationMode: retry
                    )
                }
                finish()
            } catch SmsProcessingStoreError.invalidCommand {
                errorMessage =
                    "The requested action is not available for this alert. Nothing was saved."
            } catch {
                errorMessage =
                    "The review changed or the local store was unavailable. Nothing was saved. Reopen the alert and try again."
            }
        }
    }

    private func resolveGrounded(
        _ kind: ReviewCommandKind,
        _ corrections: [SmsFieldCorrection],
        _ retry: String?
    ) {
        saving = true
        let command = ReviewCommand(
            actionID: UUID(),
            reviewCaseID: reviewCase.id,
            expectedRevision: reviewCase.revision,
            kind: kind,
            corrections: corrections,
            retryConfiguration: retry
        )
        Task { @MainActor in
            defer { saving = false }
            do {
                let store = SmsProcessingStore(modelContainer: modelContext.container)
                _ = try await store.resolveReview(command)
                if kind == .retry, let retry {
                    _ = try await AlertIngestionService(context: modelContext).retry(
                        alertID: reviewCase.sourceAlertID,
                        parentOperationID: reviewCase.currentOperationID,
                        configurationMode: retry
                    )
                }
                finish()
            } catch SmsProcessingStoreError.invalidCommand {
                errorMessage = "The selected source evidence is no longer valid. Nothing was saved."
            } catch {
                errorMessage =
                    "The review changed or the local store was unavailable. Nothing was saved. Reopen the alert and try again."
            }
        }
    }

    private func finish() {
        if let onFinished { onFinished() } else { dismiss() }
    }

    private func manualCorrections(
        amountField: String,
        amountValue: String,
        direction: TransactionDirection?
    ) -> [SmsFieldCorrection] {
        var corrections: [SmsFieldCorrection] = []
        func append(_ field: String, _ value: String) {
            corrections.append(
                SmsFieldCorrection(
                    field: field,
                    classification: .suppliedManualUngroundedValue,
                    previousRevisionID: nil,
                    candidateID: nil,
                    evidence: nil,
                    newValue: value
                )
            )
        }
        if !amountValue.isEmpty { append(amountField, amountValue) }
        append("currency", currency)
        if let direction { append("direction", direction.rawValue) }
        if !merchant.isEmpty { append("counterparty", merchant) }
        append(
            "occurred_at_epoch_ms",
            String(Int64(occurredAt.timeIntervalSince1970 * 1_000))
        )
        if accounts.isEmpty || createNewAccount {
            if !newAccountName.isEmpty { append("new_account_name", newAccountName) }
            if !newAccountBank.isEmpty { append("new_account_bank", newAccountBank) }
            append("new_account_kind", newAccountKind.rawValue)
            if !newAccountSuffix.isEmpty { append("new_account_suffix", newAccountSuffix) }
        } else if let accountID {
            append("account_id", accountID.uuidString.lowercased())
        }
        return corrections
    }

    private func loadInitialState() {
        createNewAccount = accounts.isEmpty
        loadGroundedProposal()
        loadDraft()
    }

    private func loadGroundedProposal() {
        let operationID = reviewCase.currentOperationID
        let sourceAlertID = reviewCase.sourceAlertID
        let alert = try? modelContext.fetch(
            FetchDescriptor<InboxAlert>(
                predicate: #Predicate { $0.id == sourceAlertID }
            )
        ).first
        sourceAlert = alert
        let stored = try? modelContext.fetch(
            FetchDescriptor<SmsReconstructedResult>(
                predicate: #Predicate { $0.operationID == operationID }
            )
        ).first
        if let stored, stored.contractVersion == "pocketfinancer.processing-result/3" {
            guard let alert,
                let proposal = SmsReviewProjection.parse(
                    resultJSON: stored.semanticResultJSON,
                    source: alert.rawBody
                )
            else {
                invalidV4Proposal = true
                return
            }
            invalidV4Proposal = false
            v4OriginalProposal = proposal
            v4Proposal = proposal
            occurredAt = proposal.receiptTimestamp
            return
        } else if let stored,
            let resultJSON = stored.semanticResultJSON,
            let result = try? JSONDecoder().decode(
                ReconstructedSmsTransaction.self,
                from: Data(resultJSON.utf8)
            )
        {
            groundedProposal = result
            amount = CurrencyFormatter.editableMajorUnits(
                minorUnits: result.minorUnits,
                currencyCode: result.currency
            )
            currency = result.currency.uppercased()
            direction = TransactionDirection(rawValue: result.direction)
            merchant = result.counterpartyEvidence?.text ?? ""
            if let milliseconds = result.occurredAtEpochMilliseconds {
                occurredAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            }
        } else if let alert {
            occurredAt = alert.receivedAt
        }

        guard
            let decision = try? modelContext.fetch(
                FetchDescriptor<SmsPersistenceDecision>(
                    predicate: #Predicate { $0.operationID == operationID }
                )
            ).first,
            let object = try? JSONSerialization.jsonObject(
                with: Data(decision.accountResolutionJSON.utf8)
            ) as? [String: Any],
            object["result"] as? String == "unique",
            let rawID = object["account_id"] as? String,
            let resolvedID = UUID(uuidString: rawID),
            accounts.contains(where: { $0.id == resolvedID })
        else { return }
        groundedProposalAccountID = resolvedID
        accountID = resolvedID
        createNewAccount = false
    }

    private func loadDraft() {
        guard
            let draftJSON = reviewCase.draftJSON,
            let corrections = try? JSONDecoder().decode(
                [SmsFieldCorrection].self,
                from: Data(draftJSON.utf8)
            )
        else { return }
        if let original = v4OriginalProposal, let sourceAlert {
            v4DraftCorrections = corrections
            v4Proposal = try? SmsReviewProjection.applying(
                corrections.filter {
                    $0.scalarEvidence != nil || $0.field == "counterparty"
                },
                to: original,
                source: sourceAlert.rawBody
            )
            return
        }
        if let savedCurrency = corrections.first(where: { $0.field == "currency" })?.newValue,
            PrimaryCurrencySettings.supportedCodes.contains(savedCurrency)
        {
            currency = savedCurrency
        }
        for correction in corrections {
            switch correction.field {
            case "amount_major_units":
                amount = correction.newValue
            case "amount_minor_units":
                if let value = Int64(correction.newValue) {
                    amount = CurrencyFormatter.editableMajorUnits(
                        minorUnits: value,
                        currencyCode: currency
                    )
                }
            case "counterparty":
                merchant = correction.newValue
            case "currency":
                break
            case "direction":
                direction = TransactionDirection(rawValue: correction.newValue)
            case "account_id":
                accountID = UUID(uuidString: correction.newValue)
                createNewAccount = false
            case "new_account_name":
                newAccountName = correction.newValue
                createNewAccount = true
            case "new_account_bank":
                newAccountBank = correction.newValue
            case "new_account_kind":
                if let value = AccountKind(rawValue: correction.newValue) {
                    newAccountKind = value
                }
            case "new_account_suffix":
                newAccountSuffix = correction.newValue
            case "occurred_at_epoch_ms":
                if let milliseconds = Int64(correction.newValue) {
                    occurredAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                }
            default:
                break
            }
        }
    }
}
