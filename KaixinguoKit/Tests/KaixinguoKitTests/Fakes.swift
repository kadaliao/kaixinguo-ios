import Foundation
import Openhongguo
import Synchronization

@testable import KaixinguoKit

/// FakeCatalog answers from what a test gives it, without the network.
final class FakeCatalog: Catalog {
    struct State {
        var discoverPages: [String: Page<SeriesSummary>] = [:] // by cursor
        var series: [String: Series] = [:]
        var episodes: [String: [Episode]] = [:]
        var albums: [String: Album] = [:]
        var search: @Sendable (String, SearchOptions) throws -> Page<SeriesSummary> = { _, _ in Page() }
        var batch: [String: Series] = [:]
        var suggestions: [Suggestion] = []
        var calls: [String] = []
    }

    let state = Mutex(State())

    func update(_ f: (inout State) -> Void) { state.withLock { f(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }

    private func note(_ call: String) { state.withLock { $0.calls.append(call) } }

    func discover(_ options: DiscoverOptions) async throws -> Page<SeriesSummary> {
        note("discover:\(options.cursor ?? "")")
        return state.withLock { $0.discoverPages[options.cursor ?? ""] } ?? Page()
    }

    func search(_ query: String, options: SearchOptions) async throws -> Page<SeriesSummary> {
        note("search:\(query):\(options.tab ?? "")")
        let f = state.withLock { $0.search }
        return try f(query, options)
    }

    func suggest(_ prefix: String) async throws -> [Suggestion] { state.withLock { $0.suggestions } }
    func hotSearch() async throws -> HotSearch { HotSearch() }
    func newReleases(_ query: NewReleaseQuery) async throws -> NewReleasePage { NewReleasePage() }

    func getSeries(_ seriesId: String) async throws -> Series {
        note("getSeries:\(seriesId)")
        guard let s = state.withLock({ $0.series[seriesId] }) else {
            throw OpenhongguoError(code: .contentUnavailable, message: "gone")
        }
        return s
    }

    func getSeriesBatch(_ seriesIds: [String]) async throws -> [SeriesDetail] {
        let byID = state.withLock { $0.batch }
        return seriesIds.compactMap { byID[$0].map { SeriesDetail(series: $0) } }
    }

    func listEpisodes(_ seriesId: String, options: EpisodeOptions) async throws -> Page<Episode> {
        Page(items: state.withLock { $0.episodes[seriesId] } ?? [])
    }

    func seasons(_ seriesId: String) async throws -> Album {
        guard let a = state.withLock({ $0.albums[seriesId] }) else {
            throw OpenhongguoError(code: .albumUnavailable, message: "none")
        }
        return a
    }

    func shortRank(_ query: ShortRankQuery) async throws -> ShortRanking { ShortRanking() }

    func resolvePlayback(_ episodeId: String) async throws -> PlaybackResult {
        note("resolve:\(episodeId)")
        throw OpenhongguoError(code: .anonymousLimited, message: "limited")
    }
}

/// A model on a fake catalog, its files in a fresh directory.
@MainActor
func testModel(_ catalog: FakeCatalog = FakeCatalog()) -> (AppModel, FakeCatalog) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kxg-\(UUID().uuidString)")
    let model = AppModel(catalog: catalog, dataDir: dir.appendingPathComponent("data"),
                         cacheDir: dir.appendingPathComponent("cache"))
    return (model, catalog)
}

/// Waits until `done`, or a second has gone.
@MainActor
func until(_ done: () -> Bool) async {
    for _ in 0..<200 where !done() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func episodes(_ seriesID: String, _ n: Int, locked: Set<Int> = []) -> [Episode] {
    (1...n).map { Episode(id: "\(seriesID)e\($0)", seriesId: seriesID, number: $0, playable: !locked.contains($0)) }
}
