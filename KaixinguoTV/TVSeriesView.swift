import KaixinguoKit
import Openhongguo
import SwiftUI

/// TVSeriesView is a series: its poster and what it is about, a button to
/// play it, its seasons and its episodes.
struct TVSeriesView: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let sp = model.seriesPage(id)
        Group {
            if let series = sp.series {
                TVSeriesBody(sp: sp, series: series)
            } else if let error = sp.error {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(friendly(error))
                } actions: {
                    Button("重试") { model.loadSeries(sp) }
                }
            } else {
                ProgressView()
            }
        }
    }
}

private struct TVSeriesBody: View {
    @Bindable var sp: SeriesPage
    let series: Series
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 60) {
                HStack(alignment: .top, spacing: 64) {
                    Poster(url: series.coverUrl, radius: 16)
                        .frame(width: 380)
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(series.title)
                            .font(.title2.bold())
                            .lineLimit(2)
                        Text(metaLine(series))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if !series.description.isEmpty {
                            Text(series.description)
                                .font(.body)
                                .foregroundStyle(.primary.opacity(0.86))
                                .lineLimit(6)
                        }
                        actions.padding(.top, 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                episodes
            }
            .padding(.bottom, 60)
        }
        .background {
            CoverImage(url: series.coverUrl)
                .blur(radius: 80)
                .opacity(0.45)
                .ignoresSafeArea()
        }
    }

    private var actions: some View {
        let saved = model.favorites.has(sp.id)
        return HStack(spacing: 32) {
            if !sp.episodes.isEmpty && !sp.isBook {
                let r = model.resumePoint(sp)
                Button {
                    model.player.play(r.seriesID, r.number, start: r.start)
                } label: {
                    Label(r.label, systemImage: "play.fill")
                }
            }
            Button {
                _ = model.favorites.toggle(Fav(Card(series)))
            } label: {
                Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
            }
        }
    }

    @ViewBuilder private var episodes: some View {
        let w = model.history.get(sp.id)
        let watched = Set(w?.watched ?? [])
        VStack(alignment: .leading, spacing: 28) {
            // Another season shows in place of this one: Menu still leaves
            // the series.
            TVSeasonRow(sp: sp) { se in router.replaceTop(.series(se.seriesId)) }
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text("选集").font(.title3.bold())
                Text("共 \(sp.episodes.count) 集").font(.callout).foregroundStyle(.secondary)
            }
            if sp.parts.count > 1 {
                Picker("集数", selection: $sp.part) {
                    ForEach(sp.parts.indices, id: \.self) { Text(sp.parts[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if sp.isBook {
                Text("这是小说或有声书，不能播放").foregroundStyle(.secondary)
            } else if sp.episodes.isEmpty {
                Text("暂时没有可看的剧集").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 10), spacing: 24) {
                    ForEach(sp.partEpisodes, id: \.id) { e in
                        TVEpisodeButton(episode: e, current: e.number == w?.episode, watched: watched.contains(e.number)) {
                            model.player.play(sp.id, e.number)
                        }
                    }
                }
            }
        }
    }
}

/// TVSeasonRow is the seasons of a series in several, this one chosen;
/// seasons still to come show, but can't be chosen yet.
struct TVSeasonRow: View {
    let sp: SeriesPage
    let choose: (Season) -> Void

    var body: some View {
        if let seasons = sp.seasons, seasons.count > 1 {
            TVChipRow(selected: sp.id) {
                ForEach(seasons, id: \.seriesId) { se in
                    TVChip(label: seasonLabel(se), on: se.seriesId == sp.id, enabled: se.episodeCount > 0) { choose(se) }
                        .id(se.seriesId)
                }
            }
        }
    }
}

/// TVEpisodeButton is an episode's number to choose: filled green while it
/// is the one the viewer is on, faded and checked once watched, a lock for
/// one that needs a login.
struct TVEpisodeButton: View {
    let episode: Episode
    let current: Bool
    let watched: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if episode.playable {
                    Text("\(episode.number)").monospacedDigit()
                } else {
                    Image(systemName: "lock.fill")
                }
            }
            .opacity(watched && !current ? 0.55 : 1)
            .frame(maxWidth: .infinity, minHeight: 72)
            .overlay(alignment: .topTrailing) {
                if watched {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                        .padding(10)
                }
            }
        }
        .buttonStyle(TVChoiceStyle(on: current, shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .disabled(!episode.playable)
        .accessibilityLabel("第 \(episode.number) 集")
        .accessibilityValue(watched ? "已看过" : "")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
