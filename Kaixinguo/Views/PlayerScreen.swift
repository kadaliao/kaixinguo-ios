import AVKit
import KaixinguoKit
import Openhongguo
import SwiftUI

/// PlayerScreen is the episode playing, its video filling the screen: what
/// plays and how fast above it, the episodes below it on iPhone and beside
/// it on iPad. Swiping up goes on to the next episode, and down back to the
/// one before.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsize
    @Environment(\.verticalSizeClass) private var vsize
    @State private var showEpisodes = false
    @State private var searching = false
    @State private var resumeAfterSearch = false

    var body: some View {
        let landscape = vsize == .compact // a phone on its side: the video alone
        let panel = !landscape && hsize == .regular
        ZStack {
            // One layout for all three, so the video keeps its place, and
            // its player, as the device turns.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VideoArea(landscape: landscape, search: openSearch)
                    if !landscape && !panel {
                        EpisodeBar { showEpisodes = true }
                    }
                }
                if panel {
                    EpisodePanel(steps: true)
                        .frame(width: 320)
                        .background(Color(white: 0.09))
                }
            }
            if searching {
                PlayerSearch(close: closeSearch)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .background {
            if !searching {
                KeyControls()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onDisappear { Rotation.shared.release() }
        .statusBarHidden(landscape)
        .persistentSystemOverlays(landscape ? .hidden : .automatic)
        .sheet(isPresented: $showEpisodes) {
            EpisodePanel { showEpisodes = false }
                .presentationDetents([.medium, .large])
                .presentationBackground(Color(white: 0.09))
                .environment(\.colorScheme, .dark)
        }
    }

    /// Pauses the episode for a search, to go on with it after.
    private func openSearch() {
        let player = model.player
        resumeAfterSearch = player.av.rate != 0
        player.av.pause()
        withAnimation(.easeOut(duration: 0.25)) { searching = true }
    }

    /// Leaves the search: to play the series picked, or the episode as it
    /// was.
    private func closeSearch(_ picked: Card?) {
        withAnimation(.easeOut(duration: 0.25)) { searching = false }
        if let picked {
            model.playSeason(picked.id)
        } else if resumeAfterSearch {
            model.player.av.play()
        }
    }
}

/// VideoArea is the video and what lies over it: what plays and how fast at
/// the top, how far it has got at the bottom, and what a press, a pause or a
/// failure shows. The video goes up under the status bar, and on a phone on
/// its side to every edge.
private struct VideoArea: View {
    var landscape: Bool
    var search: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            PlayerControllerView(player: model.player)
                .offset(y: PlayerHost.shared.hud.offset)
                .ignoresSafeArea(edges: landscape ? .all : .top)
            PauseMark()
            PlayerOverlay()
            VStack(spacing: 0) {
                TopBar(landscape: landscape, search: search)
                SpeedHint()
                Spacer(minLength: 0)
                ProgressBar()
            }
        }
    }
}

/// PlayerOverlay is what covers the video while it isn't playing: a
/// spinner while it loads or waits for more, or what went wrong. Swipes go
/// through it, to the episodes either side.
private struct PlayerOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        switch player.state {
        case .resolving:
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                ProgressView().controlSize(.large).tint(.white)
            }
            .allowsHitTesting(false)
        case .buffering where !player.paused:
            ProgressView().controlSize(.large).tint(.white)
                .allowsHitTesting(false)
        case .failed(let msg):
            ZStack {
                Color.black.opacity(0.85).ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: 16) {
                    Text(msg)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    HStack(spacing: 12) {
                        Button("重试") { player.retry() }
                            .buttonStyle(.borderedProminent)
                        if player.hasNext {
                            Button("下一集") { player.step(1) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
        default:
            EmptyView()
        }
    }
}

/// KeyControls are the keys of a keyboard that work the video, now the
/// system's controls are hidden: space pauses it or plays it on, and the
/// arrows left and right go back or on ten seconds.
private struct KeyControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ZStack {
            Button("暂停或继续") { player.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("快退 10 秒") { player.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("快进 10 秒") { player.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// PauseMark says the video is paused; a tap anywhere on it plays on.
private struct PauseMark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.paused && (player.state == .playing || player.state == .buffering) {
            Image(systemName: "play.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.4), radius: 8)
                .allowsHitTesting(false)
                .accessibilityLabel("已暂停")
        }
    }
}

// MARK: - Over the video

/// TopBar is what plays, and how fast, over the top of the video, with the
/// way out, to turn the screen, to search and to more.
private struct TopBar: View {
    var landscape: Bool
    var search: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 2) {
            Button { player.leave() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("退出播放")
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "第 \(player.number) 集")
                    .font(.headline)
                    .monospacedDigit()
                if let title = player.page?.series?.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(episodeLine(player))
            .accessibilityAddTraits(.isStaticText)
            Spacer(minLength: 8)
            SpeedMenu()
            RotateButton(landscape: landscape)
            Button(action: search) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("搜索")
            MoreMenu()
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3)
        .padding(.horizontal, 6)
        .background {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -24)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

/// SpeedMenu shows the speed the video plays at, and changes it.
private struct SpeedMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        Menu {
            SpeedPicker()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.needle")
                Text(player.speed == 1 ? "倍速" : "\(rateText(player.speed))x")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("倍速")
        .accessibilityValue(player.speed == 1 ? "正常" : "\(rateText(player.speed)) 倍")
    }
}

/// RotateButton turns the screen on its side for a video wider than tall,
/// and upright again: on iPhone, where on its side the screen shows the
/// video alone. It stays while the screen is held on its side, so there is
/// always a way back, even to a series shot upright.
private struct RotateButton: View {
    var landscape: Bool
    @Environment(AppModel.self) private var model
    private let rotation = Rotation.shared

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .phone, model.player.wide || rotation.held == .landscape {
            Button { rotation.turn(landscape: !landscape) } label: {
                Image(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(landscape ? "竖屏观看" : "横屏观看")
        }
    }
}

/// SpeedPicker is the speeds to play at, the one playing ticked.
private struct SpeedPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        Picker("倍速", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
            ForEach(Player.speeds.reversed(), id: \.self) { s in
                Text(s == 1 ? "1x 正常" : "\(rateText(s))x").tag(s)
            }
        }
    }
}

/// MoreMenu sets how the episode plays: its speed, its definition and when
/// to stop; and saves the series, or opens its page.
private struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let player = model.player
        Menu {
            Menu {
                SpeedPicker()
            } label: {
                Label("倍速", systemImage: "gauge.with.needle")
                Text(player.speed == 1 ? "正常" : "\(rateText(player.speed))x")
            }
            if !player.qualities.isEmpty {
                Menu {
                    Picker("清晰度", selection: Binding(get: { player.quality }, set: { player.setQuality($0) })) {
                        ForEach(player.qualities, id: \.self) { q in
                            Text(verbatim: "\(q)P").tag(q)
                        }
                    }
                } label: {
                    Label("清晰度", systemImage: "sparkles.tv")
                    Text(verbatim: "\(player.quality)P")
                }
            }
            Menu {
                Picker("定时关闭", selection: Binding(get: { player.sleep }, set: { player.setSleep($0) })) {
                    Text("不开启").tag(Player.Sleep.off)
                    Text("播完本集").tag(Player.Sleep.endOfEpisode)
                    ForEach([15, 30, 60, 90], id: \.self) { m in
                        Text("\(m) 分钟").tag(Player.Sleep.minutes(m))
                    }
                }
            } label: {
                Label("定时关闭", systemImage: "moon.zzz")
                Text(sleepLine(player))
            }
            if let sp = player.page, let series = sp.series {
                Divider()
                let saved = model.favorites.has(sp.id)
                Button(favLabel(saved) + "这部剧", systemImage: saved ? "star.slash" : "star") {
                    model.favorites.toggle(Fav(Card(series)))
                }
                Button("剧集详情", systemImage: "info.circle") {
                    player.leave()
                    if router.paths[router.tab]?.last != .series(sp.id) {
                        router.open(.series(sp.id))
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    /// When the sleep timer stops the video: "播完本集", "22:30 停止".
    private func sleepLine(_ player: Player) -> String {
        switch player.sleep {
        case .off: "未开启"
        case .endOfEpisode: "播完本集"
        case .minutes:
            (player.sleepAt?.formatted(date: .omitted, time: .shortened) ?? "") + " 停止"
        }
    }
}

/// ProgressBar is how far the episode has got, along the bottom of the
/// video; dragging along it moves there.
private struct ProgressBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragged: Double? // where a drag is, as a fraction

    var body: some View {
        let av = model.player.av
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let d = av.currentItem?.duration.seconds ?? .nan
            let total = d.isFinite && d > 0 ? d : 0
            let t = av.currentTime().seconds
            let at = dragged ?? (total > 0 && t.isFinite ? min(max(t / total, 0), 1) : 0)
            VStack(spacing: 8) {
                if let dragged {
                    Text("\(clock(dragged * total)) / \(clock(total))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                track(at, total: total)
            }
        }
        .padding(.horizontal, 12)
    }

    private func track(_ at: Double, total: Double) -> some View {
        let active = dragged != nil
        let knob: CGFloat = active ? 14 : 7
        return GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                    .frame(height: active ? 4 : 2)
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: w * at, height: active ? 4 : 2)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .offset(x: w * at - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragged = min(max(v.location.x / w, 0), 1) }
                .onEnded { _ in seek(total) })
        }
        .frame(height: 28)
        .opacity(total > 0 ? 1 : 0)
        .allowsHitTesting(total > 0)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(clock(at * total)) / \(clock(total))")
    }

    /// Moves to where the drag let go, keeping the bar there until the video
    /// has.
    private func seek(_ total: Double) {
        guard let f = dragged else { return }
        let player = model.player
        Task {
            await player.av.seek(to: CMTime(seconds: f * total, preferredTimescale: 600))
            dragged = nil
        }
    }
}

/// Seconds as minutes and seconds: 1:05.
private func clock(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let n = Int(s)
    return String(format: "%d:%02d", n / 60, n % 60)
}

/// A speed as the player writes it: 1.25, 2.
private func rateText(_ r: Float) -> String {
    Double(r).formatted()
}

/// SpeedHint shows a press and hold on the video at work: double speed, and
/// which way to swipe to lock it on or turn it off; and, for a moment, what
/// a swipe did.
private struct SpeedHint: View {
    @Environment(AppModel.self) private var model
    private let hud = PlayerHost.shared.hud

    var body: some View {
        let player = model.player
        let holding = hud.holding
        VStack(spacing: 8) {
            if holding {
                let locked = player.doubleSpeed == .locked
                Label(locked ? "已锁定 2 倍速" : "2 倍速播放中", systemImage: locked ? "lock.fill" : "forward.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                swipe(locked: locked, base: player.baseRate)
            } else if let toast = hud.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: holding)
        .animation(.easeOut(duration: 0.15), value: hud.swiped)
        .animation(.easeOut(duration: 0.25), value: hud.toast)
        .sensoryFeedback(.impact(weight: .medium), trigger: holding) { _, on in on }
        .sensoryFeedback(.selection, trigger: hud.swiped) { _, _ in holding }
        .task(id: hud.toast) {
            guard hud.toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            hud.toast = nil
        }
    }

    /// Which way to swipe, or, once swiped far enough, what letting go does.
    private func swipe(locked: Bool, base: Float) -> some View {
        let swiped = hud.swiped
        let (icon, text) = switch (locked, swiped) {
        case (false, false): ("chevron.down", "下滑锁定 2 倍速")
        case (false, true): ("lock.fill", "松手锁定 2 倍速")
        case (true, false): ("chevron.up", "上滑取消 2 倍速")
        case (true, true): ("arrow.uturn.backward", "松手" + restoring(base))
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .symbolEffect(locked ? .bounce.up : .bounce.down, options: .repeat(.periodic(delay: 0.4)),
                              isActive: !swiped)
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(swiped ? .black : .white)
        .background(swiped ? .white : .black.opacity(0.45), in: Capsule())
    }
}

/// What going back from double speed says: to the speed the viewer chose.
private func restoring(_ rate: Float) -> String {
    rate == 1 ? "恢复正常速度" : "恢复 \(rateText(rate)) 倍速"
}

// MARK: - Under and beside the video

/// EpisodeBar opens the episodes, under the video on iPhone.
private struct EpisodeBar: View {
    var open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = model.player.page?.episodes.count ?? 0
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.footnote)
                Text(verbatim: total > 0 ? "选集 · 全 \(total) 集" : "选集")
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选集")
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// PreviousButton and NextButton move between episodes; the arrows up and
/// down of a keyboard do too.
private struct PreviousButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.player.step(-1) } label: {
            Label("上一集", systemImage: "backward.end.fill")
        }
        .keyboardShortcut(.upArrow, modifiers: [])
        .disabled(!model.player.hasPrevious)
    }
}

private struct NextButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.player.step(1) } label: {
            Label("下一集", systemImage: "forward.end.fill")
        }
        .keyboardShortcut(.downArrow, modifiers: [])
        .disabled(!model.player.hasNext)
    }
}

/// EpisodePanel is the series' title and its episodes, beside the video on
/// iPad, with buttons to move between them, and in a sheet on iPhone, which
/// `picked` closes once something plays.
struct EpisodePanel: View {
    var steps = false
    var picked: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if let sp = player.page, let series = sp.series {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(series.title)
                        .font(.title3.bold())
                        .lineLimit(2)
                    Text(episodeLine(player))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if steps {
                        HStack(spacing: 10) {
                            PreviousButton()
                            NextButton()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    SeasonChips(sp: sp) { se in
                        model.playSeason(se.seriesId)
                        picked()
                    }
                    .padding(.horizontal, -20)
                    .padding(.top, 4)
                    PartPicker(sp: sp)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 14)
                Divider().overlay(Color.white.opacity(0.06))
                ScrollViewReader { proxy in
                    ScrollView {
                        EpisodeGrid(sp: sp, current: player.number,
                                    watched: Set(model.history.get(sp.id)?.watched ?? []), minWidth: 46) { e in
                            if e.number != player.number {
                                player.play(sp.id, e.number)
                            }
                            picked()
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo(player.number, anchor: .center) }
                    .onChange(of: player.number) {
                        withAnimation { proxy.scrollTo(player.number, anchor: .center) }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor private func episodeLine(_ player: Player) -> String {
    let total = player.page?.episodes.count ?? 0
    return total > 0 ? "第 \(player.number) 集 / 共 \(total) 集" : "第 \(player.number) 集"
}

// MARK: - Searching from the player

/// PlayerSearch looks for another series without leaving the player: the
/// hot searches, then what was searched for. Picking a series plays it; the
/// back button beside the field goes back to the episode.
private struct PlayerSearch: View {
    var close: (Card?) -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var query = ""
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { close(nil) } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回播放")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索短剧", text: $text)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { submit(text) }
                    if !text.isEmpty {
                        Button {
                            text = ""
                            focused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color(white: 0.16), in: Capsule())
                Button("搜索") { submit(text) }
                    .buttonStyle(.plain)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 44)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            content
                .frame(maxHeight: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .environment(\.playCard, PlayCard { close($0) })
        .onAppear { focused = true }
        .onChange(of: text) {
            if text.isEmpty {
                query = ""
            }
        }
        .task(id: text) {
            let t = text
            guard !t.isEmpty, t != query else {
                suggestions = []
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            suggestions = await model.suggestions(t)
        }
    }

    @ViewBuilder private var content: some View {
        if !suggestions.isEmpty && text != query {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { submit(s) } label: {
                            Label(s, systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        } else if query.isEmpty {
            HotView { submit($0) }
        } else {
            FeedGrid(feed: model.searchFeed(query), empty: "没有找到“\(query)”相关的短剧，换个词试试")
                .scrollDismissesKeyboard(.immediately)
        }
    }

    private func submit(_ s: String) {
        let q = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        text = q
        query = q
        suggestions = []
        focused = false
    }
}

// MARK: - The system's player

/// PlayerControllerView shows the system's player, without its controls:
/// the player's screen has its own. It still does picture in picture, and
/// what the lock screen shows.
private struct PlayerControllerView: UIViewControllerRepresentable {
    let player: Player

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        PlayerHost.shared.controller(for: player)
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

/// PlayerHost keeps the one player view controller there is, so picture
/// in picture goes on when the player's screen closes, and comes back to
/// the screen it left. It also reads the fingers on the video: a tap
/// pauses, a swipe moves between episodes, and a press and hold plays at
/// double speed.
@MainActor
final class PlayerHost: NSObject, @MainActor AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    static let shared = PlayerHost()
    /// How far a held finger swipes to lock double speed on, or off.
    private static let holdSwipe: CGFloat = 40

    let hud = PlayerHUD()
    private var vc: AVPlayerViewController?
    private weak var player: Player?
    private var holdFrom: CGFloat = 0 // where the held finger was when it began

    func controller(for player: Player) -> AVPlayerViewController {
        self.player = player
        if let vc {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
            return vc
        }
        let vc = AVPlayerViewController()
        vc.player = player.av
        vc.showsPlaybackControls = false
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        vc.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped))
        swipe.delegate = self
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        for g in [tap, swipe, press] {
            vc.view.addGestureRecognizer(g)
        }
        self.vc = vc
        return vc
    }

    // MARK: Fingers on the video

    @objc private func tapped() {
        player?.togglePause()
    }

    /// Swiping up plays the next episode, and down the one before: the
    /// video follows the finger, and goes on out if it went far or fast
    /// enough.
    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        guard let player, let view = g.view else { return }
        let dy = g.translation(in: nil).y
        let d = dy < 0 ? 1 : -1
        let can = d > 0 ? player.hasNext : player.hasPrevious
        switch g.state {
        case .changed:
            hud.offset = can ? dy : dy / 4 // nowhere to go: it gives a little
        case .ended:
            let h = view.bounds.height
            let vy = g.velocity(in: nil).y
            guard can, abs(dy) > h / 6 || (abs(vy) > 700 && vy * dy > 0) else {
                withAnimation(.spring(duration: 0.3)) { hud.offset = 0 }
                if !can && abs(dy) > 50 {
                    hud.toast = d > 0 ? "已经是最后一集了" : "已经是第一集了"
                }
                return
            }
            withAnimation(.easeIn(duration: 0.2)) {
                hud.offset = dy < 0 ? -h : h
            } completion: { [hud] in
                player.step(d)
                hud.offset = 0 // the screen black, until the next episode
            }
        case .cancelled, .failed:
            withAnimation(.spring(duration: 0.3)) { hud.offset = 0 }
        default:
            break
        }
    }

    /// Plays at double speed while a finger holds the video; swiping down
    /// locks it on, and swiping up in a later hold turns it off.
    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard let player else { return }
        let y = g.location(in: g.view).y
        switch g.state {
        case .began:
            holdFrom = y
            player.beginHold()
            hud.toast = nil
            hud.holding = true
        case .changed:
            let dy = y - holdFrom
            let swiped = player.doubleSpeed == .locked ? dy < -Self.holdSwipe : dy > Self.holdSwipe
            if swiped != hud.swiped {
                hud.swiped = swiped
            }
        case .ended, .cancelled:
            let was = player.doubleSpeed
            player.endHold(swiped: g.state == .ended && hud.swiped)
            hud.holding = false
            hud.swiped = false
            switch (was, player.doubleSpeed) {
            case (.held, .locked): hud.toast = "已锁定 2 倍速，长按上滑可取消"
            case (.locked, .off): hud.toast = "已" + restoring(player.baseRate)
            default: break
            }
        default:
            break
        }
    }

    /// A swipe goes up or down, leaving sideways ones alone.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: nil)
        return abs(v.y) > abs(v.x)
    }

    // MARK: Picture in picture

    func playerViewControllerWillStartPictureInPicture(_ vc: AVPlayerViewController) {
        player?.inPictureInPicture = true
        player?.isPresented = false // back to browsing, the video in its window
    }

    func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
        player?.inPictureInPicture = false
    }

    func playerViewController(_ vc: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        player?.isPresented = true
        // The screen slides up first; then the video flies back into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { done(true) }
    }
}

// MARK: - Turning the screen

/// Rotation turns the screen at a press: on its side, whichever way the
/// phone is held, and upright again. The way pressed holds until the phone
/// is turned that way too, when the screen goes back to following the
/// phone; and as the player closes.
@MainActor @Observable
final class Rotation {
    static let shared = Rotation()

    /// The way a press turned the screen, while the phone isn't turned so:
    /// `.landscape` or `.portrait`.
    private(set) var held: UIInterfaceOrientationMask?
    @ObservationIgnored private var observer: Any?

    private init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.phoneTurned() }
        }
    }

    /// The ways the screen may turn: the one pressed, while it holds, or
    /// else those of the project's Info.plist settings.
    var mask: UIInterfaceOrientationMask {
        held ?? (UIDevice.current.userInterfaceIdiom == .phone ? .allButUpsideDown : .all)
    }

    /// Turns the screen on its side, or upright.
    func turn(landscape: Bool) {
        let phone = UIDevice.current.orientation
        held = Self.held(phone, as: landscape) ? nil : landscape ? .landscape : .portrait
        update(landscape ? Self.side(phone) : .portrait)
    }

    /// Lets the screen follow the phone again, as the player closes:
    /// upright, unless the phone is on its side.
    func release() {
        guard held != nil else { return }
        held = nil
        let phone = UIDevice.current.orientation
        update(phone.isLandscape ? Self.side(phone) : .portrait)
    }

    private func phoneTurned() {
        guard let held, Self.held(UIDevice.current.orientation, as: held == .landscape) else { return }
        self.held = nil
        update(nil)
    }

    /// Whether the phone is on its side, or upright, as asked.
    private static func held(_ phone: UIDeviceOrientation, as landscape: Bool) -> Bool {
        landscape ? phone.isLandscape : phone == .portrait
    }

    /// The screen on its side the right way up for the phone: the top
    /// toward the left unless it's held the other way.
    private static func side(_ phone: UIDeviceOrientation) -> UIInterfaceOrientationMask {
        phone == .landscapeRight ? .landscapeLeft : .landscapeRight
    }

    /// Tells the system the ways the screen may turn have changed, and
    /// turns it to `to`.
    private func update(_ to: UIInterfaceOrientationMask?) {
        guard let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        var vc = scene.keyWindow?.rootViewController
        while let v = vc {
            v.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = v.presentedViewController
        }
        if let to {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: to))
        }
    }
}

/// PlayerHUD is what the fingers on the video are doing, for what shows
/// over it: a press and hold as it goes, the video following a swipe, and
/// a word on what the last one did.
@MainActor @Observable
final class PlayerHUD {
    var holding = false
    /// Whether the held finger has swiped far enough that letting go flips
    /// the lock.
    var swiped = false
    /// How far the video has followed a swipe up or down.
    var offset: CGFloat = 0
    /// What the last gesture did, or couldn't, said for a moment.
    var toast: String?
}
