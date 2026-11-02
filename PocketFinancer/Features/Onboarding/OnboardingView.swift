import AppIntents
import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var page = 0
    @State private var primaryCurrency = PrimaryCurrencySettings.currentCode

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                OnboardingPage(
                    symbol: "lock.shield.fill",
                    title: "Your finances stay yours",
                    subtitle: "Alerts, transactions, and AI processing remain on this iPhone.",
                    tint: .green
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        PrivacyPoint(symbol: "iphone", text: "No account login or bank connection")
                        PrivacyPoint(symbol: "icloud.slash", text: "No CloudKit or transaction backup")
                        PrivacyPoint(symbol: "network.slash", text: "No remote model, tracking, or analytics")
                    }
                }
                .tag(0)

                OnboardingPage(
                    symbol: "apple.intelligence",
                    title: "Understand alerts locally",
                    subtitle:
                        "Apple's on-device model extracts a draft; Pocket Financer verifies its evidence before saving.",
                    tint: .purple
                ) {
                    CurrentModelStatusView()
                        .padding(18)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }
                .tag(1)

                OnboardingPage(
                    symbol: "coloncurrencysign.circle.fill",
                    title: "Choose your primary currency",
                    subtitle:
                        "This is a fallback only when an alert does not name a currency. Explicit source evidence always wins.",
                    tint: .orange
                ) {
                    Picker("Primary currency", selection: $primaryCurrency) {
                        ForEach(PrimaryCurrencySettings.supportedCodes, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityIdentifier("primary-currency-picker")
                }
                .tag(2)

                OnboardingPage(
                    symbol: "command",
                    title: "Connect with Shortcuts",
                    subtitle:
                        "iOS requires you to create the Message automation. Pocket Financer cannot install or read it silently.",
                    tint: .blue
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        AutomationStep(number: 1, text: "Open Shortcuts and create a personal Message automation.")
                        AutomationStep(
                            number: 2,
                            text: "Use a Message Contains text filter such as Rs. Do not add a Sender condition."
                        )
                        AutomationStep(
                            number: 3,
                            text:
                                "Add Import Transaction Alert. Set Message Body to the incoming message’s Content property once; do not add a second Shortcut Input variable."
                        )
                        AutomationStep(number: 4, text: "Choose automatic execution when iOS offers it.")

                        ShortcutsLink()
                            .shortcutsLinkStyle(.automaticOutline)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)

                        Text("You can finish setup later. Manual alert import always remains available.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < 3 {
                    withAnimation { page += 1 }
                } else {
                    PrimaryCurrencySettings.confirm(primaryCurrency)
                    onComplete()
                }
            } label: {
                Text(page < 3 ? "Continue" : "Start Tracking")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .accessibilityIdentifier(page < 3 ? "onboarding-continue" : "onboarding-finish")
        }
        .background {
            LinearGradient(
                colors: [.accentColor.opacity(0.10), .clear],
                startPoint: .topTrailing,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 36)

                Image(systemName: symbol)
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 112, height: 112)
                    .glassEffect(.regular.tint(tint.opacity(0.14)), in: Circle())

                VStack(spacing: 10) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                content
                    .frame(maxWidth: 560)

                Spacer(minLength: 80)
            }
            .padding(.horizontal, 28)
        }
    }
}

private struct PrivacyPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AutomationStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
