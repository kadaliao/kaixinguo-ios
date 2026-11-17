import XCTest

/// TVSmokeTests goes through the Apple TV app with the remote, as a viewer
/// would, on the real catalog: it needs the network, and a first
/// recommendation whose first episodes play without a login. Each step
/// leaves a screenshot in the test results.
final class TVSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testBrowseSaveAndPlay() throws {
        let app = XCUIApplication()
        let remote = XCUIRemote.shared
        app.launchArguments = ["-KXFresh", "YES"] // not where the last run left off
        app.launch()

        // Down from the tabs reaches the first recommendation, which opens
        // its page.
        XCTAssertTrue(app.scrollViews.buttons.firstMatch.waitForExistence(timeout: 60), "no recommendations")
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["选集"].waitForExistence(timeout: 30), "the series page did not open")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放' OR label BEGINSWITH '继续看'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        wait(for: play, focused: true)
        shot(app, "剧集页")

        // Right of the play button, saving it.
        remote.press(.right)
        if app.buttons["已收藏"].exists {
            remote.press(.select)
            XCTAssertTrue(app.buttons["收藏"].waitForExistence(timeout: 5))
        }
        remote.press(.select)
        XCTAssertTrue(app.buttons["已收藏"].waitForExistence(timeout: 5), "saving did not take")

        // The episode plays, the first or where the last run got to; a
        // click shows the bar with the app's menus.
        let n = Int(play.label.filter(\.isNumber)) ?? 1
        remote.press(.left)
        wait(for: play, focused: true)
        remote.press(.select)
        let speed = app.cells["倍速"]
        sleep(8)
        remote.press(.select)
        XCTAssertTrue(speed.waitForExistence(timeout: 20), "the player's bar has no speed menu")
        for name in ["定时关闭", "关闭弹幕"] {
            XCTAssertTrue(app.cells[name].exists, "the player's bar has no \(name)")
        }
        shot(app, "播放控制栏")

        // Down from the bar, the tabs of the info panel: the system's 简介,
        // when the episode has its info, then 选集, the episodes; down
        // again, the one playing has focus, and the next one plays.
        remote.press(.down)
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "第 \(n) 集 / 共")).firstMatch
        if !line.waitForExistence(timeout: 3) {
            remote.press(.right)
        }
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the episodes did not show")
        remote.press(.down)
        wait(for: app.buttons.matching(NSPredicate(format: "label == %@ AND hasFocus == true", "第 \(n) 集")).firstMatch)
        shot(app, "选集面板")
        remote.press(.right)
        wait(for: app.buttons.matching(NSPredicate(format: "label == %@ AND hasFocus == true", "第 \(n + 1) 集")).firstMatch)
        remote.press(.select)
        // The panel closes as it plays; the bar names the episode.
        XCTAssertTrue(app.staticTexts["第 \(n + 1) 集"].waitForExistence(timeout: 10),
                      "choosing the next episode did not play it")
        sleep(5)
        shot(app, "下一集")

        // Menu hides what shows over the video, then leaves the player, back
        // to the series, which goes on from there.
        let resume = app.buttons["继续看第 \(n + 1) 集"]
        for _ in 0..<3 where !resume.hasFocus {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertTrue(resume.hasFocus, "the series did not remember episode \(n + 1)")

        // Back on the tabs, each page shows.
        remote.press(.menu)
        sleep(1)
        remote.press(.menu) // up to the tab bar
        let pages: [(tab: String, sign: XCUIElement)] = [
            ("排行榜", app.buttons["推荐榜"]),
            ("新剧", app.buttons["今天"]),
            ("我的", app.staticTexts["最近观看"]),
            ("搜索", app.searchFields.firstMatch),
        ]
        for (tab, sign) in pages {
            remote.press(.right)
            XCTAssertTrue(sign.waitForExistence(timeout: 30), "\(tab) did not show")
            sleep(2)
            shot(app, tab)
        }
        XCTAssertFalse(app.staticTexts["还没有收藏"].exists)
    }

    /// Waits until the element shows.
    @MainActor private func wait(for element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) did not show")
    }

    /// Waits until the element has focus, or hasn't.
    @MainActor private func wait(for element: XCUIElement, focused: Bool) {
        let p = NSPredicate(format: "hasFocus == %@", NSNumber(value: focused))
        let done = XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: element)], timeout: 10)
        XCTAssertEqual(done, .completed, "\(element) did not \(focused ? "take" : "lose") focus")
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name
        s.lifetime = .keepAlways
        add(s)
    }
}
