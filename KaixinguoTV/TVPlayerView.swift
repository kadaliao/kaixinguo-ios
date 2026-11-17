import AVKit
import KaixinguoKit
import SwiftUI

/// TVPlayerView is the episode playing, in the system's player with its
/// own controls: the remote scrubs and pauses, and Menu leaves. Over the
/// video fly the danmaku. The bar at the bottom, shown with a click or a
/// swipe, holds the speed, the definition, the sleep timer and the
/// danmaku's switch; swiping down shows the episode's info, and beside it
/// the episodes.
struct TVPlayerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(danmakuKey) private var danmaku = true

    var body: some View {
        let player = model.player
        ZStack {
            Color.black.ignoresSafeArea()
            if case .failed(let why) = player.state {
                ContentUnavailableView {
                    Label("播放失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(why)
                } actions: {
                    HStack(spacing: 32) {
                        Button("重试") { player.retry() }
                        if player.hasNext {
                            Button("下一集") { player.step(1) }
                        }
                    }
                }
            } else {
                SystemPlayer(model: model, controls: .init(
                    hasNext: player.hasNext, speed: player.speed, qualities: player.qualities,
                    quality: player.quality, sleep: player.sleep, danmaku: danmaku))
                    .ignoresSafeArea()
                if player.state == .resolving {
                    ProgressView()
                }
            }
        }
    }
}

/// SystemPlayer is the system's player view controller, playing the
/// player's AVPlayer, with what the app adds to it.
private struct SystemPlayer: UIViewControllerRepresentable {
    let model: AppModel
    let controls: Controls

    /// What the controls added to the system's show: they are made again
    /// only when it changes, so a menu open on screen stays put.
    struct Controls: Equatable {
        var hasNext: Bool
        var speed: Float
        var qualities: [Int]
        var quality: Int
        var sleep: Player.Sleep
        var danmaku: Bool
    }

    final class Coordinator {
        var shown: Controls?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player.av
        vc.allowsPictureInPicturePlayback = false
        // The speed menu is the app's own, which sets the speed the next
        // episodes play at too.
        vc.speeds = []

        // The danmaku, between the video and the controls.
        let danmaku = UIHostingController(rootView: AnyView(
            DanmakuLayer(size: 40, pitch: 64)
                .padding(.top, 50)
                .environment(model)))
        danmaku.view.backgroundColor = .clear
        danmaku.view.isUserInteractionEnabled = false
        danmaku.safeAreaRegions = []
        if let overlay = vc.contentOverlayView {
            vc.addChild(danmaku)
            danmaku.view.frame = overlay.bounds
            danmaku.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(danmaku.view)
            danmaku.didMove(toParent: vc)
        }

        // The episodes, in a tab of the info panel beside the episode's info.
        let episodes = UIHostingController(rootView: AnyView(TVEpisodeTab().environment(model)))
        episodes.title = "选集"
        episodes.preferredContentSize = CGSize(width: 0, height: 330)
        vc.customInfoViewControllers = [episodes]
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        guard context.coordinator.shown != controls else { return }
        context.coordinator.shown = controls
        let player = model.player
        vc.contextualActions = controls.hasNext ? [
            UIAction(title: "下一集", image: UIImage(systemName: "forward.end.fill")) { _ in player.step(1) },
        ] : []
        vc.transportBarCustomMenuItems = menus(player)
    }

    /// The menus in the bar at the bottom, the choice made ticked in each.
    @MainActor private func menus(_ player: Player) -> [UIMenuElement] {
        let c = controls
        var items: [UIMenuElement] = []
        let speed = UIMenu(title: "倍速", image: UIImage(systemName: "gauge.with.needle"), options: .singleSelection,
                           children: Player.speeds.reversed().map { s in
                               UIAction(title: speedLabel(s), state: s == c.speed ? .on : .off) { _ in player.setSpeed(s) }
                           })
        speed.subtitle = c.speed == 1 ? "正常" : "\(rateText(c.speed))x"
        items.append(speed)
        if !c.qualities.isEmpty {
            let quality = UIMenu(title: "清晰度", image: UIImage(systemName: "sparkles.tv"), options: .singleSelection,
                                 children: c.qualities.map { q in
                                     UIAction(title: "\(q)P", state: q == c.quality ? .on : .off) { _ in player.setQuality(q) }
                                 })
            quality.subtitle = "\(c.quality)P"
            items.append(quality)
        }
        let sleep = UIMenu(title: "定时关闭", image: UIImage(systemName: "moon.zzz"), options: .singleSelection,
                           children: sleepChoices.map { s, label in
                               UIAction(title: label, state: s == c.sleep ? .on : .off) { _ in player.setSleep(s) }
                           })
        sleep.subtitle = sleepLine(player)
        items.append(sleep)
        items.append(UIAction(title: c.danmaku ? "关闭弹幕" : "打开弹幕",
                              image: UIImage(systemName: c.danmaku ? "text.bubble.fill" : "text.bubble"),
                              state: c.danmaku ? .on : .off) { _ in
            UserDefaults.standard.set(!c.danmaku, forKey: danmakuKey)
        })
        return items
    }
}

/// TVEpisodeTab is the series playing and its episodes, the one playing
/// focused first, with the episodes either side and the series' seasons;
/// in the info panel, swiped down from the top while the video plays.
private struct TVEpisodeTab: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Int?

    var body: some View {
        let player = model.player
        if let sp = player.page, let series = sp.series {
            let watched = Set(model.history.get(sp.id)?.watched ?? [])
            let saved = model.favorites.has(sp.id)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 28) {
                    Text(series.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("第 \(player.number) 集 / 共 \(sp.episodes.count) 集")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button { player.step(-1) } label: {
                        Label("上一集", systemImage: "backward.end.fill")
                    }
                    .disabled(!player.hasPrevious)
                    Button { player.step(1) } label: {
                        Label("下一集", systemImage: "forward.end.fill")
                    }
                    .disabled(!player.hasNext)
                    Button { model.favorites.toggle(Fav(Card(series))) } label: {
                        Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
                    }
                }
                .focusSection()
                TVSeasonRow(sp: sp) { se in model.playSeason(se.seriesId) }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 20) {
                            ForEach(sp.episodes, id: \.id) { e in
                                TVEpisodeButton(episode: e, current: e.number == player.number,
                                                watched: watched.contains(e.number)) {
                                    if e.number != player.number {
                                        player.play(sp.id, e.number)
                                    }
                                }
                                .frame(width: 120)
                                .focused($focused, equals: e.number)
                                .id(e.number)
                            }
                        }
                        .padding(.vertical, 16) // room for a button to lift
                    }
                    .scrollClipDisabled()
                    .onAppear { proxy.scrollTo(player.number, anchor: .center) }
                    .onChange(of: player.number) { proxy.scrollTo(player.number, anchor: .center) }
                }
                .focusSection()
            }
            // Coming down into the panel, focus goes to the episode playing,
            // rather than to whatever is above it.
            .defaultFocus($focused, player.number, priority: .userInitiated)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
