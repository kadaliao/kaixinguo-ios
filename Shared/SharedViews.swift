import KaixinguoKit
import Openhongguo
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

// MARK: - The player

/// Where the viewer's choice to show danmaku or not is kept.
let danmakuKey = "danmaku"

/// DanmakuLayer flies the episode's danmaku across the top of the video,
/// white with a dark edge, each where the time the video has got to puts
/// it: they stand still while it pauses and follow a seek. Picture in
/// picture shows the video alone.
struct DanmakuLayer: View {
    /// The size of their type, and the distance from one lane to the next.
    let size: CGFloat, pitch: CGFloat
    @Environment(AppModel.self) private var model
    @AppStorage(danmakuKey) private var on = true

    var body: some View {
        let player = model.player
        if on, player.state == .playing || player.state == .buffering,
           let flights = player.danmaku()?.flights, !flights.isEmpty {
            let av = player.av, size = size, pitch = pitch
            TimelineView(.animation(minimumInterval: player.paused ? 0.25 : 1.0 / 60)) { _ in
                let t = av.currentTime().seconds
                Canvas { ctx, canvas in
                    guard t.isFinite else { return }
                    let across = Double(canvas.width / size)
                    let edge = [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)]
                    let d = max(1, size / 16) // the dark edge, thicker on bigger type
                    for f in flights {
                        guard let x = f.x(at: t, across: across) else { continue }
                        var text = ctx.resolve(Text(verbatim: f.text).font(.system(size: size, weight: .semibold)))
                        let at = CGPoint(x: CGFloat(x) * size, y: (CGFloat(f.lane) + 0.5) * pitch)
                        guard at.x + text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width > 0 else {
                            continue
                        }
                        text.shading = .color(.black.opacity(0.75))
                        for e in edge {
                            ctx.draw(text, at: CGPoint(x: at.x + e.x * d, y: at.y + e.y * d), anchor: .leading)
                        }
                        text.shading = .color(.white)
                        ctx.draw(text, at: at, anchor: .leading)
                    }
                }
            }
            .frame(height: pitch * CGFloat(DanmakuFlight.lanes))
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A speed as the player writes it: 1.25, 2.
func rateText(_ r: Float) -> String {
    Double(r).formatted()
}

/// The speeds to choose from, as the menus show them: "1x 正常", "1.5x".
func speedLabel(_ s: Float) -> String {
    s == 1 ? "1x 正常" : "\(rateText(s))x"
}

/// When the sleep timer stops the video: "播完本集", "22:30 停止".
@MainActor func sleepLine(_ player: Player) -> String {
    switch player.sleep {
    case .off: "未开启"
    case .endOfEpisode: "播完本集"
    case .minutes:
        (player.sleepAt?.formatted(date: .omitted, time: .shortened) ?? "") + " 停止"
    }
}

/// The sleep timer's choices, as the menus show them.
let sleepChoices: [(Player.Sleep, String)] =
    [(.off, "不开启"), (.endOfEpisode, "播完本集")] + [15, 30, 60, 90].map { (.minutes($0), "\($0) 分钟") }

extension Card {
    /// A series on a hot-search board: its place, and how much it is
    /// searched for, or else how hot it is.
    init(hot it: HotItem) {
        self.init(id: it.seriesId, title: it.title, cover: it.coverUrl,
                  sub: it.searchScore.isEmpty ? it.heat : it.searchScore,
                  rank: it.position, episodes: it.episodeCount)
    }
}
