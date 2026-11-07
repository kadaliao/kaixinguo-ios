import Foundation

/// Session is where the viewer was: the tab, the series pages open in each,
/// the search, the chart and the day chosen, and the episode the player had
/// open. The app saves it as it changes, and the next launch opens there
/// again, the episode paused where the viewer got to.
public struct Session: Codable, Equatable, Sendable {
    /// The tab showing, by name.
    public var tab = ""
    /// The series pages open in each tab, by the tab's name, the first
    /// opened first.
    public var pages: [String: [String]] = [:]
    /// What the search field held, and the search whose results showed.
    public var searchText = ""
    public var searchQuery = ""
    public var rankContent = ""
    public var rankBoard = ""
    public var newDate = ""
    /// The episode the player had open, on its screen or in picture in
    /// picture; nil when it was closed.
    public var playing: Playing?

    public struct Playing: Codable, Equatable, Sendable {
        public var seriesID: String
        public var episode: Int

        enum CodingKeys: String, CodingKey {
            case seriesID = "series_id"
            case episode
        }
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case tab, pages, playing
        case searchText = "search_text"
        case searchQuery = "search_query"
        case rankContent = "rank_content"
        case rankBoard = "rank_board"
        case newDate = "new_date"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tab = try c.decodeIfPresent(String.self, forKey: .tab) ?? ""
        pages = try c.decodeIfPresent([String: [String]].self, forKey: .pages) ?? [:]
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        searchQuery = try c.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
        rankContent = try c.decodeIfPresent(String.self, forKey: .rankContent) ?? ""
        rankBoard = try c.decodeIfPresent(String.self, forKey: .rankBoard) ?? ""
        newDate = try c.decodeIfPresent(String.self, forKey: .newDate) ?? ""
        playing = try c.decodeIfPresent(Playing.self, forKey: .playing)
    }
}

extension AppModel {
    /// The model's part of where the viewer is: the chart and the day
    /// chosen, and the episode the player has open. The app adds its own,
    /// the tab and the pages.
    public var session: Session {
        var s = Session()
        s.rankContent = rankContent
        s.rankBoard = rankBoard
        s.newDate = newDate
        if let id = player.seriesID, player.isPresented || player.inPictureInPicture {
            s.playing = Session.Playing(seriesID: id, episode: player.number)
        }
        return s
    }

    /// The session the app was left in, nil on its first launch.
    public func lastSession() -> Session? {
        sessions.load().first
    }

    /// Saves the session, unless it is the one saved last.
    public func save(_ s: Session) {
        guard s != savedSession else { return }
        savedSession = s
        sessions.save([s])
    }

    /// Opens the model where the session left it: the chart and the day
    /// chosen, and the episode, paused where the viewer got to.
    public func restore(_ s: Session) {
        savedSession = s
        rankContent = s.rankContent
        rankBoard = s.rankBoard
        // The calendar shows a week either side of today; a day gone from
        // it since goes back to today.
        if let d = daysFrom(todayKey(), to: s.newDate), abs(d) <= 7 {
            newDate = s.newDate
        }
        if let p = s.playing {
            var start = 0.0
            if let w = history.get(p.seriesID), w.episode == p.episode, !w.finished {
                start = w.position
            }
            player.play(p.seriesID, p.episode, start: start, paused: true)
        }
    }
}
