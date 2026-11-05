import XCTest

/// SmokeTests goes through the app as a viewer would, on the real catalog:
/// it needs the network, and a first recommendation whose first episode
/// plays without a login.
final class SmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testBrowseSaveAndPlay() throws {
        let app = XCUIApplication()
        app.launch()

        // A recommendation opens its page.
        let card = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no recommendations")
        card.tap()
        XCTAssertTrue(app.staticTexts["选集"].waitForExistence(timeout: 30), "the series page did not open")

        // Saving it puts it on 我的.
        if app.buttons["取消收藏这部剧"].exists {
            app.buttons["取消收藏这部剧"].tap()
        }
        app.buttons["收藏这部剧"].tap()
        XCTAssertTrue(app.buttons["取消收藏这部剧"].waitForExistence(timeout: 5))
        app.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["收藏"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["还没有收藏"].exists)

        // Back on the series, an episode plays, and the next one after it.
        app.buttons["推荐"].tap()
        app.buttons["第 1 集"].firstMatch.tap()
        XCTAssertTrue(app.buttons["退出播放"].waitForExistence(timeout: 10), "the player did not open")
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1 集 / 共'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["下一集"].tap()
        let second = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2 集 / 共'")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["视频加载失败，请重试"].waitForExistence(timeout: 15), "the episode failed to play")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)

        // Leaving the player goes back to the series, which goes on from
        // the episode watched.
        app.buttons["退出播放"].tap()
        XCTAssertTrue(app.buttons["继续看第 2 集"].waitForExistence(timeout: 10))
    }
}
