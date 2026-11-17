import KaixinguoKit
import SwiftUI

// Views the iPhone and iPad app and the Apple TV app both show.

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
