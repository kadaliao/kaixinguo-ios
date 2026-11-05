import Foundation
import Observation
import Openhongguo

/// AppModel is the state the app shows. It belongs to the main actor:
/// work elsewhere hands its results back to it.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored public let catalog: any Catalog
    public let history: History
    public let favorites: Favorites
    @ObservationIgnored public let covers: CoverStore
    @ObservationIgnored let cacheDir: URL
    /// The player, made once the model is: it refers back to it.
    @ObservationIgnored private var _player: Player!
    public var player: Player { _player }

    // The catalog.
    public let home: Feed
    @ObservationIgnored var feeds: [String: Feed] = [:]
    public private(set) var rankContents: [RankContent] = []
    /// The chart content chosen; empty for the one the server chose.
    public var rankContent = ""
    /// The board chosen; empty for the one the server chose.
    public var rankBoard = ""
    /// The day of new releases chosen; empty for today.
    public var newDate = ""
    public private(set) var newDates: [String] = []
    public private(set) var hot: HotSearch?
    public private(set) var hotLoading = false
    public private(set) var hotError: Error?

    // Series.
    @ObservationIgnored var series: [String: SeriesPage] = [:]

    public init(catalog: any Catalog, dataDir: URL, cacheDir: URL) {
        self.catalog = catalog
        self.cacheDir = cacheDir
        history = History(dir: dataDir)
        favorites = Favorites(dir: dataDir)
        covers = CoverStore(dir: cacheDir.appendingPathComponent("covers"))
        home = Feed(fetch: Self.discover(catalog))
        _player = Player(app: self)
        // Last launch's recommendations show at once; fresh ones join them.
        let cached = loadHomeCache()
        if !cached.isEmpty {
            home.add(FeedPage(cards: cached, more: true))
            home.stale = true
        }
        home.onPage = { [unowned self] _ in saveHomeCache(home.cards) }
    }

    /// The app's own model, its files where iOS keeps an app's data.
    public static func live() throws -> AppModel {
        let fm = FileManager.default
        let data = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let cache = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AppModel(catalog: try OpenhongguoClient.app(), dataDir: data, cacheDir: cache)
    }

    /// Writes what is waiting to be saved, as the app leaves the screen.
    public func flush() {
        history.flush()
        favorites.flush()
    }

    /// The feed of key, made with make the first time.
    func feed(_ key: String, make: () -> Feed) -> Feed {
        if let f = feeds[key] {
            return f
        }
        let f = make()
        feeds[key] = f
        return f
    }

    // MARK: - 推荐

    /// Reads the recommended channel one server page at a time, so each
    /// shows as soon as it comes; the grid asks for the next as it nears
    /// its end.
    static func discover(_ catalog: any Catalog) -> Feed.Fetcher {
        { cursor in
            var out = FeedPage(cursor: cursor)
            for _ in 0..<3 { // past pages that bring nothing
                let p = try await catalog.discover(DiscoverOptions(cursor: out.cursor))
                out.cards += p.items.map(Card.init)
                out.cursor = p.cursor
                out.more = p.hasMore
                if !out.cards.isEmpty || !p.hasMore {
                    break
                }
            }
            return out
        }
    }

    // MARK: - 排行榜

    /// Contents with charts of series; the actors' chart has none.
    public var chartContents: [RankContent] {
        rankContents.filter { !$0.id.isEmpty && !$0.boards.isEmpty && !$0.name.contains("演员") }
    }

    /// The content whose charts show: the one chosen, else the one the
    /// server chose.
    public var currentRankContent: String {
        let contents = chartContents
        if !rankContent.isEmpty {
            return rankContent
        }
        return contents.first(where: \.selected)?.id ?? contents.first?.id ?? ""
    }

    /// The boards of the content showing.
    public var rankBoards: [RankBoard] {
        let cur = currentRankContent
        return chartContents.first { $0.id == cur }?.boards ?? []
    }

    /// Whether the board shows: the one chosen, else the server's choice.
    public func boardIsOn(_ b: RankBoard) -> Bool {
        b.id == rankBoard || (rankBoard.isEmpty && b.selected)
    }

    public var rankFeed: Feed {
        let content = rankContent, board = rankBoard, catalog = catalog
        return feed("rank:\(content):\(board)") {
            let f = Feed { cursor in
                let r = try await catalog.shortRank(ShortRankQuery(content: content, board: board, cursor: cursor))
                var out = FeedPage(cursor: r.cursor, more: r.hasMore)
                out.contents = r.contents
                out.board = r.board
                for it in r.items where !it.seriesId.isEmpty { // the others are actors' rows
                    out.cards.append(Card(id: it.seriesId, title: it.title, cover: it.coverUrl,
                                          sub: it.score.isEmpty ? episodeCount(it.episodeCount) : it.score,
                                          rank: it.position, episodes: it.episodeCount))
                }
                return out
            }
            f.onPage = { [unowned self] p in
                if !p.contents.isEmpty {
                    rankContents = p.contents
                }
            }
            return f
        }
    }

    // MARK: - 新剧上线

    public var newFeed: Feed {
        let date = newDate, catalog = catalog
        return feed("new:\(date)") {
            let f = Feed { cursor in
                let r = try await catalog.newReleases(NewReleaseQuery(date: date, cursor: cursor))
                var out = FeedPage(cursor: r.cursor, more: r.hasMore)
                out.dates = r.dates
                for it in r.items {
                    let sub = !it.online && !it.note.isEmpty ? it.note : it.heat
                    out.cards.append(Card(id: it.seriesId, title: it.title, cover: it.coverUrl, sub: sub,
                                          episodes: it.episodeCount))
                }
                return out
            }
            f.onPage = { [unowned self] p in
                if !p.dates.isEmpty {
                    newDates = p.dates
                }
            }
            return f
        }
    }

    /// Whether the day shows: the one chosen, else today.
    public func dayIsOn(_ d: String) -> Bool {
        d == newDate || (newDate.isEmpty && d == todayKey())
    }

    public func chooseDay(_ d: String) {
        newDate = d == todayKey() ? "" : d
    }

    // MARK: - 搜索

    public func searchFeed(_ query: String) -> Feed {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines), catalog = catalog
        return feed("search:\(q)") {
            let f = Feed { cursor in try await Self.search(catalog, q, cursor: cursor) }
            f.order = orderSeasons
            return f
        }
    }

    static func search(_ catalog: any Catalog, _ q: String, cursor: String) async throws -> FeedPage {
        let limited: (Error) -> Bool = { isCode($0, .anonymousLimited, .endOfList) }
        // The 剧集 tab lists each season of a series; 综合 shows its first
        // season alone, among clips.
        var r: Page<SeriesSummary>
        do {
            r = try await catalog.search(q, options: SearchOptions(cursor: cursor, pageSize: 20, tab: "剧集"))
        } catch where !limited(error) {
            do {
                r = try await catalog.search(q, options: SearchOptions(cursor: cursor, pageSize: 20))
            } catch where limited(error) {
                return FeedPage() // nothing found
            }
        } catch {
            return FeedPage()
        }
        var out = FeedPage(cursor: r.cursor, more: r.hasMore && !r.items.isEmpty)
        out.cards = r.items.map(Card.init)
        // Search results come without covers: read them from the details.
        let missing = r.items.filter { $0.coverUrl.isEmpty }.map(\.id)
        if !missing.isEmpty, let details = try? await catalog.getSeriesBatch(missing) {
            var byID: [String: Series] = [:]
            for d in details {
                if let s = d.series {
                    byID[s.id] = s
                }
            }
            for i in out.cards.indices {
                guard let s = byID[out.cards[i].id] else { continue }
                out.cards[i].cover = s.coverUrl
                if s.episodeCount > 0 {
                    out.cards[i].sub = episodesLabel(s)
                    out.cards[i].episodes = s.episodeCount
                }
            }
        }
        return out
    }

    /// Words people complete the prefix to, as they type a search. They
    /// are the suggestions' text: a suggestion that leads straight to a
    /// series has its ID for a keyword, and not every such ID is a series
    /// the app can open, so the text is what gets searched.
    public func suggestions(_ prefix: String) async -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, let list = try? await catalog.suggest(p) else { return [] }
        var seen = Set<String>()
        return list.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - 热搜

    /// Loads what people search for, unless it is here or on its way.
    public func loadHot(force: Bool = false) {
        guard !hotLoading, force || (hot == nil && hotError == nil) else { return }
        Task { await reloadHot() }
    }

    /// Loads what people search for again, and returns once it has.
    public func reloadHot() async {
        guard !hotLoading else { return }
        hotLoading = true
        hotError = nil
        do {
            hot = try await catalog.hotSearch()
        } catch {
            if hot == nil {
                hotError = error
            }
        }
        hotLoading = false
    }

    // MARK: - 收藏

    /// The 收藏 grid, rebuilt from the list whenever that changes.
    public var favoritesFeed: Feed {
        Feed(cards: favorites.cards)
    }

    // MARK: - The home cache

    /// The first page of recommendations, so the next launch shows them at
    /// once.
    var homeCacheURL: URL { cacheDir.appendingPathComponent("home.json") }

    func loadHomeCache() -> [Card] {
        guard let data = try? Data(contentsOf: homeCacheURL) else { return [] }
        return (try? JSONDecoder().decode([Card].self, from: data)) ?? []
    }

    func saveHomeCache(_ cards: [Card]) {
        let cards = Array(cards.prefix(48)), url = homeCacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cards) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
