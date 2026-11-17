import KaixinguoKit
import Openhongguo
import SwiftUI

// The tabs' pages, as on iPhone and iPad, laid out for the remote: walls
// and shelves of posters that lift under focus, and rows of buttons to
// choose a chart or a day.

/// TVDiscoverView is the recommended series.
struct TVDiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TVFeedGrid(feed: model.home, empty: "暂时没有推荐")
    }
}

/// TVRankView is the charts: a kind of series, and its boards.
struct TVRankView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TVFeedGrid(feed: model.rankFeed, empty: "这个榜单暂时是空的") {
            let contents = model.chartContents
            if contents.count > 1 {
                let current = model.currentRankContent
                TVChipRow(selected: current) {
                    ForEach(contents, id: \.id) { c in
                        TVChip(label: c.name, on: c.id == current) {
                            model.rankContent = c.id
                            model.rankBoard = ""
                        }
                        .id(c.id)
                    }
                }
            }
            let boards = model.rankBoards
            if !boards.isEmpty {
                TVChipRow(selected: boards.first(where: model.boardIsOn)?.id) {
                    ForEach(boards, id: \.id) { b in
                        TVChip(label: b.name, on: model.boardIsOn(b)) { model.rankBoard = b.id }
                            .id(b.id)
                    }
                }
            }
        }
    }
}

/// TVNewView is the calendar of new series, two weeks either side.
struct TVNewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TVFeedGrid(feed: model.newFeed, empty: "这一天没有新剧") {
            let today = todayKey()
            if !model.newDates.isEmpty {
                TVChipRow(selected: model.newDates.first(where: model.dayIsOn)) {
                    ForEach(model.newDates, id: \.self) { d in
                        TVChip(label: dayLabel(d, today: today), on: model.dayIsOn(d)) { model.chooseDay(d) }
                            .id(d)
                    }
                }
            }
        }
    }
}

/// TVSearchView searches the series as the viewer types, with words to
/// complete it to beside the keyboard; before a search, it shows what
/// people search for.
struct TVSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var suggestions: [String] = []

    var body: some View {
        @Bindable var router = router
        let query = router.searchQuery
        Group {
            if query.isEmpty {
                TVHotView()
            } else {
                TVFeedGrid(feed: model.searchFeed(query), empty: "没有找到“\(query)”相关的短剧，换个词试试")
            }
        }
        .searchable(text: $router.searchText, prompt: "搜索短剧")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { s in
                Text(s).searchCompletion(s)
            }
        }
        // Typing on the remote is slow, and there is no key to submit: the
        // results follow the words once they rest for a moment.
        .task(id: router.searchText) {
            let text = router.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                router.searchQuery = ""
                suggestions = []
                return
            }
            guard text != router.searchQuery else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            router.search(text)
            let s = await model.suggestions(text)
            if !Task.isCancelled {
                suggestions = s.filter { $0 != text }
            }
        }
    }
}

/// TVHotView is the hot-search boards, a shelf each.
struct TVHotView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let hot = model.hot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(hot.boards.filter { !$0.items.isEmpty }, id: \.name) { b in
                            TVShelf(title: b.name) {
                                ForEach(b.items.map(Card.init(hot:)), id: \.id) { card in
                                    TVCard(card: card).frame(width: TVCard.shelfWidth)
                                }
                            }
                        }
                    }
                }
            } else if let error = model.hotError {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(friendly(error))
                } actions: {
                    Button("重试") { model.loadHot(force: true) }
                }
            } else {
                ProgressView()
            }
        }
        .task { model.loadHot() }
    }
}

/// TVMineView is what the viewer watched, on a shelf, and saved, below it.
struct TVMineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let watched = Array(model.history.list.prefix(30))
        let saved = model.favorites.cards
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !watched.isEmpty {
                    TVShelf(title: "最近观看") {
                        ForEach(watched) { w in
                            TVWatchCard(watch: w).frame(width: TVCard.shelfWidth)
                        }
                    }
                }
                Text("收藏").font(.title3.bold())
                if saved.isEmpty {
                    ContentUnavailableView("还没有收藏", systemImage: "star",
                                           description: Text("在剧集页选「收藏」，或者在海报上按住确认键，想看的就存下来。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    TVCardGrid(cards: saved)
                }
            }
        }
    }
}

// MARK: - Walls and shelves

/// TVFeedGrid is a feed's posters, what goes above them first, loading the
/// next page as focus nears the end.
struct TVFeedGrid<Header: View>: View {
    let feed: Feed
    let empty: String
    @ViewBuilder var header: () -> Header

    init(feed: Feed, empty: String, @ViewBuilder header: @escaping () -> Header = { EmptyView() }) {
        self.feed = feed
        self.empty = empty
        self.header = header
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header()
                if feed.cards.isEmpty {
                    FeedState(feed: feed, empty: empty)
                        .frame(maxWidth: .infinity, minHeight: 600)
                } else {
                    TVCardGrid(cards: feed.cards) { i in
                        if i >= feed.cards.count - 12 && feed.wantsMore {
                            feed.loadMore()
                        }
                    }
                    if feed.loading && feed.started {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
            }
        }
        .task(id: ObjectIdentifier(feed)) {
            if !feed.started {
                feed.loadMore()
            }
        }
    }
}

/// TVCardGrid lays posters out six to a row.
struct TVCardGrid: View {
    let cards: [Card]
    var onAppear: (Int) -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6),
                  spacing: 56) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                TVCard(card: card)
                    .onAppear { onAppear(i) }
            }
        }
        .focusSection()
    }
}

/// TVShelf is a row of posters under a title, that scrolls sideways.
struct TVShelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) { content() }
                    .padding(.vertical, 36) // room for a poster to lift
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// TVCard is a series on a wall or a shelf: its poster, which lifts under
/// focus and opens the series, and its title under it. Holding select
/// saves it.
struct TVCard: View {
    /// How wide a poster is on a shelf: as on a wall of six.
    static let shelfWidth: CGFloat = 250

    let card: Card
    @Environment(AppModel.self) private var model

    var body: some View {
        let saved = model.favorites.has(card.id)
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: Route.series(card.id)) {
                Poster(url: card.cover, radius: 0)
                    .overlay(alignment: .topLeading) {
                        if card.rank > 0 {
                            RankBadge(rank: card.rank).padding(12)
                        }
                    }
            }
            .buttonStyle(.card)
            .contextMenu {
                Button(favLabel(saved), systemImage: saved ? "star.slash" : "star") {
                    model.favorites.toggle(Fav(card))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(card.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if saved {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("已收藏")
                    }
                }
                Text(card.sub.isEmpty ? " " : card.sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// TVWatchCard is a series in the history, how far the viewer got, and a
/// way to go on.
struct TVWatchCard: View {
    let watch: Watch
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: Route.series(watch.seriesID)) {
                Poster(url: watch.cover, radius: 0)
                    .overlay(alignment: .bottom) {
                        if !watch.finished && watch.duration > 0 {
                            GeometryReader { g in
                                Capsule().fill(.tint)
                                    .frame(width: max(8, g.size.width * min(1, watch.position / watch.duration)))
                            }
                            .frame(height: 6)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                        }
                    }
            }
            .buttonStyle(.card)
            .contextMenu {
                Button("继续播放", systemImage: "play.fill") { model.playSeason(watch.seriesID) }
                Button("从最近观看中移除", systemImage: "minus.circle", role: .destructive) {
                    withAnimation { model.history.remove(watch.seriesID) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(watch.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(watch.finished ? "看完第 \(watch.episode) 集" : "看到第 \(watch.episode) 集")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Choosing

/// TVChip is a button that chooses one of a few, as a chart or a day,
/// filled green while it is the one chosen.
struct TVChip: View {
    let label: String
    let on: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            if !on { action() }
        } label: {
            Text(label).lineLimit(1)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
        }
        .buttonStyle(TVChoiceStyle(on: on, shape: Capsule()))
        .disabled(!enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// TVChoiceStyle is a button that is one of several, the one chosen filled
/// green: the system's bordered buttons show their tint only under focus,
/// so the choice would show only while focus is on it. Under focus it
/// turns white and lifts, as theirs do.
struct TVChoiceStyle<S: Shape>: ButtonStyle {
    let on: Bool
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        Choice(configuration: configuration, on: on, shape: shape)
    }

    private struct Choice: View {
        let configuration: Configuration
        let on: Bool
        let shape: S
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(focused ? AnyShapeStyle(.black) : on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(focused ? AnyShapeStyle(.white) : on ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.1)),
                            in: shape)
                .scaleEffect(configuration.isPressed ? 1 : focused ? 1.1 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 14, y: 10)
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: focused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// TVChipRow is a row of chips that scrolls sideways, the chosen one
/// brought into view.
struct TVChipRow<ID: Hashable, Content: View>: View {
    let selected: ID?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 24) { content() }
                    .padding(.vertical, 12) // room for a button to lift
            }
            .scrollClipDisabled()
            .onAppear {
                if let selected {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
        .focusSection()
    }
}
