import XCTest

final class RemoteScreenLifecycleUITests: XCTestCase {
    @MainActor
    func testPublishedScreenSurvivesRepeatedPresentation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let machine = environment["NANOCODEX_TEST_REMOTE_MACHINE_ID"], !machine.isEmpty,
              let surface = environment["NANOCODEX_TEST_REMOTE_SURFACE_ID"], !surface.isEmpty else {
            throw XCTSkip("Requires a saved account and an explicitly selected published screen")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let screens = app.buttons["conversation-remote-screens"]
        let desktop = app.buttons["remote-screen:\(machine):\(surface)"]
        let status = app.staticTexts["remote-status"]

        func requireWatching() {
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            let watching = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Watching"), object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [watching], timeout: 45), .completed)
            XCTAssertTrue(app.buttons["Take control"].exists)
            XCTAssertFalse(app.buttons["Release control"].exists)
            XCTAssertEqual(app.state, .runningForeground)
        }

        // Use the saved account without changing its credentials, conversations,
        // drafts, or the remote machine. Each path destroys a live UIKit canvas.
        for cycle in 0..<4 {
            XCTAssertTrue(screens.waitForExistence(timeout: 20))
            XCTAssertTrue(screens.isEnabled)
            screens.tap()
            XCTAssertTrue(desktop.waitForExistence(timeout: 20))
            desktop.tap()
            requireWatching()

            app.buttons["Screens"].tap()
            XCTAssertTrue(desktop.waitForExistence(timeout: 10))
            desktop.tap()
            requireWatching()

            if cycle == 0 {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
                app.activate()
                requireWatching()
            }
            if cycle == 0 || cycle == 3 {
                let evidence = XCTAttachment(screenshot: app.screenshot())
                evidence.name = "remote-screen-lifecycle-\(cycle + 1)"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            app.buttons["Done"].tap()
            XCTAssertTrue(screens.waitForExistence(timeout: 10))
            XCTAssertEqual(app.state, .runningForeground)
        }
    }
}
