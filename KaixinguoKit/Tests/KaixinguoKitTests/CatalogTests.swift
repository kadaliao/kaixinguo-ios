import Foundation
import Openhongguo
import Synchronization
import Testing

@testable import KaixinguoKit

@Test func chineseNumbers() {
    let cases = ["一": 1, "三": 3, "十": 10, "十一": 11, "二十": 20, "二十三": 23, "两": 2, "12": 12, "一百零五": 105]
    for (s, want) in cases {
        #expect(chineseNumber(s) == want, "\(s)")
    }
}

/// Search lists the seasons of a series in their order, where the first of
/// them came, and leaves the rest alone; another series of the same name
/// without the colon keeps to itself.
@Test func ordersSeasonsInSearch() {
    let titles = ["持械入宋：第一季", "持械入宋：第十季", "一品布衣", "持械入宋：第二季", "持械入宋第五季", "持械入宋：第十一季", "持械入宋第三季"]
    let cards = titles.enumerated().map { Card(id: "\($0.offset)", title: $0.element) }
    let got = orderSeasons(cards).map(\.title).joined(separator: ",")
    #expect(got == "持械入宋：第一季,持械入宋：第二季,持械入宋：第十季,持械入宋：第十一季,一品布衣,持械入宋第三季,持械入宋第五季")
}

/// Seasons the server sends without numbers take them from their titles,
/// the first season being the one title without a number; seasons with no
/// telling keep their order.
@Test(arguments: [
    ([Season(title: "b", index: 2), Season(title: "a", index: 1)], "1:a,2:b"),
    ([Season(title: "持械入宋：第十一季"), Season(title: "持械入宋：第一季"), Season(title: "持械入宋：第二季")],
     "1:持械入宋：第一季,2:持械入宋：第二季,11:持械入宋：第十一季"),
    ([Season(title: "浅浅归聿第三季"), Season(title: "浅浅归聿"), Season(title: "浅浅归聿第二季")],
     "1:浅浅归聿,2:浅浅归聿第二季,3:浅浅归聿第三季"),
    ([Season(title: "甲"), Season(title: "乙"), Season(title: "丙")], "1:甲,2:乙,3:丙"),
])
func numbersSeasons(input: [Season], want: String) {
    #expect(numberSeasons(input).map { "\($0.index):\($0.title)" }.joined(separator: ",") == want)
}

@Test func labels() {
    #expect(heat(41_658_011) == "4165万")
    #expect(heat(120_000_000) == "1.2亿")
    #expect(heat(100_000_000) == "1亿")
    #expect(heat(9_999) == "9999")
    #expect(episodeCount(0) == "")
    #expect(episodeCount(80) == "80 集")
    #expect(dayLabel("20261105", today: "20261105") == "今天")
    #expect(dayLabel("20261106", today: "20261105") == "明天")
    #expect(dayLabel("20261104", today: "20261105") == "昨天")
    #expect(dayLabel("20261201", today: "20261105") == "12月1日")
    let s = Series(id: "1", title: "浅浅归聿", episodeCount: 130, status: .end, heat: 41_658_011)
    #expect(metaLine(s) == "全 130 集  ·  热度 4165万")
    #expect(episodesLabel(Series(episodeCount: 12, status: .updating)) == "更新至 12 集")
}

@Test func picksBestStream() {
    let streams = [
        Openhongguo.Stream(definition: "720p", height: 720, bitrate: 900, url: "a"),
        Openhongguo.Stream(definition: "1080p", height: 1080, bitrate: 1200, url: "b"),
        Openhongguo.Stream(definition: "1080p", height: 1080, bitrate: 2400, url: ""), // no URL
        Openhongguo.Stream(definition: "540p", bitrate: 500, url: "c"),
    ]
    #expect(bestStream(streams)?.url == "b")
    #expect(bestStream([]) == nil)
}

/// A search page with nothing new ends the feed, rather than the grid
/// asking for the same page forever.
@MainActor @Test func repeatedPageEndsFeed() {
    let f = Feed(fetch: nil)
    f.add(FeedPage(cards: [Card(id: "a", title: "A"), Card(id: "b", title: "B")], cursor: "20", more: true))
    f.add(FeedPage(cards: [Card(id: "b", title: "B"), Card(id: "a", title: "A")], cursor: "40", more: true))
    #expect(!f.more)
    #expect(f.cards.count == 2)
}

/// Cached recommendations show at once, and the first fresh page goes
/// before them, so the grid never shrinks.
@MainActor @Test func freshPageJoinsCache() async {
    let (model, catalog) = testModel()
    model.saveHomeCache([Card(id: "old1", title: "旧一"), Card(id: "x", title: "旧版 X")])
    try? await Task.sleep(for: .milliseconds(100))
    catalog.update {
        $0.discoverPages[""] = Page(items: [SeriesSummary(id: "x", title: "X", episodeCount: 30),
                                            SeriesSummary(id: "new", title: "新")], cursor: "c1", hasMore: true)
    }
    let again = AppModel(catalog: catalog, dataDir: FileManager.default.temporaryDirectory,
                         cacheDir: model.cacheDir)
    #expect(again.home.cards.map(\.id) == ["old1", "x"])
    #expect(again.home.stale)
    again.home.loadMore()
    await until { !again.home.stale && !again.home.loading }
    #expect(again.home.cards.map(\.id) == ["x", "new", "old1"])
    #expect(again.home.cards[0].sub == "30 集")
}

/// The recommendations skip server pages that bring nothing.
@MainActor @Test func discoverSkipsEmptyPages() async {
    let (model, catalog) = testModel()
    catalog.update {
        $0.discoverPages[""] = Page(items: [], cursor: "1", hasMore: true)
        $0.discoverPages["1"] = Page(items: [SeriesSummary(id: "a", title: "A")], cursor: "2", hasMore: true)
    }
    model.home.loadMore()
    await until { model.home.started && !model.home.loading }
    #expect(model.home.cards.map(\.id) == ["a"])
    #expect(catalog.calls == ["discover:", "discover:1"])
}

/// A feed that fails tries again by itself while it has nothing to show.
@MainActor @Test func feedRetriesByItself() async {
    let attempts = Mutex(0)
    let f = Feed { _ in
        let n = attempts.withLock { $0 += 1; return $0 }
        if n == 1 { throw URLError(.timedOut) }
        return FeedPage(cards: [Card(id: "a", title: "A")])
    }
    f.loadMore()
    await until { f.error != nil }
    #expect(f.retrying)
    #expect(friendly(f.error) == "网络连接不稳定，请稍后重试")
    await until { !f.cards.isEmpty } // the first retry waits two seconds
    for _ in 0..<60 where f.cards.isEmpty {
        try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(f.cards.map(\.id) == ["a"])
    #expect(f.error == nil)
}

/// Search reads the 剧集 tab, falls back to 综合, and fills in the covers
/// the results come without.
@MainActor @Test func searchFallsBackAndFillsCovers() async throws {
    let catalog = FakeCatalog()
    catalog.update {
        $0.search = { _, o in
            if o.tab == "剧集" { throw OpenhongguoError(code: .paramInvalid, message: "bad tab") }
            return Page(items: [SeriesSummary(id: "1", title: "持械入宋：第二季"), SeriesSummary(id: "2", title: "持械入宋：第一季")],
                        cursor: "20", hasMore: true)
        }
        $0.batch = ["1": Series(id: "1", coverUrl: "https://c/1.heic", episodeCount: 80, status: .end)]
    }
    let page = try await AppModel.search(catalog, "持械入宋", cursor: "")
    #expect(page.cards.map(\.id) == ["1", "2"])
    #expect(page.cards[0].cover == "https://c/1.heic")
    #expect(page.cards[0].sub == "全 80 集")
    #expect(catalog.calls == ["search:持械入宋:剧集", "search:持械入宋:"])

    // The feed puts the seasons in order.
    let (model, _) = testModel(catalog)
    let f = model.searchFeed(" 持械入宋 ")
    f.loadMore()
    await until { !f.cards.isEmpty }
    #expect(f.cards.map(\.id) == ["2", "1"])
}

/// What anonymous search can't find is an empty result, not an error.
@MainActor @Test func searchFindsNothing() async throws {
    let catalog = FakeCatalog()
    catalog.update { $0.search = { _, _ in throw OpenhongguoError(code: .anonymousLimited, message: "") } }
    let page = try await AppModel.search(catalog, "无", cursor: "")
    #expect(page.cards.isEmpty)
}

/// Suggestions show their text, not the series ID a suggestion that leads
/// straight to a series carries as its keyword.
@MainActor @Test func suggestionsAreText() async {
    let (model, catalog) = testModel()
    catalog.update {
        $0.suggestions = [Suggestion(text: "持械入宋：第一季", keyword: "7671966197985856536", kind: 2),
                          Suggestion(text: "总裁系列", keyword: "总裁系列", kind: 1),
                          Suggestion(text: " 持械入宋：第一季 ", keyword: "1", kind: 2),
                          Suggestion(text: "", keyword: "7666404568275635224", kind: 2)]
    }
    #expect(await model.suggestions(" 持械 ") == ["持械入宋：第一季", "总裁系列"])
    #expect(await model.suggestions("  ").isEmpty)
}

/// A series' page loads its episodes, and its seasons, which every season's
/// page then shares.
@MainActor @Test func seriesAndSeasons() async {
    let (model, catalog) = testModel()
    catalog.update {
        $0.series["1"] = Series(id: "1", title: "浅浅归聿", episodeCount: 130, platform: .outer, isMultiSeason: true)
        $0.episodes["1"] = episodes("1", 130, locked: [3])
        $0.albums["1"] = Album(seasons: [Season(seriesId: "s2", title: "浅浅归聿第二季", episodeCount: 80),
                                         Season(seriesId: "1", title: "浅浅归聿", episodeCount: 130),
                                         Season(seriesId: "s3", title: "浅浅归聿第三季")])
    }
    let sp = model.seriesPage("1")
    await until { sp.seasons != nil }
    #expect(sp.episodes.count == 130)
    #expect(sp.parts == ["1–100", "101–130"])
    #expect(sp.partEpisodes.count == 100)
    sp.part = 1
    #expect(sp.partEpisodes.first?.number == 101)
    #expect(sp.seasons?.map(\.seriesId) == ["1", "s2", "s3"])
    #expect(model.seriesEntry("s2").seasons?.count == 3)

    // After the last episode of a season comes the next season's first.
    #expect(model.following(sp, 5)! == ("1", 6))
    #expect(model.following(sp, 2) == nil) // the third needs a login
    #expect(model.following(sp, 130)! == ("s2", 1))

    // The series offers to go on where the viewer was.
    #expect(model.resumePoint(sp).label == "播放第 1 集")
    model.history.record(Watch(seriesID: "1", title: "浅浅归聿", episode: 7, position: 42))
    let r = model.resumePoint(sp)
    #expect(r.label == "继续看第 7 集")
    #expect(r.start == 39)
    model.history.record(Watch(seriesID: "1", episode: 130, finished: true))
    #expect(model.resumePoint(sp).label == "播放第 2 季")
    #expect(model.resumePoint(sp).seriesID == "s2")
}

/// A series that is gone says so.
@MainActor @Test func seriesGone() async {
    let (model, _) = testModel()
    let sp = model.seriesPage("missing")
    await until { !sp.loading }
    #expect(sp.series == nil)
    #expect(friendly(sp.error) == "内容已下架或不存在")
}

/// The player waits for the series, then tries the episode; a locked
/// episode, or one the server won't give, says why.
@MainActor @Test func playerStates() async {
    let (model, catalog) = testModel()
    catalog.update {
        $0.series["1"] = Series(id: "1", title: "浅浅归聿", episodeCount: 3, platform: .outer)
        $0.episodes["1"] = episodes("1", 3, locked: [3])
    }
    model.player.play("1", 3)
    #expect(model.player.state == .resolving)
    #expect(model.player.isPresented)
    await until { model.player.state != .resolving }
    #expect(model.player.state == .failed("这一集需要登录才能观看"))

    model.player.play("1", 1)
    await until { model.player.state != .resolving }
    #expect(model.player.state == .failed("这一集暂时无法匿名播放，可以稍后再试"))
    #expect(model.history.get("1")?.episode == 1)
    #expect(model.player.hasNext)
    #expect(!model.player.hasPrevious)

    model.player.leave()
    #expect(!model.player.isPresented)
}

/// Holding the video plays it at double speed until the finger lifts; a
/// swipe down locks it on, and a later hold that swipes up goes back to the
/// speed the viewer chose.
@MainActor @Test func doubleSpeedWhileHeld() {
    let (model, _) = testModel()
    let p = model.player
    p.av.defaultRate = 1.5 // from the speed menu
    p.av.rate = 1.5

    p.beginHold()
    #expect(p.doubleSpeed == .held)
    #expect(p.av.rate == 2)
    #expect(p.av.defaultRate == 1.5)
    p.endHold(swiped: false)
    #expect(p.doubleSpeed == .off)
    #expect(p.av.rate == 1.5)

    p.beginHold()
    p.endHold(swiped: true)
    #expect(p.doubleSpeed == .locked)
    #expect(p.av.rate == 2)
    #expect(p.av.defaultRate == 2) // the next episode, and the menu, too

    // Holding again only shows it; a swipe the wrong way changes nothing.
    p.beginHold()
    #expect(p.doubleSpeed == .locked)
    p.endHold(swiped: false)
    #expect(p.doubleSpeed == .locked)
    #expect(p.av.rate == 2)

    p.av.pause()
    p.beginHold()
    p.endHold(swiped: true)
    #expect(p.doubleSpeed == .off)
    #expect(p.av.defaultRate == 1.5)
    #expect(p.av.rate == 0) // still paused

    // 2× picked from the menu counts as locked.
    p.av.defaultRate = 2
    p.beginHold()
    #expect(p.doubleSpeed == .locked)
}

/// What the viewer watched and saved survives a restart, in files the
/// macOS app's Go code reads and writes too.
@MainActor @Test func historyAndFavoritesPersist() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kxg-\(UUID().uuidString)")
    let h = History(dir: dir)
    h.record(Watch(seriesID: "1", title: "甲", episode: 3, position: 12.5))
    h.record(Watch(seriesID: "2", title: "乙", episode: 1))
    h.record(Watch(seriesID: "1", title: "甲", episode: 4))
    h.flush()
    let f = Favorites(dir: dir)
    #expect(f.toggle(Fav(Card(id: "9", title: "收藏的剧", episodes: 60))))
    #expect(f.has("9"))
    f.add(Fav(seriesID: "8", title: "另一部"))
    f.flush()

    let h2 = History(dir: dir)
    #expect(h2.list.map(\.seriesID) == ["1", "2"])
    #expect(h2.get("1")?.episode == 4)
    let f2 = Favorites(dir: dir)
    #expect(f2.list.map(\.seriesID) == ["8", "9"])
    #expect(f2.cards.last?.sub == "60 集")
    #expect(!f2.toggle(Fav(seriesID: "9", title: "")))
    #expect(!f2.has("9"))

    // A file the Go app wrote, with nanoseconds and an offset.
    let goFile = """
    [{"series_id":"7","title":"浅浅归聿","episode":7,"position":42.1,"updated":"2026-11-05T16:02:03.123456789+08:00"},
     {"series_id":"8","title":"无进度","episode":1,"updated":"2026-11-05T08:00:00Z"}]
    """
    let goDir = dir.appendingPathComponent("go")
    try FileManager.default.createDirectory(at: goDir, withIntermediateDirectories: true)
    try Data(goFile.utf8).write(to: goDir.appendingPathComponent("history.json"))
    let h3 = History(dir: goDir)
    #expect(h3.list.count == 2)
    #expect(h3.get("7")?.position == 42.1)
    #expect(h3.get("7")?.watched == [])
    let updated = try #require(h3.get("7")?.updated)
    #expect(abs(updated.timeIntervalSince1970 - 1_793_865_723.123) < 0.01)
}

/// The episodes watched add up as the viewer goes on, and a later record
/// that doesn't mention them keeps them.
@MainActor @Test func historyKeepsWatchedEpisodes() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kxg-\(UUID().uuidString)")
    let h = History(dir: dir)
    h.record(Watch(seriesID: "1", episode: 3, finished: true, watched: [3]))
    h.record(Watch(seriesID: "1", episode: 1, watched: [1]))
    h.record(Watch(seriesID: "1", episode: 2, position: 5))
    h.record(Watch(seriesID: "2", episode: 1))
    h.record(Watch(seriesID: "1", episode: 3, watched: [3]))
    #expect(h.get("1")?.watched == [1, 3])
    #expect(h.get("2")?.watched == [])
    h.flush()
    #expect(History(dir: dir).get("1")?.watched == [1, 3])

    #expect(watchedEnough(54, 60, finished: false))
    #expect(!watchedEnough(53, 60, finished: false))
    #expect(!watchedEnough(5, 0, finished: false)) // the length isn't known yet
    #expect(watchedEnough(0, 0, finished: true))
}

/// A player waiting for a series that fails to load says why, rather than
/// spinning forever.
@MainActor @Test func playerSaysWhySeriesFailed() async {
    let (model, _) = testModel()
    model.player.play("missing", 1)
    await until { model.player.state != .resolving }
    #expect(model.player.state == .failed("内容已下架或不存在"))
}

/// Leaving the player while an episode is on its way keeps it from
/// starting behind the viewer's back.
@MainActor @Test func leavingCancelsTheStart() async {
    let (model, catalog) = testModel()
    catalog.update {
        $0.series["1"] = Series(id: "1", title: "甲", episodeCount: 2, platform: .outer)
        $0.episodes["1"] = episodes("1", 2)
    }
    let sp = model.seriesPage("1")
    await until { sp.series != nil }
    model.player.play("1", 1)
    model.player.leave()
    #expect(model.player.state == .idle)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(model.player.state == .idle) // not failed: the resolve's answer went unheard
    #expect(model.player.av.currentItem == nil)
}

/// Pulling the recommendations down puts the fresh ones first and goes on
/// from where the grid had got to.
@MainActor @Test func mergingRefreshKeepsItsPlace() async {
    let calls = Mutex(0)
    let f = Feed { cursor in
        let n = calls.withLock { $0 += 1; return $0 }
        switch cursor {
        case "": return FeedPage(cards: [Card(id: "r\(n)", title: "新\(n)")], cursor: "p2", more: true)
        case "p2": return FeedPage(cards: [Card(id: "b", title: "B")], cursor: "p3", more: true)
        default: return FeedPage(cards: [Card(id: "c", title: "C")], cursor: "p4", more: true)
        }
    }
    f.loadMore()
    await until { f.cards.count == 1 }
    f.loadMore()
    await until { f.cards.count == 2 }
    await f.refresh(merging: true)
    #expect(f.cards.map(\.id) == ["r3", "r1", "b"])
    f.loadMore()
    await until { f.cards.count == 4 }
    #expect(f.cards.last?.id == "c") // the third page, not the second again
    #expect(f.more)
}
