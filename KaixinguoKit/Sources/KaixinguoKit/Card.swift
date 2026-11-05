import Foundation
import Openhongguo

/// Card is a series as a grid shows it.
public struct Card: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cover: String
    /// The line under the title.
    public var sub: String
    /// Its place on a chart; 0 off charts.
    public var rank: Int
    /// How many episodes the series has, when the page that listed it said:
    /// `sub` may say something else, as a chart's score.
    public var episodes: Int

    public init(id: String, title: String, cover: String = "", sub: String = "", rank: Int = 0, episodes: Int = 0) {
        self.id = id
        self.title = title
        self.cover = cover
        self.sub = sub
        self.rank = rank
        self.episodes = episodes
    }

    enum CodingKeys: String, CodingKey {
        case id, title, cover, sub, rank, episodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        sub = try c.decodeIfPresent(String.self, forKey: .sub) ?? ""
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
        episodes = try c.decodeIfPresent(Int.self, forKey: .episodes) ?? 0
    }

    public init(_ s: SeriesSummary) {
        self.init(id: s.id, title: s.title, cover: s.coverUrl, sub: episodeCount(s.episodeCount), episodes: s.episodeCount)
    }

    /// The card of a series' page, as the grids show it.
    public init(_ s: Series) {
        self.init(id: s.id, title: s.title, cover: s.coverUrl, sub: episodeCount(s.episodeCount), episodes: s.episodeCount)
    }
}

/// FeedPage is what a feed's fetch returns.
public struct FeedPage: Sendable {
    public var cards: [Card] = []
    public var cursor = ""
    public var more = false
    // What some feeds also tell.
    public var contents: [RankContent] = []
    public var board = ""
    public var dates: [String] = []

    public init(cards: [Card] = [], cursor: String = "", more: Bool = false) {
        self.cards = cards
        self.cursor = cursor
        self.more = more
    }
}

// MARK: - Labels

/// A card's line for a series of n episodes, or nothing when n is unknown.
public func episodeCount(_ n: Int) -> String {
    n > 0 ? "\(n) 集" : ""
}

/// The series' episodes as its page says them: 更新至 12 集, 全 80 集.
public func episodesLabel(_ s: Series) -> String {
    if !s.rightText.isEmpty {
        return s.rightText
    }
    if s.status == .updating {
        return "更新至 \(s.episodeCount) 集"
    }
    return "全 \(s.episodeCount) 集"
}

/// Writes a count as the Hongguo app does: 4165万, 1.2亿.
public func heat(_ n: Int) -> String {
    switch n {
    case 100_000_000...:
        var s = String(format: "%.1f", Double(n) / 1e8)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s + "亿"
    case 10_000...:
        return "\(n / 10_000)万"
    default:
        return "\(n)"
    }
}

/// The series at a glance: its kind, its episodes, its heat.
public func metaLine(_ s: Series) -> String {
    var parts: [String] = []
    if let row = s.rows.first(where: { $0.kind == .category && !$0.text.isEmpty }) {
        parts.append(row.text)
    }
    switch s.contentType {
    case .motionComic: parts.append("漫剧")
    case .movie: parts.append("电影")
    default: break
    }
    if s.episodeCount > 0 {
        parts.append(episodesLabel(s))
    }
    if s.heat > 0 {
        parts.append("热度 " + heat(s.heat))
    }
    return parts.joined(separator: "  ·  ")
}

/// Names a day of the calendar (YYYYMMDD) as people say it.
public func dayLabel(_ d: String, today: String) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd"
    guard let day = f.date(from: d), let now = f.date(from: today) else { return d }
    let cal = Calendar(identifier: .gregorian)
    switch cal.dateComponents([.day], from: now, to: day).day ?? 99 {
    case 0: return "今天"
    case 1: return "明天"
    case -1: return "昨天"
    default:
        let c = cal.dateComponents([.month, .day], from: day)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}

/// Today as the calendar of new releases names days.
public func todayKey(_ now: Date = Date()) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd"
    return f.string(from: now)
}

public func seasonLabel(_ se: Season) -> String { "第 \(se.index) 季" }

/// Names the action on a series that is, or is not, saved.
public func favLabel(_ saved: Bool) -> String { saved ? "取消收藏" : "收藏" }
