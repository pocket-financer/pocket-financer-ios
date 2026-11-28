import XCTest

final class PocketFinancerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingReachesDirectReviewProcessingDetailsAndConfirmation() throws {
        let app = launchResetApp()
        completeOnboarding(in: app)

        XCTAssertTrue(app.descendants(matching: .any)["monthly-summary"].waitForExistence(timeout: 8))

        let transactionsTab = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(waitForHittable(transactionsTab, timeout: 10))
        transactionsTab.tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        importSampleAlert(in: app)

        let reviewRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Needs review")
        ).firstMatch
        XCTAssertTrue(waitForHittable(reviewRow, timeout: 10))
        reviewRow.tap()

        // Direct navigation to SMS-grounded Review screen
        XCTAssertTrue(app.navigationBars["Review transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["review-source-evidence"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-field-chip-amount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-field-chip-direction"].exists)
        XCTAssertTrue(app.buttons["review-field-chip-account"].exists)
        XCTAssertTrue(app.buttons["review-field-chip-counterparty"].exists)

        // Verify "Why review?" disclosure leads to Processing details ("What Happened")
        let whyToggle = app.buttons["review-why-toggle"]
        XCTAssertTrue(waitForHittable(whyToggle, timeout: 5))
        whyToggle.tap()

        let processingLink = app.buttons["open-processing-details"]
        XCTAssertTrue(scrollToHittable(processingLink, in: app, maximumSwipes: 3))
        processingLink.tap()

        XCTAssertTrue(app.navigationBars["What Happened"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["review-outcome"].waitForExistence(timeout: 5))

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(waitForHittable(backButton, timeout: 5))
        backButton.tap()
        XCTAssertTrue(app.navigationBars["Review transaction"].waitForExistence(timeout: 10))

        if whyToggle.exists && whyToggle.isHittable {
            whyToggle.tap()
        }

        // Assign fields via quick-choice chips if not already populated by model extraction
        for identifier in [
            "review-quick-amount-0",
            "review-quick-direction-0",
            "review-quick-account-0",
        ] {
            let chip = app.buttons[identifier]
            if scrollToHittable(chip, in: app, maximumSwipes: 4) {
                chip.tap()
            }
        }

        let confirmButton = app.buttons["review-confirm-transaction"]
        XCTAssertTrue(scrollToHittable(confirmButton, in: app, maximumSwipes: 6))
        XCTAssertTrue(confirmButton.isEnabled)
        confirmButton.tap()

        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(reviewRow.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testDirectReviewRejectRemovesAlertFromNeedsReview() throws {
        let app = launchResetApp(completedOnboarding: true, confirmedCurrency: "INR")
        let transactionsTab = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(waitForHittable(transactionsTab, timeout: 15))
        transactionsTab.tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        importSampleAlert(in: app)

        let reviewRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Needs review")
        ).firstMatch
        XCTAssertTrue(waitForHittable(reviewRow, timeout: 10))
        reviewRow.tap()

        XCTAssertTrue(app.navigationBars["Review transaction"].waitForExistence(timeout: 10))
        let rejectButton = app.buttons["review-reject-alert"]
        XCTAssertTrue(scrollToHittable(rejectButton, in: app, maximumSwipes: 8))
        rejectButton.tap()

        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(reviewRow.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPrivacyShieldClearsOnLaunchAndReactivation() throws {
        let app = launchResetApp(completedOnboarding: true)
        let privacyShield = app.descendants(matching: .any)["privacy-shield"]
        let homeTab = app.tabBars.buttons["Home"]

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(waitForHittable(homeTab, timeout: 15))
        XCTAssertTrue(privacyShield.waitForNonExistence(timeout: 3))

        XCUIDevice.shared.press(.home)
        let enteredBackground =
            app.wait(for: .runningBackgroundSuspended, timeout: 5)
            || app.wait(for: .runningBackground, timeout: 2)
        XCTAssertTrue(enteredBackground)

        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(privacyShield.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(homeTab, timeout: 10))
    }

    @MainActor
    func testSettingsExposesCurrencyDiagnosticsPrivacyAndScopedErasure() throws {
        let app = launchResetApp()
        completeOnboarding(in: app)

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(waitForHittable(settingsTab, timeout: 10))
        settingsTab.tap()

        XCTAssertTrue(app.staticTexts["Money and locale"].waitForExistence(timeout: 8))
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

        XCTAssertTrue(app.staticTexts["store-unavailable-title"].waitForExistence(timeout: 10))
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

        XCTAssertTrue(app.staticTexts["store-loading-title"].waitForExistence(timeout: 5))
        app.terminate()

        app.launchArguments = [
            "--ui-testing-reset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your finances stay yours"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func importSampleAlert(in app: XCUIApplication) {
        let importButton = app.buttons["import-alert-button"]
        XCTAssertTrue(waitForHittable(importButton, timeout: 10))
        importButton.tap()

        let manualBody = app.textViews["manual-body"]
        if !manualBody.waitForExistence(timeout: 10) {
            XCTAssertTrue(waitForHittable(importButton, timeout: 5))
            importButton.tap()
            XCTAssertTrue(manualBody.waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.textFields["manual-sender"].waitForExistence(timeout: 5))
        let submitButton = app.buttons["manual-import-submit"]
        XCTAssertTrue(waitForHittable(submitButton, timeout: 5))
        submitButton.tap()

        let importAlert = app.alerts["Import result"]
        XCTAssertTrue(importAlert.waitForExistence(timeout: 15))
        importAlert.buttons["Done"].tap()
    }

    @MainActor
    private func completeOnboarding(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Your finances stay yours"].waitForExistence(timeout: 10))
        let continueButton = app.buttons["onboarding-continue"]
        XCTAssertTrue(waitForHittable(continueButton, timeout: 5))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Understand alerts locally"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitForHittable(continueButton, timeout: 5))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Choose your primary currency"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.pickers["primary-currency-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(continueButton, timeout: 5))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Connect with Shortcuts"].waitForExistence(timeout: 8))
        let finishButton = app.buttons["onboarding-finish"]
        XCTAssertTrue(waitForHittable(finishButton, timeout: 5))
        finishButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    private func launchResetApp(
        completedOnboarding: Bool = false,
        confirmedCurrency: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if completedOnboarding {
            app.launchArguments += ["-onboarding.completed.v1", "YES"]
        }
        if let confirmedCurrency {
            app.launchArguments += [
                "-primaryCurrencyConfirmed", "YES",
                "-primaryCurrencyCode", confirmedCurrency,
            ]
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
    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 6
    ) -> Bool {
        if waitForHittable(element, timeout: 1.5) {
            return true
        }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if waitForHittable(element, timeout: 1.5) {
                return true
            }
        }
        return false
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
