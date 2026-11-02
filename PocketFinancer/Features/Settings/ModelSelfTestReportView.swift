import SwiftUI

struct ModelSelfTestReportView: View {
    @Environment(\.dismiss) private var dismiss

    let report: ModelSelfTestResult

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        report.passed ? "Passed" : "Did not pass",
                        systemImage: report.passed
                            ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(report.passed ? .green : .orange)
                    Text(report.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(
                        "This is an in-memory synthetic diagnostic. "
                            + "Shadow mode prevents a transaction from being created."
                    )
                }

                Section("Run") {
                    LabeledContent("Started", value: timestamp(report.startedAt))
                    LabeledContent("Completed", value: timestamp(report.completedAt))
                    LabeledContent("Elapsed", value: String(format: "%.3f seconds", report.elapsed))
                    LabeledContent("Settlement", value: report.settlement)
                }

                Section("Grounded selector contract") {
                    LabeledContent("Input contract", value: report.contractVersion)
                    LabeledContent("Generation mode", value: report.generationMode)
                    LabeledContent("Output status", value: report.outputCompletion)
                    ReportTextField(
                        label: "Configuration hash",
                        value: report.configurationHash,
                        monospaced: true
                    )
                }

                Section("Synthetic source") {
                    ReportTextField(label: "Sender", value: report.syntheticSender, monospaced: true)
                    ReportTextField(label: "Message", value: report.syntheticBody, monospaced: true)
                    LabeledContent("Message time", value: timestamp(report.receivedAt))
                }

                Section("Direct request") {
                    ReportTextField(
                        label: "Selector instructions",
                        value: report.exactInstructions,
                        monospaced: true
                    )
                    ReportTextField(
                        label: "Exact candidate request",
                        value: report.exactRequest,
                        monospaced: true
                    )
                    ReportTextField(
                        label: "Exact available output",
                        value: report.exactOutput ?? "Not available",
                        monospaced: true
                    )
                }

                if let analysis = report.analysisJSON {
                    Section("Deterministic analysis") {
                        ReportTextField(label: "Canonical JSON", value: analysis, monospaced: true)
                    }
                }

                if let failure = report.failure {
                    Section("Safe failure") {
                        ReportTextField(label: "Safe code", value: failure.safeCode, monospaced: true)
                        LabeledContent("Retryable", value: failure.isRetryable ? "Yes" : "No")
                        ReportTextField(label: "What happened", value: failure.ownerMessage)
                    }
                }

                Section("Apple API limits") {
                    ForEach(report.apiLimitations) { limitation in
                        ReportTextField(label: limitation.metric, value: limitation.explanation)
                    }
                }

                Section("Privacy") {
                    Label("Held in memory only", systemImage: "memorychip")
                    Label("No ledger write", systemImage: "externaldrive.badge.xmark")
                    Label("Not logged or transmitted", systemImage: "network.slash")
                }
            }
            .navigationTitle("Synthetic Selector Test")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("model-self-test-report")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sensitiveSceneCover()
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private struct ReportTextField: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
