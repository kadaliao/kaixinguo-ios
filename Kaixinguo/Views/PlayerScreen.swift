import AVKit
import KaixinguoKit
import MediaPlayer
import Openhongguo
import SwiftUI

/// PlayerScreen is the episode playing, its video filling the screen: what
/// plays and how fast above it, the episodes below it on iPhone and beside
/// it on iPad. Swiping up goes on to the next episode, and down back to the
/// one before. A while after the last touch, as the video plays, all but
/// the video fades away; a tap brings it back.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsize
    @Environment(\.verticalSizeClass) private var vsize
    @Environment(\.scenePhase) private var phase
    @State private var showEpisodes = false
    @State private var searching = false
    @State private var resumeAfterSearch = false
    private let hud = PlayerHost.shared.hud

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
                            .chrome(hud.chrome)
                            .overlay {
                                if !hud.chrome { // where it was, a tap brings the controls back
                                    Color.clear.contentShape(Rectangle())
                                        .onTapGesture { hud.showChrome() }
                                }
                            }
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
        .onAppear { hud.chrome = true }
        .onDisappear {
            Rotation.shared.release()
            PlayerHost.shared.restoreBrightness()
        }
        .onChange(of: phase) {
            if phase == .background {
                PlayerHost.shared.restoreBrightness()
            }
        }
        .background(ChromeTimer(busy: showEpisodes || searching))
        .statusBarHidden(landscape || !hud.chrome)
        .persistentSystemOverlays(landscape || !hud.chrome ? .hidden : .automatic)
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
    private let hud = PlayerHost.shared.hud

    var body: some View {
        ZStack {
            PlayerControllerView(player: model.player)
                .offset(y: hud.offset)
                .ignoresSafeArea(edges: landscape ? .all : .top)
            if model.player.external {
                CastMark()
            } else {
                DanmakuLayer(size: 16, pitch: 28)
                    .padding(.top, 48) // below the top bar
                    .ignoresSafeArea(edges: .horizontal)
                    .offset(y: hud.offset)
            }
            PauseMark()
            PlayerOverlay()
            VStack(spacing: 0) {
                TopBar(landscape: landscape, search: search)
                    .chrome(hud.chrome)
                SpeedHint()
                LevelHint()
                Spacer(minLength: 0)
                ProgressBar()
                    .chrome(hud.chrome)
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

/// CastMark covers the video while it plays on an AirPlay device: what it
/// plays on. Taps and swipes go through it, as on the video.
private struct CastMark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.system(size: 44, weight: .light))
                Text("正在投屏")
                    .font(.headline)
                if !player.castName.isEmpty {
                    Text(player.castName)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
            CastButton()
                .frame(width: 40, height: 44)
            Button(action: search) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 40, height: 44)
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

/// CastButton picks where the video plays: here, or on an Apple TV or a
/// television AirPlay reaches, which fetches it from the app itself.
private struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.tintColor = .white
        v.activeTintColor = .tintColor
        v.accessibilityLabel = "投屏"
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {}

    func makeCoordinator() -> Picking { Picking() }

    /// Picking keeps the controls while the devices to pick from show.
    @MainActor final class Picking: NSObject, @MainActor AVRoutePickerViewDelegate {
        func routePickerViewWillBeginPresentingRoutes(_ v: AVRoutePickerView) {
            PlayerHost.shared.hud.picking = true
        }

        func routePickerViewDidEndPresentingRoutes(_ v: AVRoutePickerView) {
            let hud = PlayerHost.shared.hud
            hud.picking = false
            hud.poke()
        }
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
            Button {
                rotation.turn(landscape: !landscape)
                PlayerHost.shared.hud.poke()
            } label: {
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
        Picker("倍速", selection: Binding(get: { player.speed }, set: {
            player.setSpeed($0)
            PlayerHost.shared.hud.poke()
        })) {
            ForEach(Player.speeds.reversed(), id: \.self) { s in
                Text(speedLabel(s)).tag(s)
            }
        }
    }
}

/// MoreMenu sets how the episode plays: its speed, its definition, when to
/// stop and whether danmaku show; and saves the series, or opens its page.
private struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage(danmakuKey) private var danmaku = true

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
                    Picker("清晰度", selection: Binding(get: { player.quality }, set: {
                        player.setQuality($0)
                        PlayerHost.shared.hud.poke()
                    })) {
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
                Picker("定时关闭", selection: Binding(get: { player.sleep }, set: {
                    player.setSleep($0)
                    PlayerHost.shared.hud.poke()
                })) {
                    ForEach(sleepChoices, id: \.0) { s, label in
                        Text(label).tag(s)
                    }
                }
            } label: {
                Label("定时关闭", systemImage: "moon.zzz")
                Text(sleepLine(player))
            }
            Toggle("弹幕", systemImage: "text.bubble", isOn: $danmaku)
            if let sp = player.page, let series = sp.series {
                Divider()
                let saved = model.favorites.has(sp.id)
                Button(favLabel(saved) + "这部剧", systemImage: saved ? "star.slash" : "star") {
                    model.favorites.toggle(Fav(Card(series)))
                    PlayerHost.shared.hud.poke()
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
        .onChange(of: danmaku) { PlayerHost.shared.hud.poke() }
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
                .onChanged { v in
                    dragged = min(max(v.location.x / w, 0), 1)
                    PlayerHost.shared.hud.scrubbing = true
                }
                .onEnded { _ in
                    PlayerHost.shared.hud.scrubbing = false
                    PlayerHost.shared.hud.poke()
                    seek(total)
                })
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

/// LevelHint shows the brightness or the volume a swipe up or down at the
/// side of the video sets, as it goes: the volume past 100% in orange, and
/// a mark where the system's loudest ends.
private struct LevelHint: View {
    private let hud = PlayerHost.shared.hud

    var body: some View {
        ZStack {
            if let level = hud.level {
                let most: Float = level.kind == .volume ? Player.boostLimit : 1
                let over = level.value > 1.001
                HStack(spacing: 10) {
                    Image(systemName: icon(level))
                        .frame(width: 24)
                        .accessibilityLabel(level.kind == .volume ? "音量" : "亮度")
                    GeometryReader { g in
                        let w = g.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(over ? Color.orange : .white)
                                .frame(width: w * CGFloat(level.value / most))
                            if most > 1 {
                                Rectangle().fill(.white.opacity(0.7))
                                    .frame(width: 1.5, height: 10)
                                    .offset(x: w / CGFloat(most))
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(width: 140, height: 10)
                    Text(verbatim: "\(Int((level.value * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: Capsule())
                .transition(.opacity)
                .sensoryFeedback(.impact(weight: .light), trigger: over) // past the system's loudest, and back
            }
        }
        .padding(.top, 12)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: hud.level == nil)
    }

    private func icon(_ level: PlayerHUD.Level) -> String {
        switch level.kind {
        case .brightness:
            return level.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            switch level.value {
            case ..<0.01: return "speaker.slash.fill"
            case ..<0.34: return "speaker.wave.1.fill"
            case ..<0.67: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
            }
        }
    }
}

private extension View {
    /// Shows the controls, or fades them, leaving taps where they were to
    /// the video.
    func chrome(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(.easeInOut(duration: 0.3), value: shown)
    }
}

/// ChromeTimer fades the controls once the video has played on a while
/// untouched, and brings them back as it pauses or fails. It is a view of
/// its own so that each touch, which starts it again, redraws nothing else.
///
/// The touches are counted where they land (`PlayerHUD.poke`), not by a
/// recognizer watching the whole screen: that holds up a menu's items and
/// the video's own taps, which then go missing now and then.
private struct ChromeTimer: View {
    var busy: Bool // something else on screen, which the controls stay for
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private let hud = PlayerHost.shared.hud

    /// How long the controls stay after the last touch, as the video plays;
    /// Debug builds take `-KXChromeFor <seconds>`, so the UI tests have time
    /// to reach them.
    private static var delay: Duration {
        #if DEBUG
        let s = UserDefaults.standard.double(forKey: "KXChromeFor")
        if s > 0 {
            return .seconds(s)
        }
        #endif
        return .seconds(4)
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task(id: key) {
                let k = key
                guard k.shown, k.playing, !k.busy else { return }
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { hud.chrome = false }
            }
            .onChange(of: stopped) {
                if stopped {
                    hud.showChrome()
                }
            }
    }

    /// Whether the video has stopped where the viewer sees it: paused, or
    /// failed.
    private var stopped: Bool {
        let player = model.player
        if case .failed = player.state {
            return true
        }
        return player.paused && (player.state == .playing || player.state == .buffering)
    }

    /// What the fading waits on: it starts again as any of it changes.
    private var key: ChromeKey {
        let player = model.player
        return ChromeKey(touches: hud.touches, shown: hud.chrome,
                         playing: player.state == .playing && !player.paused,
                         busy: busy || voiceOver || hud.holding || hud.level != nil || hud.scrubbing || hud.picking
                             || hud.offset != 0)
    }
}

/// ChromeKey is what the controls fading waits on.
private struct ChromeKey: Hashable {
    var touches: Int
    var shown: Bool
    var playing: Bool
    var busy: Bool
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
/// brings back the controls, or with them showing pauses; a swipe up or
/// down moves between episodes in the middle, and sets the brightness on
/// the left and the volume on the right; a press and hold plays at double
/// speed.
@MainActor
final class PlayerHost: NSObject, @MainActor AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    static let shared = PlayerHost()
    /// How far a held finger swipes to lock double speed on, or off.
    private static let holdSwipe: CGFloat = 40

    let hud = PlayerHUD()
    private var vc: AVPlayerViewController?
    private weak var player: Player?
    private var holdFrom: CGFloat = 0 // where the held finger was when it began
    private var swipe: PlayerHUD.Level.Kind? // what a swipe sets; nil to move between episodes
    private var swipeFrom: Float = 0 // the level as the swipe began
    private var brightnessBefore: CGFloat? // the screen's, before a swipe set it
    private let volume = Volume()

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
        volume.install(in: vc.view, player: player)
        self.vc = vc
        return vc
    }

    // MARK: Fingers on the video

    @objc private func tapped() {
        guard hud.chrome else {
            hud.showChrome()
            return
        }
        player?.togglePause()
        hud.poke()
    }

    /// A swipe up or down: on the left third of the video it sets the
    /// brightness, on the right third the volume, and in the middle it
    /// moves between episodes.
    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        guard let player, let view = g.view else { return }
        if g.state == .began {
            let w = view.bounds.width
            let x = g.location(in: view).x - g.translation(in: view).x // where the finger came down
            swipe = x < w / 3 ? .brightness : x > w * 2 / 3 ? .volume : nil
        }
        if let swipe {
            adjust(swipe, g, view, player)
        } else {
            moveEpisodes(g, view, player)
        }
        if g.state == .ended || g.state == .cancelled {
            hud.touches += 1
        }
    }

    /// Sets the brightness or the volume as the finger goes: a swipe most
    /// of the way up the video goes from none to full. The volume goes on
    /// past the system's loudest, to `Player.boostLimit`.
    private func adjust(_ kind: PlayerHUD.Level.Kind, _ g: UIPanGestureRecognizer, _ view: UIView, _ player: Player) {
        let screen = view.window?.windowScene?.screen
        switch g.state {
        case .began:
            swipeFrom = kind == .brightness ? Float(screen?.brightness ?? 0.5) : volume.level(player)
            hud.adjusting = true
            hud.level = PlayerHUD.Level(kind: kind, value: swipeFrom)
        case .changed:
            let span = max(view.bounds.height * 0.7, 240)
            let most = kind == .brightness ? 1 : volume.most(player)
            let v = min(max(swipeFrom + Float(-g.translation(in: view).y / span), 0), most)
            switch kind {
            case .brightness:
                if brightnessBefore == nil {
                    brightnessBefore = screen?.brightness
                }
                screen?.brightness = CGFloat(v)
            case .volume:
                volume.set(v, player)
            }
            hud.level?.value = v
        default:
            hud.adjusting = false
            let hud = hud
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if !hud.adjusting {
                    hud.level = nil
                }
            }
        }
    }

    /// Puts the screen's brightness back as it was before a swipe set it,
    /// as the player closes or the app leaves the screen.
    func restoreBrightness() {
        guard let b = brightnessBefore else { return }
        brightnessBefore = nil
        vc?.view.window?.windowScene?.screen.brightness = b
    }

    /// Swiping up plays the next episode, and down the one before: the
    /// video follows the finger, and goes on out if it went far or fast
    /// enough.
    private func moveEpisodes(_ g: UIPanGestureRecognizer, _ view: UIView, _ player: Player) {
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
            hud.touches += 1
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
    /// Whether the controls over the video show: they fade a while after
    /// the last touch as the video plays, and a tap brings them back.
    var chrome = true
    /// How many touches on the video and its controls have ended, each
    /// keeping the controls a while longer; and what keeps them while it
    /// goes on: a finger dragging along the progress bar, the AirPlay
    /// devices to pick from.
    var touches = 0
    var scrubbing = false
    var picking = false
    /// The brightness or volume a swipe at the side sets, while it shows;
    /// and whether the swipe goes on.
    var level: Level?
    var adjusting = false
    var holding = false
    /// Whether the held finger has swiped far enough that letting go flips
    /// the lock.
    var swiped = false
    /// How far the video has followed a swipe up or down.
    var offset: CGFloat = 0
    /// What the last gesture did, or couldn't, said for a moment.
    var toast: String?

    struct Level: Equatable {
        enum Kind { case brightness, volume }
        var kind: Kind
        var value: Float // brightness 0 to 1; volume 0 to `Player.boostLimit`
    }

    func showChrome() {
        guard !chrome else { return }
        withAnimation(.easeOut(duration: 0.2)) { chrome = true }
    }

    /// Keeps the controls a while longer, after a touch on them; or brings
    /// them back, as a choice in a menu they faded behind is made.
    func poke() {
        touches += 1
        showChrome()
    }
}

// MARK: - Volume

/// Volume sets the system's volume from a swipe, through a volume view of
/// its own on the player, which keeps the system's volume from showing
/// too; past the system's loudest it turns the episode up itself
/// (`Player.setBoost`). The volume buttons turning it down end that.
@MainActor
final class Volume {
    private let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 20, height: 20))
    private var observer: NSKeyValueObservation?
    private weak var player: Player?

    func install(in host: UIView, player: Player) {
        self.player = player
        view.alpha = 0.01 // there, but not seen: the system's volume shows otherwise
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        host.addSubview(view)
        observer = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] s, _ in
            let v = s.outputVolume
            Task { @MainActor in
                if v < 0.99, let p = self?.player, p.boost > 1 {
                    p.setBoost(1)
                }
            }
        }
    }

    private var system: Float { AVAudioSession.sharedInstance().outputVolume }

    /// The volume now, from 0 to `most`.
    func level(_ player: Player) -> Float {
        player.boost > 1 ? player.boost : system
    }

    /// The loudest a swipe goes: past the system's only on this device.
    func most(_ player: Player) -> Float {
        player.casting ? 1 : Player.boostLimit
    }

    func set(_ v: Float, _ player: Player) {
        let s = min(v, 1)
        if abs(system - s) > 0.001, let slider = view.subviews.lazy.compactMap({ $0 as? UISlider }).first {
            slider.value = s
            slider.sendActions(for: .valueChanged)
        }
        player.setBoost(max(v, 1))
    }
}
