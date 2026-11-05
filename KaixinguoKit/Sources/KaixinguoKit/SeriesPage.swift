import Foundation
import Observation
import Openhongguo

/// SeriesPage is a series and its episodes, as its page shows them.
@MainActor @Observable
public final class SeriesPage: Identifiable {
    public static let episodesPerPart = 100

    public let id: String
    public internal(set) var series: Series?
    public internal(set) var episodes: [Episode] = []
    public internal(set) var loading = false
    public internal(set) var error: Error?
    /// Which hundred of episodes shows.
    public var part = 0
    /// The seasons of the series, the same list on each season's page;
    /// empty when there is one season, nil until known.
    public internal(set) var seasons: [Season]?
    @ObservationIgnored var seasonsLoading = false

    init(id: String) {
        self.id = id
    }

    public func episode(_ n: Int) -> Episode? {
        episodes.first { $0.number == n }
    }

    /// The season after this one, once it has episodes.
    public func nextSeason() -> Season? {
        guard let seasons, let i = seasons.firstIndex(where: { $0.seriesId == id }), i + 1 < seasons.count,
              seasons[i + 1].episodeCount > 0 else { return nil }
        return seasons[i + 1]
    }

    /// The labels of the hundreds of episodes, for a long series.
    public var parts: [String] {
        let n = episodes.count
        guard n > Self.episodesPerPart else { return [] }
        return stride(from: 0, to: n, by: Self.episodesPerPart).map { lo in
            "\(lo + 1)–\(min(n, lo + Self.episodesPerPart))"
        }
    }

    /// The episodes of the part showing.
    public var partEpisodes: ArraySlice<Episode> {
        let n = episodes.count
        let p = min(part, max(0, (n - 1) / Self.episodesPerPart))
        return episodes[(p * Self.episodesPerPart)..<min(n, (p + 1) * Self.episodesPerPart)]
    }

    /// Shows the part that holds episode n.
    public func reveal(_ n: Int) {
        if n > 0 {
            part = (n - 1) / Self.episodesPerPart
        }
    }

    /// Whether the series is a novel or audiobook, which can't play.
    public var isBook: Bool { series?.platform == .unknown }
}

extension AppModel {
    /// The series' page, loading it unless it is here or on its way.
    public func seriesPage(_ id: String) -> SeriesPage {
        let sp = seriesEntry(id)
        if sp.series == nil && !sp.loading && sp.error == nil {
            loadSeries(sp)
        }
        return sp
    }

    /// The series' page, without loading it.
    func seriesEntry(_ id: String) -> SeriesPage {
        if let sp = series[id] {
            return sp
        }
        let sp = SeriesPage(id: id)
        series[id] = sp
        return sp
    }

    public func loadSeries(_ sp: SeriesPage) {
        sp.loading = true
        sp.error = nil
        let catalog = catalog, id = sp.id
        Task {
            async let s = catalog.getSeries(id)
            async let e = catalog.listEpisodes(id, options: EpisodeOptions())
            let series: Result<Series, Error>, episodes: Result<[Episode], Error>
            do { series = .success(try await s) } catch { series = .failure(error) }
            do { episodes = .success(try await e.items) } catch { episodes = .failure(error) }
            sp.loading = false
            switch (series, episodes) {
            case (.failure(let err), _):
                sp.error = err
            case (.success, .failure(let err)) where !isCode(err, .anonymousLimited):
                sp.error = err
            case (.success(let s), let eps):
                sp.series = s
                sp.episodes = (try? eps.get()) ?? []
                if s.isMultiSeason && sp.seasons == nil {
                    loadSeasons(sp)
                }
            }
            player.fillPending(sp) // starts the episode, or says why it can't
        }
    }

    /// Lists the seasons of a series in several, and gives the list to the
    /// page of each.
    func loadSeasons(_ sp: SeriesPage) {
        guard !sp.seasonsLoading else { return }
        sp.seasonsLoading = true
        let catalog = catalog, id = sp.id
        Task {
            let album = try? await catalog.seasons(id)
            sp.seasonsLoading = false
            guard let album, album.seasons.count >= 2 else {
                sp.seasons = [] // one season: nothing to choose
                return
            }
            let seasons = numberSeasons(album.seasons)
            for se in seasons {
                seriesEntry(se.seriesId).seasons = seasons
            }
            sp.seasons = seasons
        }
    }

    /// The episode after episode n: the next of the season, else the first
    /// of the next season.
    public func following(_ sp: SeriesPage, _ n: Int) -> (seriesID: String, number: Int)? {
        if let next = sp.episode(n + 1) {
            return next.playable ? (sp.id, next.number) : nil
        }
        if let ns = sp.nextSeason() {
            return (ns.seriesId, 1)
        }
        return nil
    }

    /// Where to go on from: the series (this season or the next), the
    /// episode and the second, and what the button says.
    public func resumePoint(_ sp: SeriesPage) -> (seriesID: String, number: Int, start: Double, label: String) {
        guard let w = history.get(sp.id), !sp.episodes.isEmpty else {
            return (sp.id, 1, 0, "播放第 1 集")
        }
        if w.finished {
            if sp.episode(w.episode + 1) != nil {
                return (sp.id, w.episode + 1, 0, "播放第 \(w.episode + 1) 集")
            }
            if let ns = sp.nextSeason() {
                return (ns.seriesId, 1, 0, "播放" + seasonLabel(ns))
            }
            return (sp.id, 1, 0, "从头再看")
        }
        return (sp.id, w.episode, max(0, w.position - 3), "继续看第 \(w.episode) 集")
    }

    /// Plays a season from where the viewer left it, else from its first
    /// episode.
    public func playSeason(_ id: String) {
        if let sp = series[id], sp.series != nil {
            let r = resumePoint(sp)
            player.play(r.seriesID, r.number, start: r.start)
            return
        }
        if let w = history.get(id), !w.finished {
            player.play(id, w.episode, start: max(0, w.position - 3))
            return
        }
        player.play(id, 1)
    }

    /// Plays the series from where the viewer left it, as its button does.
    public func resume(_ sp: SeriesPage) {
        let r = resumePoint(sp)
        player.play(r.seriesID, r.number, start: r.start)
    }
}
