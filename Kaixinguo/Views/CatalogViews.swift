import KaixinguoKit
import Openhongguo
import SwiftUI

/// DiscoverView is the recommended series.
struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FeedGrid(feed: model.home, empty: "暂时没有推荐")
            .refreshable { await model.home.refresh(merging: true) }
            .navigationTitle("推荐")
    }
}

/// RankView is the charts: a kind of series, and its boards.
struct RankView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let feed = model.rankFeed
        FeedGrid(feed: feed, empty: "这个榜单暂时是空的") {
            controls
        }
        .refreshable { await feed.refresh(merging: false) }
        .navigationTitle("排行榜")
    }

    @ViewBuilder private var controls: some View {
        let contents = model.chartContents
        if !contents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if contents.count > 1 {
                    Picker("类型", selection: Binding(get: { model.currentRankContent }, set: { id in
                        model.rankContent = id
                        model.rankBoard = ""
                    })) {
                        ForEach(contents, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                }
                let boards = model.rankBoards
                ChipRow(selected: boards.first(where: model.boardIsOn)?.id) {
                    ForEach(boards, id: \.id) { b in
                        Chip(label: b.name, on: model.boardIsOn(b)) { model.rankBoard = b.id }
                            .id(b.id)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }
}

/// NewReleasesView is the calendar of new series, two weeks either side.
struct NewReleasesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let feed = model.newFeed
        FeedGrid(feed: feed, empty: "这一天没有新剧") {
            let today = todayKey()
            if !model.newDates.isEmpty {
                ChipRow(selected: model.newDates.first(where: model.dayIsOn)) {
                    ForEach(model.newDates, id: \.self) { d in
                        Chip(label: dayLabel(d, today: today), on: model.dayIsOn(d)) { model.chooseDay(d) }
                            .id(d)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .refreshable { await feed.refresh(merging: false) }
        .navigationTitle("新剧上线")
    }
}

/// SearchView searches the series; before a search, it shows what people
/// search for.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var suggestions: [String] = []

    var body: some View {
        @Bindable var router = router
        let query = router.searchQuery
        Group {
            if query.isEmpty {
                HotView { router.search($0) }
            } else {
                FeedGrid(feed: model.searchFeed(query), empty: "没有找到“\(query)”相关的短剧，换个词试试")
            }
        }
        .navigationTitle(query.isEmpty ? "热搜" : "“\(query)”")
        .searchable(text: $router.searchText, prompt: "搜索短剧")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { s in
                Button { submit(s) } label: {
                    Label(s, systemImage: "magnifyingglass")
                }
            }
        }
        .onSubmit(of: .search) { submit(router.searchText) }
        .onChange(of: router.searchText) {
            if router.searchText.isEmpty {
                router.searchQuery = ""
            }
        }
        .task(id: router.searchText) {
            let text = router.searchText
            guard text != router.searchQuery else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            suggestions = await model.suggestions(text)
        }
    }

    private func submit(_ s: String) {
        router.search(s)
        suggestions = []
    }
}

/// HotView is the hot-search boards.
struct HotView: View {
    var search: (String) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let hot = model.hot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        ForEach(hot.boards.filter { !$0.items.isEmpty }, id: \.name) { b in
                            Text(b.name)
                                .font(.title3.bold())
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                            CardGrid(cards: b.items.map { it in
                                Card(id: it.seriesId, title: it.title, cover: it.coverUrl,
                                     sub: it.searchScore.isEmpty ? it.heat : it.searchScore,
                                     rank: it.position, episodes: it.episodeCount)
                            })
                        }
                    }
                }
                .refreshable { await model.reloadHot() }
            } else if let error = model.hotError {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(friendly(error))
                } actions: {
                    Button("重试") { model.loadHot(force: true) }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
            }
        }
        .task { model.loadHot() }
    }
}

/// MineView is what the viewer watched and saved.
struct MineView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let watched = Array(model.history.list.prefix(30))
        let saved = model.favorites.cards
        ScrollView {
            if !watched.isEmpty {
                section("最近观看")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(watched) { w in
                            WatchCard(watch: w)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }
            section("收藏")
            if saved.isEmpty {
                ContentUnavailableView("还没有收藏", systemImage: "star",
                                       description: Text("在剧集页点「收藏」，或者长按海报，想看的就存下来。"))
                    .padding(.top, 40)
            } else {
                CardGrid(cards: saved)
            }
        }
        .navigationTitle("我的")
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// WatchCard is a series in the history, how far the viewer got, and a
/// way to go on.
struct WatchCard: View {
    let watch: Watch
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink(value: Route.series(watch.seriesID)) {
            VStack(alignment: .leading, spacing: 6) {
                Poster(url: watch.cover, radius: 9)
                    .overlay(alignment: .bottom) {
                        if !watch.finished && watch.duration > 0 {
                            GeometryReader { g in
                                Capsule().fill(.tint)
                                    .frame(width: max(4, g.size.width * min(1, watch.position / watch.duration)))
                            }
                            .frame(height: 3)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 7)
                        }
                    }
                Text(watch.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(watch.finished ? "看完第 \(watch.episode) 集" : "看到第 \(watch.episode) 集")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 96)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("继续播放", systemImage: "play.fill") { model.playSeason(watch.seriesID) }
            Button("从最近观看中移除", systemImage: "minus.circle", role: .destructive) {
                withAnimation { model.history.remove(watch.seriesID) }
            }
        }
    }
}
