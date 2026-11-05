import Foundation
import Observation
import Synchronization

/// JSONStore keeps a list of values in a JSON file. The list itself belongs
/// to its owner on the main actor; the store only writes snapshots of it,
/// on a queue of its own, so saving never holds up a frame.
public final class JSONStore<T: Codable & Sendable>: Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "kaixinguo.store", qos: .utility)
    private let pending = Mutex<[T]?>(nil)

    public init(url: URL) {
        self.url = url
    }

    /// Reads the list. A file that is missing or unreadable reads as an
    /// empty list: the app opens clean rather than refusing to open.
    public func load() -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
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
        guard let data = try? Self.encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written beside the file and moved over it, so a crash halfway
        // through cannot leave half a file behind.
        try? data.write(to: url, options: .atomic)
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

/// History keeps the series watched, the latest first, in history.json.
@MainActor @Observable
public final class History {
    /// How many series the history keeps.
    public static let max = 200

    public private(set) var list: [Watch]
    @ObservationIgnored let store: JSONStore<Watch>

    public init(dir: URL) {
        store = JSONStore(url: dir.appendingPathComponent("history.json"))
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

/// Favorites keeps the series saved, the latest first, in favorites.json.
@MainActor @Observable
public final class Favorites {
    public private(set) var list: [Fav]
    @ObservationIgnored private var ids: Set<String>
    @ObservationIgnored let store: JSONStore<Fav>

    public init(dir: URL) {
        let store = JSONStore<Fav>(url: dir.appendingPathComponent("favorites.json"))
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
