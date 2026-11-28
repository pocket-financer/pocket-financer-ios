import SwiftData
import SwiftUI

enum StoreBootstrapState {
    case loading
    case ready(AppDatabase)
    case unavailable(AppDatabaseStartupFailure)
}

@MainActor
struct StoreBootstrapView: View {
    @State private var state: StoreBootstrapState = .loading
    private let openDatabase: @MainActor @Sendable () async throws -> AppDatabase

    init() {
        self.init(openDatabase: Self.openProductionDatabase)
    }

    init(openDatabase: @escaping @MainActor @Sendable () async throws -> AppDatabase) {
        self.openDatabase = openDatabase
    }

    var body: some View {
        switch state {
        case .loading:
            LocalStoreLoadingView()
                .task {
                    await load()
                }
        case .ready(let database):
            AppRootView()
                .modelContainer(database.container)
        case .unavailable(let failure):
            LocalStoreUnavailableView(failure: failure) {
                state = .loading
            }
        }
    }

    private func load() async {
        let nextState = await Self.load(using: openDatabase)
        guard !Task.isCancelled else { return }
        state = nextState
    }

    private static func load(
        using openDatabase: @MainActor @Sendable () async throws -> AppDatabase
    ) async -> StoreBootstrapState {
        do {
            let database = try await openDatabase()
            prepareForUITesting(database)
            return .ready(database)
        } catch let failure as AppDatabaseStartupFailure {
            return .unavailable(failure)
        } catch {
            return .unavailable(
                AppDatabaseStartupFailure(classifying: error, phase: .openingStore)
            )
        }
    }

    private static func openProductionDatabase() async throws -> AppDatabase {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-store-unavailable") {
                throw AppDatabaseStartupFailure(
                    kind: .unrecognizedStoreModel,
                    diagnosticCode: "NSCocoaErrorDomain/134504"
                )
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-hold-store-open") {
                try await Task.sleep(for: .seconds(300))
            }
        #endif
        return try await AppDatabase.openShared()
    }

    private static func prepareForUITesting(_ database: AppDatabase) {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") else { return }
            UserDefaults.standard.set(false, forKey: AppPreferenceKey.completedOnboarding)
            PrimaryCurrencySettings.reset()
            try? LocalDataService(context: database.container.mainContext).eraseAll()
        #endif
    }
}

struct LocalStoreLoadingView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Opening protected local data")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("store-loading-title")

                Text("Keep this iPhone unlocked while Pocket Financer safely opens its on-device store.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Opening local store")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LocalStoreUnavailableView: View {
    let failure: AppDatabaseStartupFailure
    let retry: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)

                        Text("Local store unavailable")
                            .font(.largeTitle.bold())
                            .accessibilityIdentifier("store-unavailable-title")

                        Text(
                            "Pocket Financer could not open its local database. It did not delete, reset, or replace the existing store. Imports are paused."
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("store-unavailable-preservation-message")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(failureTitle)
                            .font(.headline)
                        Text(failureDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        LabeledContent("Safe code", value: failure.safeCode)
                        LabeledContent("System diagnostic", value: failure.diagnosticCode)
                    }
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 18))

                    Button(action: retry) {
                        Label("Retry Local Store", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("retry-local-store")

                    Label(
                        "Do not delete Pocket Financer if this store contains data you need. Deleting the app also deletes its local data.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .navigationTitle("Pocket Financer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var failureTitle: String {
        switch failure.kind {
        case .unrecognizedStoreModel:
            "Store version not recognized"
        case .newerStoreVersion:
            "Newer app version required"
        case .protectedDataUnavailable:
            "Protected data is unavailable"
        case .fileProtectionFailed:
            "Storage protection could not be verified"
        case .storeOpenFailed:
            "Local database could not be opened"
        }
    }

    private var failureDetail: String {
        switch failure.kind {
        case .unrecognizedStoreModel:
            "This store comes from a version Pocket Financer cannot safely identify. It was left in place for recovery."
        case .newerStoreVersion:
            "This store was created by a newer version of Pocket Financer. Install that version before retrying."
        case .protectedDataUnavailable:
            "Unlock this iPhone after restarting it, then retry. The existing store was left in place."
        case .fileProtectionFailed:
            "Pocket Financer paused access because it could not verify the required on-device file protection."
        case .storeOpenFailed:
            "The existing store was left in place. Retry once the device has enough free space and protected data is available."
        }
    }
}
