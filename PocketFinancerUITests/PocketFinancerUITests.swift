import XCTest

final class PocketFinancerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingReachesManualImport() throws {
        let app = launchResetApp()
        completeOnboarding(in: app)

        let transactionsTab = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(transactionsTab.waitForExistence(timeout: 5))
        transactionsTab.tap()

        let importButton = app.buttons["import-alert-button"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        XCTAssertTrue(app.textViews["manual-body"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["manual-import-submit"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testPrivacyShieldClearsOnLaunchAndReactivation() throws {
        let app = launchResetApp(completedOnboarding: true)
        let privacyShield = app.descendants(matching: .any)["privacy-shield"]
        let homeTab = app.tabBars.buttons["Home"]

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        XCTAssertTrue(waitForHittable(homeTab, timeout: 15))
        XCTAssertTrue(privacyShield.waitForNonExistence(timeout: 2))

        XCUIDevice.shared.press(.home)
        let enteredBackground =
            app.wait(for: .runningBackgroundSuspended, timeout: 5)
            || app.wait(for: .runningBackground, timeout: 1)
        XCTAssertTrue(enteredBackground)

        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(privacyShield.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(homeTab, timeout: 10))
    }

    @MainActor
    func testSettingsExposesPrivacyAndScopedErasure() throws {
        let app = launchResetApp()
        completeOnboarding(in: app)

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(app.staticTexts["On-device intelligence"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["model-self-test"].exists)
        XCTAssertTrue(app.buttons["model-self-test"].isEnabled)
        XCTAssertTrue(reveal(app.staticTexts["Local inbox diagnostics"], in: app))

        let eraseButton = app.buttons["erase-all-data"]
        XCTAssertTrue(reveal(eraseButton, in: app))
    }

    @MainActor
    func testUnavailableStoreFailsClosedAndExplainsPreservation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-store-unavailable",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["store-unavailable-title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["store-unavailable-preservation-message"].exists)
        XCTAssertTrue(app.buttons["retry-local-store"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["erase-all-data"].exists)
    }

    @MainActor
    func testProtectedStoreOpeningHasVisibleStartupState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-hold-store-open",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["store-loading-title"].waitForExistence(timeout: 3))
        app.terminate()

        app.launchArguments = [
            "--ui-testing-reset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your finances stay yours"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func completeOnboarding(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Your finances stay yours"].waitForExistence(timeout: 8))
        let continueButton = app.buttons["onboarding-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Understand alerts locally"].waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Choose your primary currency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.pickers["primary-currency-picker"].waitForExistence(timeout: 3))
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Connect with Shortcuts"].waitForExistence(timeout: 5))
        let finishButton = app.buttons["onboarding-finish"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 3))
        finishButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    private func launchResetApp(completedOnboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if completedOnboarding {
            app.launchArguments += ["-onboarding.completed.v1", "YES"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 6
    ) -> Bool {
        if element.waitForExistence(timeout: 1) {
            return true
        }

        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }

        return false
    }
}
