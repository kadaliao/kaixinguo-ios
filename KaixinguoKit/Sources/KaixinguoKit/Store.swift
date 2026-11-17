import Foundation
import Observation
import Synchronization

/// JSONStore keeps a list of values as JSON, in a file or in the user
/// defaults. The list itself belongs to its owner on the main actor; the
/// store only writes snapshots of it, on a queue of its own, so saving
/// never holds up a frame.
public final class JSONStore<T: Codable & Sendable>: Sendable {
    /// Where a store keeps its list.
    public enum Place: Sendable {
        /// A file of its own.
        case file(URL)
        /// The user defaults of suite (the app's own when nil), under key,
        /// in at most budget bytes. tvOS keeps an app's own defaults, up to
        /// 500 KB, but may delete any of its files when storage runs low.
        case defaults(key: String, suite: String? = nil, budget: Int)
    }

    public let place: Place
    /// The file the list is in, when it is in one.
    public var url: URL? {
        if case .file(let url) = place { url } else { nil }
    }
    private let queue = DispatchQueue(label: "kaixinguo.store", qos: .utility)
    private let pending = Mutex<[T]?>(nil)

    public convenience init(url: URL) {
        self.init(.file(url))
    }

    public init(_ place: Place) {
        self.place = place
    }

    /// Reads the list. One that is missing or unreadable reads as an empty
    /// list: the app opens clean rather than refusing to open.
    public func load() -> [T] {
        let data: Data?
        switch place {
        case .file(let url):
            data = try? Data(contentsOf: url)
        case .defaults(let key, let suite, _):
            data = Self.defaults(suite)?.data(forKey: key)
        }
        guard let data else { return [] }
        return (try? Self.decoder.decode([T].self, from: data)) ?? []
    }

    /// Saves the list. A snapshot still waiting to be written is dropped:
    /// only the latest matters.
    public func save(_ list: [T]) {
        let first = pending.withLock { p in
            defer { p = list }
            return p == nil
        }
        guard first else { return } // the write on its way takes this one
        queue.async { [self] in
            guard let list = pending.withLock({ p in defer { p = nil }; return p }) else { return }
            write(list)
        }
    }

    /// Waits until every list saved so far is on disk, as the app goes to
    /// the background.
    public func flush() {
        queue.sync {}
    }

    private func write(_ list: [T]) {
        switch place {
        case .file(let url):
            guard let data = try? Self.encoder.encode(list) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Written beside the file and moved over it, so a crash halfway
            // through cannot leave half a file behind.
            try? data.write(to: url, options: .atomic)
        case .defaults(let key, let suite, let budget):
            guard let data = Self.fit(list, in: budget) else { return }
            Self.defaults(suite)?.set(data, forKey: key)
        }
    }

    /// The list encoded in at most budget bytes, leaving out as many of its
    /// last entries, the oldest, as it takes.
    static func fit(_ list: [T], in budget: Int) -> Data? {
        var list = list[...]
        while true {
            guard let data = try? encoder.encode(Array(list)) else { return nil }
            if data.count <= budget || list.isEmpty {
                return data
            }
            // About the share that is over, and at least one.
            list = list.dropLast(max(1, list.count * (data.count - budget) / data.count))
        }
    }

    private static func defaults(_ suite: String?) -> UserDefaults? {
        guard let suite else { return .standard }
        return UserDefaults(suiteName: suite)
    }

    // Dates as Go writes them (RFC 3339 with fractions), so the files read
    // the same as the macOS app's.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = .withoutEscapingSlashes
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseRFC3339(s) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }
}

/// Reads an RFC 3339 time, with or without fractions of a second, of any
/// precision Go writes.
func parseRFC3339(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) {
        return d
    }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) {
        return d
    }
    // ISO8601DateFormatter reads three digits of a fraction at most: cut
    // Go's nanoseconds down to milliseconds.
    if let dot = s.firstIndex(of: "."),
       let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
        let frac = s[s.index(after: dot)..<end].prefix(3)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: String(s[..<dot]) + "." + frac + String(s[end...]))
    }
    return nil
}

/// Watch is where the viewer is in one series.
public struct Watch: Codable, Hashable, Identifiable, Sendable {
    public var seriesID: String
    public var title: String
    public var cover: String
    public var episode: Int
    /// Seconds into the episode.
    public var position: Double
    public var duration: Double
    /// Episodes in the series.
    public var total: Int
    public var finished: Bool
    public var updated: Date
    /// The episodes watched to the end, or nearly, in order.
    public var watched: [Int]

    public var id: String { seriesID }

    public init(seriesID: String, title: String = "", cover: String = "", episode: Int, position: Double = 0,
                duration: Double = 0, total: Int = 0, finished: Bool = false, updated: Date = Date(),
                watched: [Int] = []) {
        self.seriesID = seriesID
        self.title = title
        self.cover = cover
        self.episode = episode
        self.position = position
        self.duration = duration
        self.total = total
        self.finished = finished
        self.updated = updated
        self.watched = watched
    }

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case title, cover, episode, position, duration, total, finished, updated, watched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seriesID = try c.decode(String.self, forKey: .seriesID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        episode = try c.decodeIfPresent(Int.self, forKey: .episode) ?? 0
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
        watched = try c.decodeIfPresent([Int].self, forKey: .watched) ?? []
    }
}

/// History keeps the series watched, the latest first, in history.json,
/// or in a store of its own.
@MainActor @Observable
public final class History {
    /// How many series the history keeps.
    public static let max = 200

    public private(set) var list: [Watch]
    @ObservationIgnored let store: JSONStore<Watch>

    public convenience init(dir: URL) {
        self.init(store: JSONStore(url: dir.appendingPathComponent("history.json")))
    }

    public init(store: JSONStore<Watch>) {
        self.store = store
        list = store.load()
    }

    public func get(_ id: String) -> Watch? {
        list.first { $0.seriesID == id }
    }

    /// Moves w to the front. The episodes watched before stay watched,
    /// with w's own added.
    public func record(_ w: Watch) {
        var w = w
        w.updated = Date()
        if let old = get(w.seriesID), !old.watched.isEmpty {
            w.watched = Set(old.watched).union(w.watched).sorted()
        }
        var next = [w]
        next += list.lazy.filter { $0.seriesID != w.seriesID }.prefix(Self.max - 1)
        list = next
        store.save(list)
    }

    public func remove(_ id: String) {
        guard get(id) != nil else { return }
        list.removeAll { $0.seriesID == id }
        store.save(list)
    }

    public func flush() { store.flush() }
}

/// Fav is a series the viewer saved, with what a grid needs to show it
/// without asking the server again. It keeps the episodes rather than the
/// line its grid showed, which may be a chart's score or a day's heat and
/// would be stale on the 收藏 page.
public struct Fav: Codable, Hashable, Identifiable, Sendable {
    public var seriesID: String
    public var title: String
    public var cover: String
    public var episodes: Int
    public var added: Date

    public var id: String { seriesID }

    public init(seriesID: String, title: String, cover: String = "", episodes: Int = 0, added: Date = Date()) {
        self.seriesID = seriesID
        self.title = title
        self.cover = cover
        self.episodes = episodes
        self.added = added
    }

    /// The series as it would be saved.
    public init(_ k: Card) {
        self.init(seriesID: k.id, title: k.title, cover: k.cover, episodes: k.episodes)
    }

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case title, cover, episodes, added
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seriesID = try c.decode(String.self, forKey: .seriesID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        episodes = try c.decodeIfPresent(Int.self, forKey: .episodes) ?? 0
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? .distantPast
    }
}

/// Favorites keeps the series saved, the latest first, in favorites.json,
/// or in a store of its own.
@MainActor @Observable
public final class Favorites {
    public private(set) var list: [Fav]
    @ObservationIgnored private var ids: Set<String>
    @ObservationIgnored let store: JSONStore<Fav>

    public convenience init(dir: URL) {
        self.init(store: JSONStore(url: dir.appendingPathComponent("favorites.json")))
    }

    public init(store: JSONStore<Fav>) {
        let list = store.load()
        self.store = store
        self.list = list
        ids = Set(list.map(\.seriesID))
    }

    public func has(_ id: String) -> Bool {
        // Read list, so a view that asks follows the changes.
        _ = list.count
        return ids.contains(id)
    }

    /// Saves the series, or drops it when it is saved already, and reports
    /// whether it is saved now.
    @discardableResult
    public func toggle(_ x: Fav) -> Bool {
        if has(x.seriesID) {
            remove(x.seriesID)
            return false
        }
        add(x)
        return true
    }

    /// Saves the series, newest first.
    public func add(_ x: Fav) {
        guard !x.seriesID.isEmpty, !ids.contains(x.seriesID) else { return }
        var x = x
        x.added = Date()
        ids.insert(x.seriesID)
        list.insert(x, at: 0)
        store.save(list)
    }

    public func remove(_ id: String) {
        guard ids.remove(id) != nil else { return }
        list.removeAll { $0.seriesID == id }
        store.save(list)
    }

    /// The saved series as a grid shows them, the latest first.
    public var cards: [Card] {
        list.map { Card(id: $0.seriesID, title: $0.title, cover: $0.cover, sub: episodeCount($0.episodes), episodes: $0.episodes) }
    }

    public func flush() { store.flush() }
}
