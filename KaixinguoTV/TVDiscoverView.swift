import KaixinguoKit
import SwiftUI

/// TVDiscoverView is the recommended series, a wall of posters that loads
/// more as focus nears its end.
struct TVDiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let feed = model.home
        ScrollView {
            if feed.cards.isEmpty {
                FeedState(feed: feed, empty: "暂时没有推荐")
                    .frame(maxWidth: .infinity, minHeight: 600)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6),
                          spacing: 56) {
                    ForEach(Array(feed.cards.enumerated()), id: \.element.id) { i, card in
                        TVCard(card: card)
                            .onAppear {
                                if i >= feed.cards.count - 12 && feed.wantsMore {
                                    feed.loadMore()
                                }
                            }
                    }
                }
                if feed.loading && feed.started {
                    ProgressView().padding(.vertical, 40)
                }
            }
        }
        .navigationTitle("推荐")
        .task {
            if !feed.started {
                feed.loadMore()
            }
        }
    }
}

/// TVCard is a series on the wall: its poster, which lifts under focus and
/// opens the series, and its title under it. Holding select saves it.
struct TVCard: View {
    let card: Card
    @Environment(AppModel.self) private var model

    var body: some View {
        let saved = model.favorites.has(card.id)
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: SeriesRoute(id: card.id)) {
                Poster(url: card.cover, radius: 0)
            }
            .buttonStyle(.card)
            .contextMenu {
                Button(favLabel(saved), systemImage: saved ? "star.slash" : "star") {
                    model.favorites.toggle(Fav(card))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(card.sub.isEmpty ? " " : card.sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
