import SwiftData
import SwiftUI

struct AppRootView: View {
    @AppStorage(AppPreferenceKey.completedOnboarding) private var completedOnboarding = false
    @PrimaryCurrencyState private var primaryCurrency
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    private var drainTrigger: PendingAlertDrainTrigger {
        PendingAlertDrainPolicy.trigger(
            completedOnboarding: completedOnboarding,
            scenePhase: scenePhase,
            confirmedPrimaryCurrency: primaryCurrency.confirmedCode
        )
    }

    var body: some View {
        ZStack {
            Group {
                if completedOnboarding {
                    MainTabView()
                } else {
                    OnboardingView {
                        completedOnboarding = true
                    }
                }
            }

            if scenePhase != .active {
                PrivacyShieldView()
                    .zIndex(100)
            }
        }
        .task(id: drainTrigger) {
            guard drainTrigger.mayDrain else { return }

            // Commit the active scene before model discovery or inbox work can
            // occupy the main actor. Changing the task ID requests cancellation as
            // soon as the owner leaves the active scene or updates currency confirmation.
            await Task.yield()
            guard !Task.isCancelled, drainTrigger.mayDrain else { return }
            await drainPendingAlerts()
        }
    }

    private func drainPendingAlerts() async {
        guard drainTrigger.mayDrain else { return }
        let service = AlertIngestionService(context: modelContext)
        // Process bounded batches until fewer than the requested limit complete.
        // Each operation is independently claimed/fenced, and scene cancellation
        // stops the loop.
        while true {
            guard !Task.isCancelled, drainTrigger.mayDrain else { return }
            let completed = await service.processPending(limit: 8)
            if completed < 8 { return }
            await Task.yield()
        }
    }
}

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Pocket Financer")
                    .font(.title2.bold())
                Label("Protected while inactive", systemImage: "lock.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pocket Financer is protected while inactive")
        .accessibilityIdentifier("privacy-shield")
    }
}

struct PendingAlertDrainTrigger: Equatable, Hashable, Sendable {
    let completedOnboarding: Bool
    let isActiveScene: Bool
    let confirmedPrimaryCurrency: String?

    nonisolated var mayDrain: Bool {
        completedOnboarding && isActiveScene && confirmedPrimaryCurrency != nil
    }
}

enum PendingAlertDrainPolicy {
    nonisolated static func mayDrain(completedOnboarding: Bool, scenePhase: ScenePhase) -> Bool {
        completedOnboarding && scenePhase == .active
    }

    nonisolated static func mayDrain(
        completedOnboarding: Bool,
        scenePhase: ScenePhase,
        confirmedPrimaryCurrency: String?
    ) -> Bool {
        trigger(
            completedOnboarding: completedOnboarding,
            scenePhase: scenePhase,
            confirmedPrimaryCurrency: confirmedPrimaryCurrency
        ).mayDrain
    }

    nonisolated static func trigger(
        completedOnboarding: Bool,
        scenePhase: ScenePhase,
        confirmedPrimaryCurrency: String?
    ) -> PendingAlertDrainTrigger {
        PendingAlertDrainTrigger(
            completedOnboarding: completedOnboarding,
            isActiveScene: scenePhase == .active,
            confirmedPrimaryCurrency: PrimaryCurrencySettings.normalizedSupportedCode(
                confirmedPrimaryCurrency
            )
        )
    }
}

struct SensitiveSceneCoverModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
            if scenePhase != .active {
                PrivacyShieldView()
                    .zIndex(100)
            }
        }
    }
}

extension View {
    func sensitiveSceneCover() -> some View {
        modifier(SensitiveSceneCoverModifier())
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }

            Tab("Transactions", systemImage: "list.bullet.rectangle.portrait.fill") {
                TransactionsView()
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .accessibilityIdentifier("main-tab-view")
    }
}
