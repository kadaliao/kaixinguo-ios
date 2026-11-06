import KaixinguoKit
import SwiftUI

/// FeedGrid is a feed's posters, loading the next page as the viewer nears
/// the end, with what goes above them.
struct FeedGrid<Header: View>: View {
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
            header()
            if feed.cards.isEmpty {
                FeedState(feed: feed, empty: empty)
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                CardGrid(cards: feed.cards) { i in
                    if i >= feed.cards.count - 9 && feed.wantsMore {
                        feed.loadMore()
                    }
                }
                if feed.loading && feed.started {
                    ProgressView().padding(.vertical, 24)
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

/// CardGrid lays posters out in as many columns as fit.
struct CardGrid: View {
    let cards: [Card]
    var onAppear: (Int) -> Void = { _ in }
    @Environment(\.horizontalSizeClass) private var hsize

    var body: some View {
        let minWidth: CGFloat = hsize == .regular ? 150 : 104
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 12, alignment: .top)], spacing: 18) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                CardView(card: card)
                    .onAppear { onAppear(i) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

/// FeedState is what a feed with no series yet shows.
struct FeedState: View {
    let feed: Feed
    let empty: String

    var body: some View {
        if feed.retrying {
            VStack(spacing: 10) {
                ProgressView()
                Text("网络不稳定，正在重试…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if let error = feed.error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(friendly(error))
            } actions: {
                Button("重试") { feed.retry() }
                    .buttonStyle(.bordered)
            }
        } else if feed.loading || !feed.started {
            ProgressView()
        } else {
            ContentUnavailableView(empty, systemImage: "film.stack")
        }
    }
}

/// CardView is a series in a grid: its poster, title and a line about it.
/// It opens the series, unless `playCard` in the environment says to play
/// it instead. A long press saves it.
struct CardView: View {
    let card: Card
    @Environment(AppModel.self) private var model
    @Environment(\.playCard) private var playCard

    var body: some View {
        let saved = model.favorites.has(card.id)
        Group {
            if let playCard {
                Button { playCard.play(card) } label: { label(saved) }
            } else {
                NavigationLink(value: Route.series(card.id)) { label(saved) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(favLabel(saved), systemImage: saved ? "star.slash" : "star") {
                model.favorites.toggle(Fav(card))
            }
        } preview: {
            Poster(url: card.cover).frame(width: 240)
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Poster(url: card.cover)
                .overlay(alignment: .topLeading) {
                    if card.rank > 0 {
                        RankBadge(rank: card.rank).padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if saved {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("已收藏")
                    }
                }
                Text(card.sub.isEmpty ? " " : card.sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// PlayCard is what tapping a card does in place of opening its series: in
/// the player's search, play it.
struct PlayCard {
    let play: (Card) -> Void
}

extension EnvironmentValues {
    @Entry var playCard: PlayCard?
}

/// RankBadge is a series' place on a chart, the first three in medal
/// colors.
struct RankBadge: View {
    let rank: Int

    var body: some View {
        let colors: [Color] = [Color(red: 0.95, green: 0.68, blue: 0.13), Color(white: 0.62), Color(red: 0.76, green: 0.47, blue: 0.27)]
        Text("\(rank)")
            .font(.caption.weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(rank <= 3 ? colors[rank - 1] : .black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Poster is a cover in a rounded 3:4 frame, gray until it loads.
struct Poster: View {
    let url: String
    var radius: CGFloat = 10

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { CoverImage(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

/// CoverImage is a cover filling its frame, fading in as it arrives.
struct CoverImage: View {
    let url: String
    @Environment(AppModel.self) private var model
    @State private var loaded: (url: String, image: CGImage)?

    var body: some View {
        // Memory has most covers already: those show at once.
        let image = loaded?.url == url ? loaded?.image : model.covers.cached(url)
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                guard !url.isEmpty, loaded?.url != url else { return }
                if let hit = model.covers.cached(url) {
                    loaded = (url, hit) // another view may have fetched it since
                    return
                }
                guard let img = await model.covers.image(url), !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    loaded = (url, img)
                }
            }
    }
}

/// Chip is a capsule that chooses one of a few, as a chart or a day.
struct Chip: View {
    let label: String
    let on: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            if !on { action() }
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .foregroundStyle(on ? AnyShapeStyle(Color(uiColor: .systemBackground)) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.07)), in: Capsule())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// ChipRow is a row of chips that scrolls sideways, bringing the chosen
/// one into view.
struct ChipRow<ID: Hashable, Content: View>: View {
    let selected: ID?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            .onAppear {
                if let selected {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
    }
}
