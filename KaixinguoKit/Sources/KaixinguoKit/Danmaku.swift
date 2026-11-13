import Foundation
import Observation
import Openhongguo

/// DanmakuReel is the danmaku of an episode: what viewers wrote as it
/// played, each to fly across the top of the video, from right to left, at
/// the moment it was written. An episode has some tens or hundreds, so the
/// reel reads them all as the episode starts, and a seek finds them here.
/// It belongs to the main actor.
@MainActor @Observable
public final class DanmakuReel {
    public let seriesID: String
    public let episodeID: String
    /// The danmaku placed so far, in the order they came.
    public private(set) var flights: [DanmakuFlight] = []
    private(set) var loading = false
    @ObservationIgnored private(set) var error: Error?
    /// When each lane has room for the next danmaku, in seconds into the
    /// episode.
    @ObservationIgnored var free = Array(repeating: -Double.infinity, count: DanmakuFlight.lanes)
    @ObservationIgnored var task: Task<Void, Never>?

    init(seriesID: String, episodeID: String) {
        self.seriesID = seriesID
        self.episodeID = episodeID
    }

    /// Reads the episode's danmaku from its start, a page at a time, placing
    /// each page's as it comes. A page is a stretch of the episode, and may
    /// be empty with more after it.
    func load(_ catalog: any Catalog) {
        loading = true
        let seriesID = seriesID, episodeID = episodeID
        task = Task {
            var options = DanmakuOptions()
            do {
                while !Task.isCancelled {
                    let page = try await catalog.listDanmaku(seriesID, episodeId: episodeID, options: options)
                    flights += page.items.compactMap(place)
                    guard page.hasMore, !page.cursor.isEmpty else { break }
                    options = DanmakuOptions(cursor: page.cursor)
                }
            } catch {
                self.error = error
                debugLog("danmaku \(episodeID): \(error)")
            }
            loading = false
        }
    }

    /// Stops reading, as another episode's danmaku take over.
    func cancel() {
        task?.cancel()
    }

    /// Places a danmaku in the top lane with room for it at its moment; or,
    /// with every lane full, in the one with room soonest, if that is soon
    /// enough. Otherwise it is left out, rather than crowding the others or
    /// coming long after what it speaks of.
    func place(_ d: Danmaku) -> DanmakuFlight? {
        let text = d.text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let at = Double(d.offsetMs) / 1000
        var start = at
        var lane = free.firstIndex { $0 <= at }
        if lane == nil, let soonest = free.indices.min(by: { free[$0] < free[$1] }),
           free[soonest] - at <= DanmakuFlight.patience {
            lane = soonest
            start = free[soonest]
        }
        guard let lane else { return nil }
        let f = DanmakuFlight(text: text, start: start, lane: lane, width: ems(text))
        free[lane] = start + (f.width + DanmakuFlight.gap) / DanmakuFlight.speed
        return f
    }
}

/// DanmakuFlight is a danmaku on its way across the video: it comes in at
/// the right edge at its start and goes left at the same speed as all the
/// others, so it never catches up with the one ahead of it in its lane.
public struct DanmakuFlight: Hashable, Sendable {
    /// How many lanes danmaku fly along, from the top of the video down.
    public static let lanes = 4
    /// How fast danmaku fly, in ems a second.
    static let speed = 5.0
    /// The room a danmaku leaves behind it before the next in its lane comes
    /// in, in ems.
    static let gap = 2.0
    /// How long a danmaku may wait for a lane, in seconds.
    static let patience = 1.5

    public let text: String
    /// When it comes in, in seconds into the episode.
    public let start: Double
    /// Its lane, 0 at the top.
    public let lane: Int
    /// About how wide it is, in ems.
    public let width: Double

    /// Where its left edge is t seconds into the episode, in ems from the
    /// left of a view `across` ems wide; nil before it comes in, and once it
    /// is out of sight on the left, by a margin for a width guessed short.
    public func x(at t: Double, across: Double) -> Double? {
        guard t >= start else { return nil }
        let x = across - (t - start) * Self.speed
        return x + 2 * width + Self.gap > 0 ? x : nil
    }
}

/// About how wide a line of text is, in ems: a Chinese character fills
/// one, an emoji a little more, and a letter or digit some six tenths.
func ems(_ text: String) -> Double {
    text.reduce(0) { w, c in
        if c.isASCII {
            return w + 0.6
        }
        return w + (c.unicodeScalars.first?.properties.isEmojiPresentation == true ? 1.25 : 1)
    }
}

extension Player {
    /// The danmaku of the episode playing, read the first time they're
    /// asked for, as the player's screen shows them; nil until the episode
    /// is known. Only the last episode's are kept.
    public func danmaku() -> DanmakuReel? {
        guard let sp = page, let ep = sp.episode(number) else { return nil }
        if let reel, reel.episodeID == ep.id {
            return reel
        }
        reel?.cancel()
        let r = DanmakuReel(seriesID: sp.id, episodeID: ep.id)
        reel = r
        r.load(app.catalog)
        return r
    }
}
