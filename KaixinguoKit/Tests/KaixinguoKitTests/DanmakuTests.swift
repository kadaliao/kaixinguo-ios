import Foundation
import Openhongguo
import Testing

@testable import KaixinguoKit

/// A danmaku written s seconds into the episode.
private func at(_ s: Double, _ text: String) -> Danmaku {
    Danmaku(text: text, offsetMs: Int(s * 1000))
}

/// Danmaku take the top lane with room at their moment; with every lane
/// full they wait a little for one, or are left out. None runs into the one
/// ahead of it.
@MainActor @Test func placesDanmakuInLanes() throws {
    let reel = DanmakuReel(seriesID: "1", episodeID: "1e1")
    let ten = "一二三四五六七八九十"
    let input = [
        at(0, "哈哈哈"), at(0.5, "前方高能"), at(1, "abc"), // lane 0 has room again at 1
        at(2, ten), at(2, ten), at(2, ten), at(2.5, ten), // every lane full until 4.4
        at(3, "好"), // waits 1.4 seconds for lane 0
        at(2.8, "来晚了"), // would wait 1.6: left out
        at(3, "  \n "), // nothing to say
        at(3, "多行\n弹幕"), // waits for lane 1
    ]
    let placed = input.map(reel.place)
    #expect(placed.map { $0?.lane } == [0, 1, 0, 0, 1, 2, 3, 0, nil, nil, 1])
    #expect(placed[10]?.text == "多行 弹幕")
    let waited = try #require(placed[7])
    #expect(abs(waited.start - 4.4) < 1e-9)

    let flights = placed.compactMap { $0 }
    for lane in 0..<DanmakuFlight.lanes {
        let inLane = flights.filter { $0.lane == lane }
        for (a, b) in zip(inLane, inLane.dropFirst()) {
            #expect(b.start >= a.start + (a.width + DanmakuFlight.gap) / DanmakuFlight.speed - 1e-9, "lane \(lane)")
        }
    }
}

/// A danmaku comes in at the right edge at its moment and goes left, until
/// it is out of sight.
@Test func danmakuFliesLeft() {
    let f = DanmakuFlight(text: "哈哈", start: 10, lane: 0, width: 2)
    #expect(f.x(at: 9.9, across: 24) == nil)
    #expect(f.x(at: 10, across: 24) == 24)
    #expect(f.x(at: 12, across: 24) == 14)
    #expect(f.x(at: 15, across: 24) == -1) // its end still shows
    #expect(f.x(at: 16, across: 24) == nil)
}

@Test func danmakuWidths() {
    #expect(ems("") == 0)
    #expect(ems("哈哈") == 2)
    #expect(abs(ems("ab") - 1.2) < 1e-9)
    #expect(ems("😂") == 1.25)
}

/// The player reads every page of the episode's danmaku, empty ones
/// included, once; the next episode has its own.
@MainActor @Test func readsEveryPageOfDanmaku() async throws {
    let (model, catalog) = testModel()
    catalog.update {
        $0.series["1"] = Series(id: "1", title: "甲", episodeCount: 2, platform: .outer)
        $0.episodes["1"] = episodes("1", 2)
        $0.danmaku["1e1:"] = DanmakuPage(items: [Danmaku(id: "a", text: "开头", offsetMs: 1_000)],
                                         endMs: 30_000, hasMore: true, cursor: "c1")
        // Nobody wrote anything in the second half minute.
        $0.danmaku["1e1:c1"] = DanmakuPage(startMs: 30_000, endMs: 60_000, hasMore: true, cursor: "c2")
        $0.danmaku["1e1:c2"] = DanmakuPage(items: [Danmaku(id: "b", text: "结尾", offsetMs: 65_000)],
                                           startMs: 60_000, endMs: 90_000)
        $0.danmaku["1e2:"] = DanmakuPage(items: [Danmaku(id: "c", text: "第二集", offsetMs: 2_000)])
    }
    let p = model.player
    #expect(p.danmaku() == nil) // nothing playing
    p.play("1", 1)
    await until { model.seriesEntry("1").series != nil }
    let reel = try #require(p.danmaku())
    #expect(p.danmaku() === reel)
    await until { !reel.loading }
    #expect(reel.flights.map(\.text) == ["开头", "结尾"])
    #expect(reel.flights.map(\.start) == [1, 65])
    #expect(reel.error == nil)
    #expect(catalog.calls.filter { $0.hasPrefix("danmaku:") } == ["danmaku:1e1:", "danmaku:1e1:c1", "danmaku:1e1:c2"])

    p.play("1", 2)
    let next = try #require(p.danmaku())
    #expect(next !== reel)
    #expect(next.episodeID == "1e2")
    await until { !next.loading }
    #expect(p.danmaku() === next)
    #expect(next.flights.map(\.text) == ["第二集"])
    #expect(catalog.calls.filter { $0.hasPrefix("danmaku:") }.count == 4)
}
