import SwiftData
import SwiftUI

struct AlertProcessingDetailView: View {
    @Bindable var alert: InboxAlert
    var transaction: Transaction?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExtractionRun.startedAt, order: .reverse) private var allExtractionRuns: [ExtractionRun]
    @Query(sort: \StructuredGenerationSnapshot.capturedAt) private var allGenerationSnapshots:
        [StructuredGenerationSnapshot]
    @Query(sort: \DeterministicFilterRun.evaluatedAt, order: .reverse) private var allFilterRuns:
        [DeterministicFilterRun]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \SmsProcessingOperation.createdAt, order: .reverse) private var allSmsOperations:
        [SmsProcessingOperation]
    @Query(sort: \SmsProcessingTraceEvent.sequence) private var allSmsTraceEvents: [SmsProcessingTraceEvent]
    @Query(sort: \SmsReviewCase.updatedAt, order: .reverse) private var allSmsReviewCases: [SmsReviewCase]
    @Query(sort: \SmsSelectorAttempt.startedAt, order: .reverse) private var allSmsSelectorAttempts:
        [SmsSelectorAttempt]

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

    private var extractionRuns: [ExtractionRun] {
        allExtractionRuns.filter { $0.alertID == alert.id }
    }

    private var latestRun: ExtractionRun? {
        extractionRuns.first
    }

    private var currentTransactionAcceptingRun: ExtractionRun? {
        guard let transactionID = acceptedTransaction?.id else { return nil }
        return extractionRuns.first { $0.acceptedTransactionID == transactionID }
    }

    private var filterRuns: [DeterministicFilterRun] {
        allFilterRuns.filter { $0.alertID == alert.id }
    }

    private var latestFilterRun: DeterministicFilterRun? {
        filterRuns.first
    }

    private var pipelineRun: ExtractionRun? {
        guard let extractionRunID = latestFilterRun?.extractionRunID else { return nil }
        return extractionRuns.first { $0.id == extractionRunID }
    }

    private var latestSnapshots: [StructuredGenerationSnapshot] {
        snapshots(for: latestRun)
    }

    private var pipelineSnapshots: [StructuredGenerationSnapshot] {
        snapshots(for: pipelineRun)
    }

    private var exactPersistedFilterTrace: AlertFilterTrace? {
        if let latestFilterRun,
            let decision = latestFilterRun.decision,
            let stages = latestFilterRun.stages
        {
            return AlertFilterTrace(
                result: AlertFilterResult(
                    decision: decision,
                    rejectionCode: latestFilterRun.rejectionCode,
                    completedStages: latestFilterRun.completedStages
                ),
                stages: stages,
                senderWasUsed: latestFilterRun.senderWasUsed
            )
        }
        return nil
    }

    private var filterTrace: AlertFilterTrace? {
        if let exactPersistedFilterTrace { return exactPersistedFilterTrace }
        guard !alert.rawBody.isEmpty else { return nil }
        return AlertFilter().trace(sender: alert.sender, body: alert.rawBody)
    }

    private var filterTraceIsPersistedExact: Bool {
        exactPersistedFilterTrace != nil
    }

    private var canRetry: Bool {
        !alert.rawBody.isEmpty
            && (alert.status == .pending || alert.status == .processing || alert.status == .needsReview)
    }

    private var nativeOperation: SmsProcessingOperation? {
        allSmsOperations.first { $0.sourceAlertID == alert.id }
    }

    private var nativeTrace: [SmsProcessingTraceEvent] {
        guard let operationID = nativeOperation?.id else { return [] }
        return allSmsTraceEvents.filter { $0.operationID == operationID }.sorted { $0.sequence < $1.sequence }
    }

    private var nativeReviewCase: SmsReviewCase? {
        allSmsReviewCases.first { $0.sourceAlertID == alert.id }
    }

    private var nativeSelectorAttempt: SmsSelectorAttempt? {
        guard let operationID = nativeOperation?.id else { return nil }
        return allSmsSelectorAttempts.first { $0.operationID == operationID }
    }

    var body: some View {
        List {
            outcomeSection
            reviewSection
            nativeDecisionTraceSection
            pipelineSection
            deterministicFilterSection
            generationSection
            fieldJourneySection
            databaseSection
            sourceEvidenceSection
            attemptHistorySection
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

    @ViewBuilder
    private var nativeDecisionTraceSection: some View {
        if nativeOperation != nil {
            Section {
                DecisionTraceTimeline(events: nativeTrace)
                if let nativeReviewCase {
                    NavigationLink {
                        ReviewCorrectionView(
                            reviewCase: nativeReviewCase,
                            onFinished: { dismiss() }
                        )
                    } label: {
                        Label("Review, correct, retry, or reject", systemImage: "checklist")
                    }
                }
            } header: {
                Text("Decision Trace")
            } footer: {
                Text(
                    "Stored native analyzer and direct-selector stages. Missing runtime metrics are not available, not zero."
                )
            }
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
        if let transaction = acceptedTransaction, transaction.reviewState == .needsReview {
            Section {
                ForEach(reviewReasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }

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
                    "The transaction is already stored against the account shown above. Review lets you correct it and mark it confirmed."
                )
            }
        }
    }

    private var pipelineSection: some View {
        Section {
            ForEach(pipelineStages) { stage in
                PipelineStageRow(stage: stage)
            }
        } header: {
            Text("Pipeline")
        } footer: {
            Text(
                "The Apple model is invoked only after all deterministic eligibility checks pass."
            )
        }
    }

    private var deterministicFilterSection: some View {
        Section {
            DisclosureGroup("Eligibility decision and rule-by-rule trace") {
                if let filterTrace {
                    HStack {
                        Label(
                            filterTraceIsPersistedExact ? "Persisted exact result" : "Reconstructed",
                            systemImage: filterTraceIsPersistedExact
                                ? "externaldrive.badge.checkmark"
                                : "clock.arrow.trianglehead.counterclockwise.rotate.90"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(filterDecisionTitle(filterTrace.result.decision))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(filterDecisionColor(filterTrace.result.decision))
                    }

                    if filterTraceIsPersistedExact, let latestFilterRun {
                        LabeledContent("Rules version", value: latestFilterRun.rulesVersion)
                        LabeledContent("Evaluation", value: latestFilterRun.evaluationIndex.formatted())
                        LabeledContent("Sender used", value: latestFilterRun.senderWasUsed ? "Yes" : "No")
                    } else {
                        Text(
                            latestFilterRun == nil
                                ? "This alert predates persisted filter traces. The rows below were reconstructed with the current rule set."
                                : "The persisted filter row could not be decoded completely. The rows below were reconstructed with the current rule set and are not presented as historical fact."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(filterTrace.stages, id: \.id) { stage in
                        FilterStageRow(stage: stage)
                    }

                    if filterRuns.count > 1 {
                        DisclosureGroup("Earlier filter evaluations (\(filterRuns.count - 1))") {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(filterRuns.dropFirst())) { run in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Evaluation \(run.evaluationIndex)")
                                            .font(.subheadline.weight(.semibold))
                                        TraceValue("evaluatedAt", run.evaluatedAt.ISO8601Format())
                                        TraceValue("rulesVersion", run.rulesVersion)
                                        TraceValue("decision", run.decisionRawValue)
                                        TraceValue("rejectionCode", run.rejectionCodeRawValue ?? "nil")
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Filter trace unavailable",
                        systemImage: "eraser.fill",
                        description: Text(
                            "No persisted trace exists and the source evidence is no longer available for reconstruction."
                        )
                    )
                }
            }
        } header: {
            Text("Deterministic eligibility details")
        } footer: {
            Text(
                "OTP, collect-request, failed-transaction, and promotion checks run before amount, account, and completed-transaction checks. Only an eligible result reaches the model."
            )
        }
    }

    private var generationSection: some View {
        Section {
            DisclosureGroup("Model generation (\(latestSnapshots.count) snapshots)") {
                if !latestSnapshots.isEmpty {
                    StructuredGenerationInspector(
                        snapshots: latestSnapshots,
                        runStartedAt: latestRun?.startedAt
                    )
                    .accessibilityIdentifier("generation-snapshots")
                } else if latestRun != nil {
                    ContentUnavailableView(
                        "No observable snapshot",
                        systemImage: "apple.intelligence",
                        description: Text(generationUnavailableDetail)
                    )
                } else {
                    ContentUnavailableView(
                        "Model not invoked",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This alert has no persisted model attempt.")
                    )
                }

                if let draft = latestRun?.parserDraft {
                    DisclosureGroup("Mapped app fields (ParsedAlertDraft)") {
                        VStack(alignment: .leading, spacing: 8) {
                            TraceValue("classification", draft.classification.rawValue)
                            TraceValue("direction", display(draft.direction))
                            TraceValue("amountText", display(draft.amountText))
                            TraceValue("merchant", display(draft.merchant))
                            TraceValue("accountLabel", display(draft.accountLabel))
                            TraceValue("occurredAtText", display(draft.occurredAtText))
                            TraceValue("currencyCode", display(draft.currencyCode))
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        } header: {
            Text("Progressive structured decoding")
        } footer: {
            Text(
                "These are verbatim cumulative GeneratedContent.jsonString snapshots exposed by Apple's public Foundation Models API. Apple does not expose individual token IDs, logits, probabilities, or hidden reasoning."
            )
        }
    }

    private var fieldJourneySection: some View {
        Section {
            DisclosureGroup("Field-by-field attempt trace") {
                if let draft = latestRun?.parserDraft {
                    FieldJourneyRow(
                        title: "Classification",
                        modelValue: draft.classification.rawValue,
                        verification: verificationText(for: .classification, draft: draft),
                        databaseValue: latestRun?.acceptedTransactionID == nil
                            ? "No value written by this attempt" : "transaction"
                    )
                    FieldJourneyRow(
                        title: "Direction",
                        modelValue: display(draft.direction),
                        verification: verificationText(for: .direction, draft: draft),
                        databaseValue: latestRun?.acceptedDirectionRawValue
                            ?? "No value written by this attempt"
                    )
                    FieldJourneyRow(
                        title: "Amount",
                        modelValue: display(draft.amountText),
                        verification: verificationText(for: .amount, draft: draft),
                        databaseValue: databaseAmountValue
                    )
                    FieldJourneyRow(
                        title: "Merchant",
                        modelValue: display(draft.merchant),
                        verification: verificationText(for: .merchant, draft: draft),
                        databaseValue: latestRun?.acceptedMerchant
                            ?? "No value written by this attempt",
                        needsAttention: draft.merchant.isEmpty
                    )
                    FieldJourneyRow(
                        title: "Account",
                        modelValue: display(draft.accountLabel),
                        verification: verificationText(for: .account, draft: draft),
                        databaseValue: databaseAccountValue
                    )
                    FieldJourneyRow(
                        title: "Date",
                        modelValue: display(draft.occurredAtText),
                        verification: verificationText(for: .date, draft: draft),
                        databaseValue: latestRun?.acceptedOccurredAt.map(databaseDate)
                            ?? "No value written by this attempt",
                        needsAttention: draft.occurredAtText.isEmpty
                    )
                    FieldJourneyRow(
                        title: "Currency",
                        modelValue: display(draft.currencyCode),
                        verification: "Normalized to uppercase after amount validation.",
                        databaseValue: latestRun?.acceptedCurrencyCode
                            ?? "No value written by this attempt"
                    )
                } else {
                    ContentUnavailableView(
                        "No fields to compare",
                        systemImage: "rectangle.and.text.magnifyingglass",
                        description: Text("The model did not return a mapped transaction draft.")
                    )
                }
            }
        } header: {
            Text("Latest model attempt → verification → write")
        } footer: {
            Text(
                "These saved values belong only to the latest model attempt. The separate database section shows the current row, including any earlier successful attempt or owner edit."
            )
        }
    }

    private var databaseSection: some View {
        Section {
            DisclosureGroup("InboxAlert row") {
                VStack(alignment: .leading, spacing: 8) {
                    TraceValue("id", alert.id.uuidString.lowercased())
                    TraceValue("statusRawValue", alert.statusRawValue)
                    TraceValue("originRawValue", alert.originRawValue)
                    TraceValue("transactionID", uuid(alert.transactionID))
                    TraceValue("parserName", alert.parserName ?? "nil")
                    TraceValue("attemptCount", alert.attemptCount.formatted())
                    TraceValue("lastErrorCode", alert.lastErrorCode ?? "nil")
                    TraceValue("rejectionCode", alert.rejectionCode ?? "nil")
                    TraceValue("receivedAt", databaseDate(alert.receivedAt))
                    TraceValue("createdAt", databaseDate(alert.createdAt))
                    TraceValue("updatedAt", databaseDate(alert.updatedAt))
                }
                .padding(.vertical, 8)
            }

            if let latestFilterRun {
                DisclosureGroup("DeterministicFilterRun row") {
                    VStack(alignment: .leading, spacing: 8) {
                        TraceValue("id", latestFilterRun.id.uuidString.lowercased())
                        TraceValue("alertID", latestFilterRun.alertID.uuidString.lowercased())
                        TraceValue("evaluationIndex", latestFilterRun.evaluationIndex.formatted())
                        TraceValue("evaluatedAt", databaseDate(latestFilterRun.evaluatedAt))
                        TraceValue("rulesVersion", latestFilterRun.rulesVersion)
                        TraceValue("decisionRawValue", latestFilterRun.decisionRawValue)
                        TraceValue("rejectionCodeRawValue", latestFilterRun.rejectionCodeRawValue ?? "nil")
                        TraceValue("senderWasUsed", latestFilterRun.senderWasUsed ? "true" : "false")
                        TraceValue("extractionRunID", uuid(latestFilterRun.extractionRunID))
                        TraceValue("completedStagesRawValue", latestFilterRun.completedStagesRawValue)
                        TraceValue("stagesJSON", latestFilterRun.stagesJSON)
                    }
                    .padding(.vertical, 8)
                }
            }

            if let transaction = acceptedTransaction {
                DisclosureGroup("Transaction row") {
                    VStack(alignment: .leading, spacing: 8) {
                        TraceValue("id", transaction.id.uuidString.lowercased())
                        TraceValue("amountMinorUnits", transaction.amountMinorUnits.formatted())
                        TraceValue("currencyCode", transaction.currencyCode)
                        TraceValue("directionRawValue", transaction.directionRawValue)
                        TraceValue("merchant", transaction.merchant)
                        TraceValue("occurredAt", databaseDate(transaction.occurredAt))
                        TraceValue("accountID", uuid(transaction.accountID))
                        TraceValue("accountLabel", transaction.accountLabel ?? "nil")
                        TraceValue("parserName", transaction.parserName)
                        TraceValue("reviewStateRawValue", transaction.reviewStateRawValue)
                        TraceValue("isEdited", transaction.isEdited ? "true" : "false")
                        TraceValue("sourceAlertID", transaction.sourceAlertID.uuidString.lowercased())
                        TraceValue("amountEvidenceText", transaction.amountEvidenceText)
                        TraceValue("dateEvidenceText", transaction.dateEvidenceText ?? "nil")
                        TraceValue("createdAt", databaseDate(transaction.createdAt))
                        TraceValue("updatedAt", databaseDate(transaction.updatedAt))
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
                        TraceValue("createdAt", databaseDate(account.createdAt))
                        TraceValue("updatedAt", databaseDate(account.updatedAt))
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("database-account-record")
            }
        } header: {
            Text("Exact current database values")
        } footer: {
            Text(
                "This section reads the current local SwiftData objects. Historical values written by each extraction attempt remain in Attempt history below."
            )
        }
    }

    private var sourceEvidenceSection: some View {
        Section {
            DisclosureGroup("Exact source SMS and metadata") {
                if alert.rawBody.isEmpty {
                    Label("Evidence erased after deterministic rejection", systemImage: "eraser.fill")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Source app", value: alert.sourceApplication ?? "Not supplied")
                    LabeledContent("Sender", value: alert.sender.isEmpty ? "Not supplied" : alert.sender)
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
            Text("This is the exact locally persisted input used by the filter, model request, and verifier.")
        }
    }

    private var attemptHistorySection: some View {
        Section {
            if extractionRuns.isEmpty {
                ContentUnavailableView(
                    "No persisted model attempt",
                    systemImage: "archivebox",
                    description: Text("The deterministic pipeline stopped before model invocation.")
                )
            } else {
                ForEach(extractionRuns) { run in
                    ExtractionRunDisclosure(
                        run: run,
                        snapshots: snapshots(for: run),
                        initiallyExpanded: false
                    )
                }
            }
        } header: {
            Text("Attempt history")
        } footer: {
            Text("Retries create separate immutable audit snapshots; owner edits do not rewrite them.")
        }
    }

    private var technicalAuditSection: some View {
        Section("Technical audit") {
            DisclosureGroup("Current model runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    TraceValue("Parser", alert.parserName ?? "Not invoked")
                    TraceValue("System model API", "SystemLanguageModel.default")
                    if let modelDiagnostic {
                        TraceValue("Model processing locale", modelDiagnostic.localeIdentifier)
                        TraceValue("Locale supported", modelDiagnostic.localeWasSupported ? "Yes" : "No")
                        TraceValue("Formatting locale", modelDiagnostic.formattingLocaleIdentifier)
                        TraceValue("Supported languages", modelDiagnostic.supportedLanguageSummary)
                    } else {
                        ModelStatusLoadingView()
                    }
                    TraceValue(
                        "Public model version",
                        "Not exposed by Foundation Models"
                    )
                }
                .padding(.vertical, 8)
            }

            if nativeOperation != nil {
                DisclosureGroup("Current Candidate Selector") {
                    VStack(alignment: .leading, spacing: 10) {
                        TraceValue("Generation mode", "Direct, non-thinking")
                        TraceValue("Decoding", "Greedy")
                        Text("Pinned instructions")
                            .font(.caption.weight(.semibold))
                        Text(FoundationDirectCandidateSelector.selectorInstructions)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        if let nativeSelectorAttempt {
                            TraceValue("Completion", nativeSelectorAttempt.completionRawValue)
                            TraceValue(
                                "Validation result",
                                nativeSelectorAttempt.safeErrorCode ?? "Validated"
                            )
                            Text("Exact stored request")
                                .font(.caption.weight(.semibold))
                            Text(nativeSelectorAttempt.requestJSON)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            if let rawOutput = nativeSelectorAttempt.rawOutput {
                                Text("Exact stored response")
                                    .font(.caption.weight(.semibold))
                                Text(rawOutput)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("No Candidate Selector attempt was recorded for this operation.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                DisclosureGroup("Legacy extraction contract") {
                    Text(
                        "This alert predates the native Candidate Selector. Its historical extraction details remain in Attempt history."
                    )
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                }
            }

            DisclosureGroup("What Apple does not expose") {
                VStack(alignment: .leading, spacing: 12) {
                    TransparencyLimitRow(
                        title: "Token-level decoding",
                        detail:
                            "No individual token boundaries, IDs, logits, probabilities, or token-per-second counters are public."
                    )
                    TransparencyLimitRow(
                        title: "Hidden reasoning",
                        detail: "No private reasoning trace is requested or returned."
                    )
                    TransparencyLimitRow(
                        title: "Numeric confidence",
                        detail:
                            "The model supplies no calibrated confidence score; exact source-evidence checks are used instead."
                    )
                    TransparencyLimitRow(
                        title: "Model build and runtime context query",
                        detail:
                            "The public API does not identify the exact model build or provide a runtime context-capacity query. Apple's iOS 26 documentation states a 4,096-token session limit."
                    )
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
            return transaction.reviewState == .confirmed ? "Saved and confirmed" : "Saved — confirmation needed"
        }
        switch alert.status {
        case .pending:
            return "Saved for local retry"
        case .processing:
            return "Processing on this iPhone"
        case .needsReview:
            return "Not saved — review needed"
        case .rejected:
            return "Stopped before transaction creation"
        case .duplicate:
            return "Duplicate — no new transaction"
        case .imported:
            return "Transaction link unavailable"
        }
    }

    private var outcomeDetail: String {
        if acceptedTransaction != nil {
            return reviewReasons.isEmpty
                ? "The validated extraction was written to the local transaction and account records."
                : reviewReasons.joined(separator: " ")
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
        acceptedTransaction == nil ? statusIcon : "externaldrive.fill.badge.checkmark"
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

    private var statusIcon: String {
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

    private var reviewReasons: [String] {
        guard acceptedTransaction?.reviewState == .needsReview else { return [] }
        guard let draft = currentTransactionAcceptingRun?.parserDraft else {
            return ["Confirm the extracted fields before using them."]
        }
        var reasons: [String] = []
        if draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("The model did not extract a merchant; “Unknown Merchant” was saved.")
        }
        if draft.occurredAtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("The model did not extract a transaction date; the local receipt time was saved.")
        }
        if reasons.isEmpty {
            reasons.append("Confirm the extracted values and selected account.")
        }
        return reasons
    }

    private var pipelineStages: [PipelineStagePresentation] {
        let filterStage: PipelineStagePresentation
        if let filterTrace {
            switch filterTrace.result.decision {
            case .eligible:
                filterStage = .init(
                    order: 2,
                    title: "Deterministic eligibility",
                    detail: "All checks passed; model invocation was allowed.",
                    state: .passed
                )
            case .needsReview:
                filterStage = .init(
                    order: 2,
                    title: "Deterministic eligibility",
                    detail:
                        "Stopped before the model: \(filterTrace.result.rejectionCode?.rawValue ?? "missing signal").",
                    state: .failed
                )
            case .rejectAndErase:
                filterStage = .init(
                    order: 2,
                    title: "Deterministic eligibility",
                    detail: "Rejected and erased before the model.",
                    state: .failed
                )
            }
        } else {
            filterStage = .init(
                order: 2,
                title: "Deterministic eligibility",
                detail: "Historical trace unavailable after evidence erasure.",
                state: .notRun
            )
        }

        let modelStage: PipelineStagePresentation
        if let pipelineRun {
            if pipelineRun.parserDraft != nil {
                modelStage = .init(
                    order: 3,
                    title: "Local model extraction",
                    detail: "Returned structured fields in \(duration(pipelineRun.parserDuration)).",
                    state: .passed
                )
            } else if pipelineRun.completedAt == nil {
                modelStage = .init(
                    order: 3,
                    title: "Local model extraction",
                    detail: pipelineSnapshots.isEmpty
                        ? "Request is in progress or was interrupted."
                        : "\(pipelineSnapshots.count) structured snapshots observed so far.",
                    state: .inProgress
                )
            } else {
                modelStage = .init(
                    order: 3,
                    title: "Local model extraction",
                    detail: pipelineRun.safeResultCode ?? "No structured response was accepted.",
                    state: .failed
                )
            }
        } else {
            modelStage = .init(
                order: 3,
                title: "Local model extraction",
                detail: filterTrace?.result.isEligible == true
                    ? "Eligibility passed, but no model attempt is linked to this evaluation."
                    : "Not invoked.",
                state: alert.status == .processing ? .inProgress : .notRun
            )
        }

        let validationStage: PipelineStagePresentation
        switch pipelineRun?.validationOutcome {
        case .passed:
            validationStage = .init(
                order: 4,
                title: "Source evidence validation",
                detail: "Required values were grounded in the exact SMS.",
                state: .passed
            )
        case .failed:
            validationStage = .init(
                order: 4,
                title: "Source evidence validation",
                detail: pipelineRun?.safeResultCode ?? "A field failed validation.",
                state: .failed
            )
        case .notPerformed:
            validationStage = .init(
                order: 4,
                title: "Source evidence validation",
                detail: "Not run because no model draft was available.",
                state: .notRun
            )
        case nil:
            validationStage = .init(
                order: 4,
                title: "Source evidence validation",
                detail: "Waiting for structured model fields.",
                state: pipelineRun == nil ? .notRun : .inProgress
            )
        }

        let accountStage: PipelineStagePresentation
        if let pipelineRun, pipelineRun.acceptedTransactionID != nil {
            accountStage = .init(
                order: 5,
                title: "Account resolution",
                detail: "This attempt resolved and saved account label \(pipelineRun.acceptedAccountLabel ?? "nil").",
                state: .passed
            )
        } else {
            accountStage = .init(
                order: 5,
                title: "Account resolution",
                detail: "This evaluation did not commit an accepted account selection.",
                state: pipelineRun?.validationOutcome == .passed ? .failed : .notRun
            )
        }

        let databaseStage: PipelineStagePresentation
        if let pipelineRun, let transactionID = pipelineRun.acceptedTransactionID {
            databaseStage = .init(
                order: 6,
                title: "Database write",
                detail:
                    "This attempt wrote Transaction \(transactionID.uuidString.lowercased()) with reviewState \(pipelineRun.acceptedReviewStateRawValue ?? "nil").",
                state: pipelineRun.acceptedReviewState == .confirmed ? .passed : .attention
            )
        } else if let pipelineRun {
            databaseStage = .init(
                order: 6,
                title: "Database write",
                detail: "This model attempt did not write a Transaction row.",
                state: pipelineRun.completedAt == nil ? .inProgress : .failed
            )
        } else {
            databaseStage = .init(
                order: 6,
                title: "Database write",
                detail: "No model attempt or Transaction write is linked to this filter evaluation.",
                state: .notRun
            )
        }

        return [
            PipelineStagePresentation(
                order: 1,
                title: "Input persisted",
                detail: "InboxAlert \(alert.id.uuidString.lowercased()) was saved before model work.",
                state: .passed
            ),
            filterStage,
            modelStage,
            validationStage,
            accountStage,
            databaseStage,
        ]
    }

    private var generationUnavailableDetail: String {
        if latestRun?.completedAt == nil {
            return "Generation has not emitted a persisted structured snapshot yet, or the attempt was interrupted."
        }
        return "This attempt ended before Apple emitted a structured response, or it predates snapshot capture."
    }

    private var databaseAmountValue: String {
        guard
            let run = latestRun,
            run.acceptedTransactionID != nil,
            let amountMinorUnits = run.acceptedAmountMinorUnits,
            let currencyCode = run.acceptedCurrencyCode
        else {
            return "No value written by this attempt"
        }
        let formatted = CurrencyFormatter.string(
            minorUnits: amountMinorUnits,
            currencyCode: currencyCode
        )
        return "\(amountMinorUnits) minor units (\(formatted))"
    }

    private var databaseAccountValue: String {
        guard let run = latestRun, run.acceptedTransactionID != nil else {
            return "No value written by this attempt"
        }
        return run.acceptedAccountLabel ?? "nil"
    }

    private func verificationText(
        for stage: EvidenceValidationStage,
        draft: ParsedAlertDraft
    ) -> String {
        guard let run = latestRun else { return "No validation attempt." }
        let state = run.validationState(for: stage)
        switch state {
        case .failed:
            return "Failed • \(run.safeResultCode ?? "no result code")"
        case .notRun:
            return "Not run because an earlier stage stopped validation."
        case nil:
            return "No persisted validation result."
        case .passed:
            switch stage {
            case .classification:
                return "Accepted only after checking that the SMS did not explicitly describe a failed transaction."
            case .direction:
                return "A matching debit or credit cue was found in the SMS."
            case .amount:
                return
                    "Exact substring found; it was the only plausible transaction amount and was converted to minor units."
            case .merchant:
                return draft.merchant.isEmpty
                    ? "Model value was empty; “Unknown Merchant” was substituted and review was required."
                    : "Exact literal substring found in the SMS."
            case .account:
                return
                    "Exact literal substring found with at least three account digits, then normalized to an Account row."
            case .date:
                return draft.occurredAtText.isEmpty
                    ? "Model value was empty; the local receipt timestamp was substituted and review was required."
                    : "Exact literal substring found and parsed relative to the receipt date."
            }
        }
    }

    private func snapshots(for run: ExtractionRun?) -> [StructuredGenerationSnapshot] {
        guard let run else { return [] }
        return
            allGenerationSnapshots
            .filter { $0.extractionRunID == run.id }
            .sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex { return lhs.capturedAt < rhs.capturedAt }
                return lhs.sequenceIndex < rhs.sequenceIndex
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

    private func duration(_ value: TimeInterval?) -> String {
        value.map(AlertProcessingDiagnostics.durationText) ?? "an unrecorded duration"
    }

    private func filterDecisionTitle(_ decision: AlertFilterDecision) -> String {
        switch decision {
        case .eligible:
            return "ELIGIBLE → MODEL"
        case .needsReview:
            return "STOPPED → REVIEW"
        case .rejectAndErase:
            return "REJECTED → ERASED"
        }
    }

    private func filterDecisionColor(_ decision: AlertFilterDecision) -> Color {
        switch decision {
        case .eligible:
            return .green
        case .needsReview:
            return .orange
        case .rejectAndErase:
            return .red
        }
    }

    private func display(_ value: String) -> String {
        value.isEmpty ? "<empty string>" : value
    }

    private func uuid(_ value: UUID?) -> String {
        value?.uuidString.lowercased() ?? "nil"
    }

    private func databaseDate(_ value: Date) -> String {
        value.ISO8601Format()
    }
}

private enum PipelineStageState {
    case passed
    case attention
    case failed
    case inProgress
    case notRun
}

private struct PipelineStagePresentation: Identifiable {
    let order: Int
    let title: String
    let detail: String
    let state: PipelineStageState

    var id: Int { order }
}

private struct PipelineStageRow: View {
    let stage: PipelineStagePresentation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(stage.order). \(stage.title)")
                    .font(.headline)
                Text(stage.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("pipeline-stage-\(stage.order)")
    }

    private var icon: String {
        switch stage.state {
        case .passed:
            return "checkmark.circle.fill"
        case .attention:
            return "exclamationmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .inProgress:
            return "ellipsis.circle.fill"
        case .notRun:
            return "minus.circle.fill"
        }
    }

    private var color: Color {
        switch stage.state {
        case .passed:
            return .green
        case .attention:
            return .orange
        case .failed:
            return .red
        case .inProgress:
            return .blue
        case .notRun:
            return .secondary
        }
    }
}

private struct FilterStageRow: View {
    let stage: AlertFilterStageOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch stage.state {
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .notRun:
            return "minus.circle.fill"
        }
    }

    private var color: Color {
        switch stage.state {
        case .passed:
            return .green
        case .failed:
            return .red
        case .notRun:
            return .secondary
        }
    }

    private var detail: String {
        stage.state == .notRun
            ? "Not run because an earlier deterministic stage stopped processing."
            : stage.detail
    }
}

private struct StructuredGenerationInspector: View {
    let snapshots: [StructuredGenerationSnapshot]
    let runStartedAt: Date?

    @State private var selectedSequence: Int?
    @State private var followsLatest = true

    private var selectedSnapshot: StructuredGenerationSnapshot? {
        if let selectedSequence,
            let selected = snapshots.first(where: { $0.sequenceIndex == selectedSequence })
        {
            return selected
        }
        return snapshots.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    snapshots.last?.isComplete == true ? "Complete output" : "Partial output",
                    systemImage: snapshots.last?.isComplete == true
                        ? "checkmark.circle.fill" : "waveform.path.ecg"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(snapshots.last?.isComplete == true ? .green : .blue)
                Spacer()
                Text("\(snapshots.count) snapshot\(snapshots.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("Follow latest snapshot", isOn: $followsLatest)
                .font(.subheadline)

            Picker(
                "Visible snapshot",
                selection: Binding(
                    get: { selectedSnapshot?.sequenceIndex },
                    set: {
                        selectedSequence = $0
                        followsLatest = $0 == snapshots.last?.sequenceIndex
                    }
                )
            ) {
                ForEach(snapshots, id: \.id) { snapshot in
                    Text(snapshotTitle(snapshot)).tag(Optional(snapshot.sequenceIndex))
                }
            }
            .pickerStyle(.menu)

            if let snapshot = selectedSnapshot {
                HStack {
                    Text(snapshot.isComplete ? "Final cumulative JSON" : "Cumulative JSON at this point")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(elapsedText(snapshot))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.rawContentJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier(
                        snapshot.isComplete ? "generation-final-raw-json" : "generation-live-output"
                    )
                TraceValue("formatIdentifier", snapshot.formatIdentifier)
                TraceValue("capturedAt", snapshot.capturedAt.ISO8601Format())
            }
        }
        .onAppear { followNewestSnapshot() }
        .onChange(of: snapshots.count) { _, _ in
            if followsLatest { followNewestSnapshot() }
        }
    }

    private func followNewestSnapshot() {
        selectedSequence = snapshots.last?.sequenceIndex
    }

    private func snapshotTitle(_ snapshot: StructuredGenerationSnapshot) -> String {
        "#\(snapshot.sequenceIndex + 1) • \(elapsedText(snapshot))\(snapshot.isComplete ? " • final" : "")"
    }

    private func elapsedText(_ snapshot: StructuredGenerationSnapshot) -> String {
        guard let runStartedAt else { return "time unavailable" }
        let elapsed = max(0, snapshot.capturedAt.timeIntervalSince(runStartedAt))
        return "+\(AlertProcessingDiagnostics.durationText(elapsed))"
    }
}

private struct FieldJourneyRow: View {
    let title: String
    let modelValue: String
    let verification: String
    let databaseValue: String
    var needsAttention = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                JourneyStep(label: "MODEL OUTPUT", value: modelValue, color: .purple)
                JourneyStep(label: "APP VERIFICATION", value: verification, color: .blue)
                JourneyStep(label: "THIS ATTEMPT'S SAVED VALUE", value: databaseValue, color: .green)
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Text(title)
                    .font(.headline)
                if needsAttention {
                    Text("Review")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(databaseValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct JourneyStep: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ExtractionRunDisclosure: View {
    let run: ExtractionRun
    let snapshots: [StructuredGenerationSnapshot]
    @State private var isExpanded: Bool

    init(
        run: ExtractionRun,
        snapshots: [StructuredGenerationSnapshot],
        initiallyExpanded: Bool
    ) {
        self.run = run
        self.snapshots = snapshots
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                identityAndTiming
                Divider()
                exactRequest
                Divider()
                generatedResponse
                Divider()
                parserDraft
                Divider()
                validation
                Divider()
                acceptedTransaction
            }
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Attempt \(run.attemptIndex)")
                    .font(.headline)
                Text("\(dispositionTitle) • \(durationTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var identityAndTiming: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Identity and timing")
            TraceValue("Run ID", run.id.uuidString.lowercased())
            TraceValue("Parser", run.parserName)
            TraceValue("Contract version", run.contractVersion)
            TraceValue("Extraction profile version", run.profileVersion)
            TraceValue("Model processing locale", run.localeIdentifier)
            TraceValue(
                "Locale supported at request start",
                run.localeWasSupported.map { $0 ? "Yes" : "No" } ?? "Not recorded"
            )
            TraceValue(
                "Model language identifiers",
                run.supportedLanguageIdentifiers.isEmpty
                    ? "Not recorded" : run.supportedLanguageIdentifiers.joined(separator: ", ")
            )
            TraceValue("Started", run.startedAt.ISO8601Format())
            TraceValue("Response received", run.responseReceivedAt?.ISO8601Format() ?? "Not recorded")
            TraceValue("Completed", run.completedAt?.ISO8601Format() ?? "Not recorded")
        }
    }

    private var exactRequest: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Exact request used")
            Text("Instructions")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(run.exactInstructions)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Prompt")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(run.exactRequest)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var generatedResponse: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Exact structured generation")
            if snapshots.isEmpty {
                Text("No structured generation snapshot was persisted for this attempt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                StructuredGenerationInspector(snapshots: snapshots, runStartedAt: run.startedAt)
            }
        }
    }

    @ViewBuilder
    private var parserDraft: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Mapped ParsedAlertDraft")
            if let draft = run.parserDraft {
                TraceValue("classification", draft.classification.rawValue)
                TraceValue("direction", display(draft.direction))
                TraceValue("amountText", display(draft.amountText))
                TraceValue("merchant", display(draft.merchant))
                TraceValue("accountLabel", display(draft.accountLabel))
                TraceValue("occurredAtText", display(draft.occurredAtText))
                TraceValue("currencyCode", display(draft.currencyCode))
            } else {
                Text("No mapped draft was persisted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var validation: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Evidence validation")
            ForEach(EvidenceValidationStage.allCases, id: \.self) { stage in
                TraceValue(stage.rawValue, validationTitle(run.validationState(for: stage)))
            }
            TraceValue("safeResultCode", run.safeResultCode ?? "nil")
            TraceValue("terminalDisposition", run.terminalDispositionRawValue ?? "nil")
        }
    }

    @ViewBuilder
    private var acceptedTransaction: some View {
        VStack(alignment: .leading, spacing: 8) {
            auditHeading("Accepted-field snapshot at this attempt")
            if let transactionID = run.acceptedTransactionID {
                TraceValue("transactionID", transactionID.uuidString.lowercased())
                TraceValue("amountMinorUnits", run.acceptedAmountMinorUnits?.formatted() ?? "nil")
                TraceValue("currencyCode", run.acceptedCurrencyCode ?? "nil")
                TraceValue("directionRawValue", run.acceptedDirectionRawValue ?? "nil")
                TraceValue("merchant", run.acceptedMerchant ?? "nil")
                TraceValue("accountLabel", run.acceptedAccountLabel ?? "nil")
                TraceValue("occurredAt", run.acceptedOccurredAt?.ISO8601Format() ?? "nil")
                TraceValue("reviewStateRawValue", run.acceptedReviewStateRawValue ?? "nil")
                TraceValue("amountEvidenceText", run.acceptedAmountEvidenceText ?? "nil")
                TraceValue("dateEvidenceText", run.acceptedDateEvidenceText ?? "nil")
            } else {
                Text("This attempt did not write a Transaction row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dispositionTitle: String {
        switch run.terminalDisposition {
        case .imported:
            return "Imported"
        case .queued:
            return "Queued for retry"
        case .needsReview:
            return "Needs review"
        case nil:
            return "In progress or interrupted"
        }
    }

    private var durationTitle: String {
        run.totalDuration.map(AlertProcessingDiagnostics.durationText) ?? "unfinished"
    }

    private func validationTitle(_ state: EvidenceValidationStageState?) -> String {
        switch state {
        case .passed:
            return "passed"
        case .failed:
            return "failed"
        case .notRun:
            return "not_run"
        case nil:
            return "not recorded"
        }
    }

    private func auditHeading(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
    }

    private func display(_ value: String) -> String {
        value.isEmpty ? "<empty string>" : value
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

private struct TransparencyLimitRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
