import Foundation
import Observation

/// Feed is a list of series loaded a page at a time. It belongs to the
/// main actor.
@MainActor @Observable
public final class Feed {
    public typealias Fetcher = @Sendable (_ cursor: String) async throws -> FeedPage

    @ObservationIgnored let fetch: Fetcher?
    public private(set) var cards: [Card] = []
    @ObservationIgnored var seen = Set<String>()
    @ObservationIgnored var cursor = ""
    public private(set) var more = true
    public internal(set) var started = false
    public private(set) var loading = false
    /// The cards came from the disk cache: the first page replaces them.
    public internal(set) var stale = false
    public private(set) var error: Error?
    @ObservationIgnored var errorAt = Date.distantPast
    /// Retries made by themselves since the last success.
    @ObservationIgnored var tries = 0
    /// Whether a retry is on its way by itself.
    public private(set) var retrying = false

    @ObservationIgnored var onPage: ((FeedPage) -> Void)?
    /// Sorts the cards after each page, when set.
    @ObservationIgnored var order: (([Card]) -> [Card])?

    public init(fetch: Fetcher?) {
        self.fetch = fetch
    }

    /// A feed of these cards alone, with nothing to fetch.
    public convenience init(cards: [Card]) {
        self.init(fetch: nil)
        add(FeedPage(cards: cards))
        started = true
        more = false
    }

    func add(_ p: FeedPage) {
        var incoming = p.cards
        if stale {
            // Fresh series first, then those of the cache, so the grid
            // never shrinks under the viewer.
            incoming += cards
            cards = []
            seen = []
            stale = false
        }
        var list = cards
        var added = 0
        for k in incoming where !k.id.isEmpty && seen.insert(k.id).inserted {
            list.append(k)
            added += 1
        }
        cursor = p.cursor
        more = p.more
        // Search pages repeat what came before: a page with nothing new
        // ends the feed, or the grid would ask for more forever.
        if added == 0 && !p.cards.isEmpty {
            more = false
        }
        if let order {
            list = order(list)
        }
        cards = list
    }

    /// Whether the grid should ask for the next page.
    public var wantsMore: Bool { fetch != nil && (stale || more || !started) }

    /// Fetches the next page, unless one is on its way, the feed has no
    /// more, or the last try failed a moment ago.
    public func loadMore() {
        guard let fetch, !loading, !(started && !stale && !more) else { return }
        if error != nil && Date().timeIntervalSince(errorAt) < 5 {
            return
        }
        loading = true
        started = true
        let cursor = stale ? "" : self.cursor
        Task {
            do {
                let p = try await fetch(cursor)
                loading = false
                error = nil
                tries = 0
                add(p)
                onPage?(p)
            } catch {
                loading = false
                self.error = error
                errorAt = Date()
                debugLog("feed: \(error)")
                scheduleRetry()
            }
        }
    }

    /// Tries again by itself after 2, 4, 8 and 16 seconds, while the feed
    /// has nothing to show; then it waits for the viewer.
    private func scheduleRetry() {
        guard cards.isEmpty, tries < 4 else {
            retrying = false
            return
        }
        let wait = Double(2 << tries)
        tries += 1
        retrying = true
        Task {
            try? await Task.sleep(for: .seconds(wait))
            retrying = false
            error = nil
            loadMore()
        }
    }

    /// Fetches again after an error, now.
    public func retry() {
        tries = 0
        error = nil
        loadMore()
    }

    /// Fetches the first page again, as the viewer pulls the grid down.
    /// Merging keeps the cards there are after the fresh ones; else the
    /// fresh page replaces them.
    public func refresh(merging: Bool) async {
        guard let fetch, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let p = try await fetch("")
            let had = !cards.isEmpty, oldCursor = cursor, oldMore = more
            if merging {
                stale = true
            } else {
                cards = []
                seen = []
            }
            error = nil
            tries = 0
            add(p)
            if merging && had {
                // The grid goes on from where it had got to, not from the
                // fresh page's second.
                cursor = oldCursor
                more = oldMore
            }
            onPage?(p)
        } catch {
            if !(error is CancellationError) {
                self.error = error
                errorAt = Date()
            }
        }
    }
}

func debugLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["KX_DEBUG"] != nil {
        print("kxg:", message())
    }
}
