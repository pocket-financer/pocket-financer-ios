import SwiftData
import SwiftUI

struct AlertProcessingDetailView: View {
    @Bindable var alert: InboxAlert
    var transaction: Transaction?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \SmsProcessingOperation.createdAt, order: .reverse) private var allSmsOperations:
        [SmsProcessingOperation]
    @Query(sort: \SmsProcessingTraceEvent.sequence) private var allSmsTraceEvents: [SmsProcessingTraceEvent]
    @Query(sort: \SmsReviewCase.updatedAt, order: .reverse) private var allSmsReviewCases: [SmsReviewCase]
    @Query(sort: \SmsSelectorAttempt.startedAt, order: .reverse) private var allSmsSelectorAttempts:
        [SmsSelectorAttempt]
    @Query(sort: \SmsPersistenceDecision.createdAt, order: .reverse) private var allPersistenceDecisions:
        [SmsPersistenceDecision]

    @State private var fetchedTransaction: Transaction?
    @State private var modelDiagnostic: ModelDiagnostic?
    @State private var retrying = false
    @State private var resultMessage: String?

    private var acceptedTransaction: Transaction? {
        transaction ?? fetchedTransaction
    }

    private var acceptedAccount: Account? {
        guard let accountID = acceptedTransaction?.accountID else { return nil }
        return accounts.first { $0.id == accountID }
    }

    private var canRetry: Bool {
        !alert.rawBody.isEmpty
            && (alert.status == .pending || alert.status == .processing || alert.status == .needsReview)
    }

    private var operation: SmsProcessingOperation? {
        allSmsOperations.first { $0.sourceAlertID == alert.id }
    }

    private var traceEvents: [SmsProcessingTraceEvent] {
        guard let operationID = operation?.id else { return [] }
        return allSmsTraceEvents.filter { $0.operationID == operationID }.sorted { $0.sequence < $1.sequence }
    }

    private var reviewCase: SmsReviewCase? {
        allSmsReviewCases.first { $0.sourceAlertID == alert.id }
    }

    private var selectorAttempt: SmsSelectorAttempt? {
        guard let operationID = operation?.id else { return nil }
        return allSmsSelectorAttempts.first { $0.operationID == operationID }
    }

    private var persistenceDecision: SmsPersistenceDecision? {
        guard let operationID = operation?.id else { return nil }
        return allPersistenceDecisions.first { $0.operationID == operationID }
    }

    var body: some View {
        List {
            outcomeSection
            reviewSection
            decisionTraceSection
            databaseSection
            sourceEvidenceSection
            technicalAuditSection
            retrySection
        }
        .navigationTitle("What Happened")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("processing-trace")
        .task {
            loadLinkedTransaction()
            await loadModelDiagnostic()
        }
        .alert(
            "Pocket Financer",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var outcomeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label(outcomeTitle, systemImage: outcomeIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(outcomeColor)

                Text(outcomeDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let retentionState = operation?.retentionState ?? alert.rejectionCode {
                    LabeledContent("Retention state", value: retentionState)
                        .font(.caption)
                }

                if let transaction = acceptedTransaction {
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            CurrencyFormatter.string(
                                minorUnits: transaction.amountMinorUnits,
                                currencyCode: transaction.currencyCode
                            )
                        )
                        .font(.title2.bold().monospacedDigit())
                        Spacer()
                        Text(transaction.direction.rawValue.capitalized)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(transaction.direction == .debit ? .orange : .green)
                    }
                    LabeledContent("Account", value: transaction.accountLabel ?? "No account")
                }
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("review-outcome")
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if let reviewCase {
            Section("Action needed") {
                NavigationLink {
                    ReviewCorrectionView(
                        reviewCase: reviewCase,
                        onFinished: { dismiss() }
                    )
                } label: {
                    Label("Review, correct, retry, or reject", systemImage: "checklist")
                        .font(.headline)
                }
                .accessibilityIdentifier("open-review-correction")
            }
        }
        if let transaction = acceptedTransaction, transaction.reviewState == .needsReview {
            Section {
                NavigationLink {
                    TransactionDetailView(transaction: transaction)
                } label: {
                    Label("Review and confirm saved transaction", systemImage: "checkmark.circle")
                        .font(.headline)
                }
                .accessibilityIdentifier("open-transaction-review")
            } header: {
                Text("Review required")
            } footer: {
                Text(
                    "Confirm the saved transaction values and linked account."
                )
            }
        }
    }

    @ViewBuilder
    private var decisionTraceSection: some View {
        if let operation {
            Section {
                LabeledContent("Pipeline contract", value: operation.contractReleaseID)
                LabeledContent("Operation state", value: operation.stateRawValue)
                if let persistenceDecision {
                    LabeledContent("Gate result", value: persistenceDecision.result)
                    LabeledContent("Primary reason", value: persistenceDecision.primaryReason)
                }
                if !traceEvents.isEmpty {
                    DecisionTraceTimeline(events: traceEvents)
                }
            } header: {
                Text("Decision Trace")
            } footer: {
                Text(
                    "Stored prefilter, extraction, grounding, duplicate-window, and settlement stages."
                )
            }
        }
    }

    private var databaseSection: some View {
        Section {
            if let transaction = acceptedTransaction {
                DisclosureGroup("Transaction row") {
                    VStack(alignment: .leading, spacing: 8) {
                        TraceValue("id", transaction.id.uuidString.lowercased())
                        TraceValue("amountMinorUnits", "\(transaction.amountMinorUnits)")
                        TraceValue("currencyCode", transaction.currencyCode)
                        TraceValue("direction", transaction.directionRawValue)
                        TraceValue("merchant", transaction.merchant)
                        TraceValue("occurredAt", databaseDate(transaction.occurredAt))
                        TraceValue("accountID", uuid(transaction.accountID))
                        TraceValue("accountLabel", transaction.accountLabel ?? "nil")
                        TraceValue("parserName", transaction.parserName)
                        TraceValue("reviewStateRawValue", transaction.reviewStateRawValue)
                        TraceValue("sourceAlertID", transaction.sourceAlertID.uuidString.lowercased())
                        TraceValue("amountEvidenceText", transaction.amountEvidenceText)
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("database-transaction-record")
            } else {
                Label("No Transaction row was written", systemImage: "nosign")
                    .foregroundStyle(.secondary)
            }

            if let account = acceptedAccount {
                DisclosureGroup("Account row") {
                    VStack(alignment: .leading, spacing: 8) {
                        TraceValue("id", account.id.uuidString.lowercased())
                        TraceValue("name", account.name)
                        TraceValue("bank", account.bank)
                        TraceValue("kindRawValue", account.kindRawValue)
                        TraceValue("suffix", account.suffix ?? "nil")
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("database-account-record")
            }
        } header: {
            Text("Exact current database values")
        }
    }

    private var sourceEvidenceSection: some View {
        Section {
            DisclosureGroup("Exact source SMS and metadata") {
                if alert.rawBody.isEmpty {
                    Label(
                        "Body erased into privacy-safe tombstone",
                        systemImage: "eraser.fill"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Source app", value: alert.sourceApplication ?? "Not supplied")
                    LabeledContent(
                        "Sender",
                        value: alert.sender.isEmpty ? "Not supplied" : alert.sender
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Exact SMS body")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(alert.rawBody)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("source-message-body")
                    }
                }
            }
        } header: {
            Text("Source evidence")
        } footer: {
            Text("Local input used for deterministic prefiltering, model extraction, and validation.")
        }
    }

    private var technicalAuditSection: some View {
        Section("Technical audit") {
            DisclosureGroup("Current model runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    TraceValue("Pipeline", SmsContractAssets.releaseID)
                    TraceValue("System model API", "SystemLanguageModel.default")
                    if let diagnostic = modelDiagnostic {
                        TraceValue("Availability", diagnostic.title)
                        TraceValue(
                            "Checked model locale",
                            "\(diagnostic.localeIdentifier) (supported: \(diagnostic.localeWasSupported))"
                        )
                    } else {
                        TraceValue(
                            "Checked model locale",
                            ModelDiagnostics.modelProcessingLocaleIdentifier
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            DisclosureGroup("Extractor attempt") {
                VStack(alignment: .leading, spacing: 10) {
                    TraceValue("Generation mode", "Direct guided flat schema")
                    TraceValue("Decoding", "Greedy")
                    TraceValue(
                        "Pinned instructions",
                        (try? FoundationSmsExtractor.instructions()) ?? "Unavailable"
                    )
                    if let selectorAttempt {
                        TraceValue("Completion", selectorAttempt.completionRawValue)
                        TraceValue(
                            "Validation result",
                            selectorAttempt.safeErrorCode ?? "Validated"
                        )
                        TraceValue("Stored request", selectorAttempt.requestJSON)
                        if let rawOutput = selectorAttempt.rawOutput {
                            TraceValue("Stored response", rawOutput)
                        }
                    } else {
                        Text("No model attempt was recorded for this alert.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            DisclosureGroup("What Apple does not expose") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "Token counts, probabilities, KV-cache state, and hidden chain-of-thought "
                            + "are not exposed by the public iOS 26 Foundation Models API."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var retrySection: some View {
        if canRetry {
            Section {
                Button {
                    Task { await retry() }
                } label: {
                    Label(
                        retrying ? "Retrying locally…" : "Retry Local Processing",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(retrying)
                .accessibilityIdentifier("retry-alert-processing")
            }
        }
    }

    private var outcomeTitle: String {
        if let transaction = acceptedTransaction {
            return transaction.reviewState == .confirmed
                ? "Saved and confirmed"
                : "Saved — confirmation needed"
        }
        switch alert.status {
        case .pending:
            return "Saved for local retry"
        case .processing:
            return "Processing on this iPhone"
        case .needsReview:
            return "Not saved — review needed"
        case .rejected:
            return "Tombstoned — no transaction"
        case .duplicate:
            return "Duplicate — no new transaction"
        case .imported:
            return "Transaction link unavailable"
        }
    }

    private var outcomeDetail: String {
        if acceptedTransaction != nil {
            return "The validated extraction was written to local transaction and account records."
        }
        if let code = alert.lastErrorCode {
            let presentation = AlertProcessingDiagnostics.presentation(for: code)
            return "\(presentation.title): \(presentation.detail)"
        }
        if let code = alert.rejectionCode {
            let presentation = AlertProcessingDiagnostics.presentation(for: code)
            return "\(presentation.title): \(presentation.detail)"
        }
        return "No transaction row is linked to this alert."
    }

    private var outcomeIcon: String {
        if acceptedTransaction != nil {
            return "externaldrive.fill.badge.checkmark"
        }
        switch alert.status {
        case .pending:
            return "clock.fill"
        case .processing:
            return "apple.intelligence"
        case .imported:
            return "checkmark.circle.fill"
        case .needsReview:
            return "exclamationmark.triangle.fill"
        case .rejected:
            return "xmark.shield.fill"
        case .duplicate:
            return "doc.on.doc.fill"
        }
    }

    private var outcomeColor: Color {
        if acceptedTransaction?.reviewState == .confirmed { return .green }
        if acceptedTransaction != nil || alert.status == .needsReview { return .orange }
        switch alert.status {
        case .pending, .processing:
            return .blue
        case .imported:
            return .green
        case .rejected, .duplicate:
            return .secondary
        case .needsReview:
            return .orange
        }
    }

    private func loadLinkedTransaction() {
        guard transaction == nil, let transactionID = alert.transactionID else { return }
        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        fetchedTransaction = transactions.first { $0.id == transactionID }
    }

    private func loadModelDiagnostic() async {
        guard modelDiagnostic == nil else { return }
        let diagnostic = await ModelDiagnostics.loadCurrent()
        guard !Task.isCancelled else { return }
        modelDiagnostic = diagnostic
    }

    private func retry() async {
        retrying = true
        defer { retrying = false }

        do {
            let service = AlertIngestionService(context: modelContext)
            let receipt = try await service.retry(alertID: alert.id)
            loadLinkedTransaction()
            resultMessage = receipt.safeDialog
        } catch {
            resultMessage = "The retry could not be saved locally. The retained alert is unchanged."
        }
    }

    private func uuid(_ value: UUID?) -> String {
        value?.uuidString.lowercased() ?? "nil"
    }

    private func databaseDate(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct TraceValue: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
