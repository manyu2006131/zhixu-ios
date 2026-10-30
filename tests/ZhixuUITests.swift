import XCTest

final class ZhixuUITests: XCTestCase {
    func testDailyWorkflow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["学习一键开始 · 25 分钟"].waitForExistence(timeout: 10))
        app.buttons["学习一键开始 · 25 分钟"].tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        app.buttons["暂停"].tap()
        XCTAssertTrue(app.buttons["开始 / 继续"].exists)
        app.buttons["重置"].tap()
        app.tabBars.buttons["今天"].tap()
        app.buttons["添加"].tap()
        let title = app.textFields["例如：完成 5 道数学题"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("UI smoke task")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["UI smoke task"].waitForExistence(timeout: 5))
        app.tabBars.buttons["花销"].tap()
        app.buttons["记一笔"].tap()
        let amount = app.textFields["金额（元，最多两位小数）"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("12.34")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "12.34")).firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["工具"].tap()
        app.buttons["错题本"].tap()
        app.buttons["添加"].tap()
        let question = app.textFields["标题"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap(); question.typeText("Review link smoke")
        app.buttons["保存"].tap()
        app.tabBars.buttons["复习"].tap()
        XCTAssertTrue(app.staticTexts["错题 · Review link smoke"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["复习"].tap()
        XCTAssertTrue(app.staticTexts["错题 · Review link smoke"].waitForExistence(timeout: 5))
    }
}
