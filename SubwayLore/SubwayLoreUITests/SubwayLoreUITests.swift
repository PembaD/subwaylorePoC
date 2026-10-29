//
//  SubwayLoreUITests.swift
//  SubwayLoreUITests
//
//  Created by Pemba Dorji on 9/4/26.
//

import XCTest

final class SubwayLoreUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testChatHistorySurvivesAppRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SUBWAYLORE_TEST_STORE"] = UUID().uuidString
        app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }
        let newChat = app.buttons["newChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        if !newChat.isHittable { app.swipeUp() }
        let landing = XCTAttachment(screenshot: app.screenshot())
        landing.name = "Four-card landing"
        landing.lifetime = .keepAlways
        add(landing)
        newChat.tap()
        let name = app.textFields["chatTitle"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Morning commute test")
        app.buttons["createChat"].tap()
        let composer = app.textViews["messageComposer"]
        let field = app.textFields["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5) || field.exists)
        let input = composer.exists ? composer : field
        input.tap()
        input.typeText("A saved message")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["A saved message"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        let history = app.buttons["chatHistory"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        if !history.isHittable { app.swipeUp() }
        history.tap()
        let savedChat = app.staticTexts["Morning commute test"]
        XCTAssertTrue(savedChat.waitForExistence(timeout: 5))
        savedChat.tap()
        XCTAssertTrue(app.staticTexts["A saved message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Join / Resume chat"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Saved chat preview after relaunch"
        preview.lifetime = .keepAlways
        add(preview)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
