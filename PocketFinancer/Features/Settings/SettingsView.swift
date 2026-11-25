import AppIntents
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.completedOnboarding) private var completedOnboarding = true
    @State private var primaryCurrency = PrimaryCurrencySettings.currentCode
    @Query private var alerts: [InboxAlert]
    @State private var retrying = false
    @State private var testingModel = false
    @State private var showingEraseConfirmation = false
    @State private var resultMessage: String?
    @State private var selfTestReport: ModelSelfTestResult?

    private var diagnostics: StorageDiagnostic {
        StorageDiagnostic(
            pending: alerts.count { $0.status == .pending || $0.status == .processing },
            needsReview: alerts.count { $0.status == .needsReview },
            imported: alerts.count { $0.status == .imported },
            rejected: alerts.count { $0.status == .rejected },
            duplicates: alerts.count { $0.status == .duplicate }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Money and locale") {
                    Picker("Primary currency", selection: $primaryCurrency) {
                        ForEach(PrimaryCurrencySettings.supportedCodes, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    Button("Confirm \(primaryCurrency) as Primary Currency") {
                        PrimaryCurrencySettings.confirm(primaryCurrency)
                        resultMessage = "Primary currency confirmed for future alert processing."
                    }
                    .disabled(PrimaryCurrencySettings.confirmedCode == primaryCurrency)
                    Text(
                        "This is used only when a message has no explicit currency. Each processing attempt stores its own immutable setting snapshot."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("On-device intelligence") {
                    CurrentModelStatusView()
                        .padding(.vertical, 6)

                    Button {
                        Task { await runModelSelfTest() }
                    } label: {
                        Label(
                            testingModel ? "Testing Apple Model…" : "Run Synthetic Model Test",
                            systemImage: "apple.intelligence"
                        )
                    }
                    .disabled(testingModel)
                    .accessibilityIdentifier("model-self-test")

                    Button {
                        Task { await retrySavedAlerts() }
                    } label: {
                        Label(retrying ? "Retrying…" : "Retry Saved Alerts", systemImage: "arrow.clockwise")
                    }
                    .disabled(retrying || (diagnostics.pending == 0 && diagnostics.needsReview == 0))
                }

                Section("Shortcuts ingestion") {
                    NavigationLink {
                        AutomationSetupView()
                    } label: {
                        Label("Automation Setup", systemImage: "command")
                    }

                    ShortcutsLink()
                        .shortcutsLinkStyle(.automaticOutline)

                    Text(
                        "Automations are personal OS settings. Pocket Financer cannot create, inspect, or silently change them."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Local inbox diagnostics") {
                    DiagnosticRow(title: "Waiting", value: diagnostics.pending, color: .blue)
                    DiagnosticRow(title: "Needs review", value: diagnostics.needsReview, color: .orange)
                    DiagnosticRow(title: "Imported", value: diagnostics.imported, color: .green)
                    DiagnosticRow(title: "Rejected safely", value: diagnostics.rejected, color: .secondary)
                    DiagnosticRow(title: "Duplicates", value: diagnostics.duplicates, color: .secondary)
                }

                Section("Privacy") {
                    NavigationLink {
                        PrivacyDetailsView()
                    } label: {
                        Label("How your data is handled", systemImage: "hand.raised.fill")
                    }

                    Button("Show Onboarding Again") {
                        completedOnboarding = false
                    }
                }

                Section {
                    Button("Erase All Local Data", role: .destructive) {
                        showingEraseConfirmation = true
                    }
                    .accessibilityIdentifier("erase-all-data")
                } footer: {
                    Text(
                        "Invalidates active processing and deletes transactions, accounts, queued alerts, retained evidence, and local pipeline audit snapshots from this iPhone."
                    )
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Storage", value: "This device only")
                    LabeledContent("Minimum iOS", value: "26.0")
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Erase every local record?",
                isPresented: $showingEraseConfirmation,
                titleVisibility: .visible
            ) {
                Button("Erase All Local Data", role: .destructive) { eraseAll() }
            } message: {
                Text("This cannot be undone. Pocket Financer does not keep a cloud backup.")
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
            .sheet(item: $selfTestReport) { report in
                ModelSelfTestReportView(report: report)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func retrySavedAlerts() async {
        guard PrimaryCurrencySettings.confirmedCode != nil else {
            resultMessage = "Confirm a primary currency before processing saved alerts."
            return
        }
        retrying = true
        defer { retrying = false }
        let service = AlertIngestionService(context: modelContext)
        let completed = await service.processPending(limit: 20, includeNeedsReview: true)
        resultMessage =
            completed == 0
            ? "No alert could be completed. Check the model status and try again later."
            : "Retried \(completed) saved alert\(completed == 1 ? "" : "s") locally."
    }

    private func runModelSelfTest() async {
        testingModel = true
        defer { testingModel = false }
        selfTestReport = await ModelSelfTestService.run()
    }

    private func eraseAll() {
        do {
            try LocalDataService(context: modelContext).eraseAll()
            resultMessage = "All local Pocket Financer data was erased."
        } catch {
            resultMessage = "The local data could not be completely erased. Please try again."
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(value, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct AutomationSetupView: View {
    var body: some View {
        List {
            Section {
                AutomationStep(number: 1, text: "Open Shortcuts and tap the Automation tab at the bottom.")
                AutomationStep(
                    number: 2,
                    text:
                        "Tap Automation at the bottom. Tap New Automation, or + if you already have one, then choose Message under Communication."
                )
                AutomationStep(
                    number: 3,
                    text:
                        "Set Message Contains to debited, leave Sender empty, choose Run Immediately, then continue to a New Blank Automation. Do not choose Find Messages."
                )
                AutomationStep(
                    number: 4,
                    text:
                        "Tap Add Action, open Apps → Pocket Financer, and add Import Transaction Alert. Searching that exact action name also works."
                )
                AutomationStep(
                    number: 5,
                    text:
                        "Clear the Message Body slot, then insert the Shortcut Input variable and select its Content property. The final slot may display Shortcut Input and Content together as one property-qualified variable; do not insert either variable a second time. Leave Sender and Received At empty."
                )
                AutomationStep(
                    number: 6,
                    text: "Confirm the action reads Import transaction alert from Content, then tap Done."
                )
            } header: {
                Text("iOS 27 Message automation")
            } footer: {
                Text(
                    "Start with one synthetic incoming message. The app uses the time it receives the alert when the Message trigger has no date field."
                )
            }

            Section("Sender-independent coverage") {
                Text(
                    "After the first test works, make three otherwise identical Message automations: Message Contains Rs, INR, and ₹. Do not add a Sender condition. Pocket Financer rejects non-transactions locally and deduplicates overlapping matches."
                )
            }

            Section("Open Shortcuts") {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)

                Link(destination: URL(string: "shortcuts://")!) {
                    Label("Launch Shortcuts", systemImage: "arrow.up.forward.app")
                }
            }

            Section("iOS 27 beta experiment") {
                Text(
                    "You may also test the notification automation with selected apps and keyword filters. Treat its Messages support and payload shape as experimental until Apple documents the stable behavior."
                )
            }

            Section("Synthetic test alert") {
                Text(ManualAlertImportView.sample)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("Never place a real account alert in screenshots, issues, or source control.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Automation Setup")
    }
}

private struct PrivacyDetailsView: View {
    var body: some View {
        List {
            Section("Local processing") {
                Label("Apple Foundation Models runs on device", systemImage: "apple.intelligence")
                Label("No network client or analytics SDK", systemImage: "network.slash")
                Label("No CloudKit transaction sync", systemImage: "icloud.slash")
            }

            Section("Evidence") {
                Text(
                    "Accepted alerts remain locally attached to the imported transaction so you can audit a model extraction. Deterministically rejected OTP, verification, promotional, collect-request, and duplicate bodies are cleared. Model-only rejections remain available for your review."
                )
            }

            Section("Device protection") {
                Text(
                    "The database is excluded from device backup and protected until the first device unlock after reboot. That protection level allows a user-approved automation to save alerts while the phone is subsequently locked."
                )
            }
        }
        .navigationTitle("Privacy")
    }
}
