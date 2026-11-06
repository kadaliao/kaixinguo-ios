import AVKit
import KaixinguoKit
import Openhongguo
import SwiftUI

/// PlayerScreen is the episode playing: full screen on iPhone, beside its
/// episodes on iPad.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsize
    @Environment(\.verticalSizeClass) private var vsize
    @State private var showEpisodes = false

    var body: some View {
        let landscape = vsize == .compact // a phone on its side: the video alone
        let panel = !landscape && hsize == .regular
        let bars = !landscape && !panel
        // One layout for all three, so the video keeps its place, and its
        // player, as the device turns.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if bars {
                    TopBar()
                }
                video.overlay(alignment: .topLeading) {
                    if !bars {
                        CloseButton().padding(landscape ? 12 : 16)
                    }
                }
                if bars {
                    BottomBar(showEpisodes: $showEpisodes)
                }
            }
            .ignoresSafeArea(edges: landscape ? .all : [])
            if panel {
                EpisodePanel(steps: true)
                    .frame(width: 320)
                    .background(Color(white: 0.09))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden(vsize == .compact)
        .persistentSystemOverlays(vsize == .compact ? .hidden : .automatic)
        .sheet(isPresented: $showEpisodes) {
            EpisodePanel()
                .presentationDetents([.medium, .large])
                .presentationBackground(Color(white: 0.09))
                .environment(\.colorScheme, .dark)
        }
    }

    private var video: some View {
        ZStack {
            PlayerControllerView(player: model.player)
            SpeedHint()
            PlayerOverlay()
        }
    }
}

/// PlayerOverlay is what covers the video while it isn't playing: a
/// spinner while it loads, or what went wrong.
private struct PlayerOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        switch player.state {
        case .resolving:
            ZStack {
                Color.black.opacity(0.5)
                ProgressView().controlSize(.large).tint(.white)
            }
            .allowsHitTesting(false)
        case .failed(let msg):
            ZStack {
                Color.black.opacity(0.85)
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

/// SpeedHint shows a press and hold on the video at work: double speed, and
/// which way to swipe to lock it on or turn it off; then, for a moment,
/// what the swipe did.
private struct SpeedHint: View {
    @Environment(AppModel.self) private var model
    private let hold = PlayerHost.shared.hold

    var body: some View {
        let player = model.player
        let active = hold.active
        VStack(spacing: 8) {
            if active {
                let locked = player.doubleSpeed == .locked
                Label(locked ? "已锁定 2 倍速" : "2 倍速播放中", systemImage: locked ? "lock.fill" : "forward.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                swipe(locked: locked, base: player.baseRate)
            } else if let done = hold.done {
                Text(done)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 56) // under the player's own top controls
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.15), value: hold.swiped)
        .animation(.easeOut(duration: 0.25), value: hold.done)
        .sensoryFeedback(.impact(weight: .medium), trigger: active) { _, on in on }
        .sensoryFeedback(.selection, trigger: hold.swiped) { _, _ in active }
        .task(id: hold.done) {
            guard hold.done != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            hold.done = nil
        }
    }

    /// Which way to swipe, or, once swiped far enough, what letting go does.
    private func swipe(locked: Bool, base: Float) -> some View {
        let swiped = hold.swiped
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
    rate == 1 ? "恢复正常速度" : "恢复 \(Double(rate).formatted()) 倍速"
}

private struct CloseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.player.leave() } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("退出播放")
    }
}

/// TopBar is the series and the episode, over the video on iPhone.
private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 8) {
            CloseButton()
            VStack(spacing: 2) {
                Text(player.page?.series?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(episodeLine(player))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// BottomBar moves between episodes, under the video on iPhone.
private struct BottomBar: View {
    @Binding var showEpisodes: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            PreviousButton()
            Spacer()
            Button { showEpisodes = true } label: {
                Label("选集", systemImage: "square.grid.3x3.fill")
            }
            Spacer()
            NextButton()
        }
        .labelStyle(BarLabelStyle())
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct BarLabelStyle: LabelStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title.font(.caption2)
        }
        .frame(minWidth: 56, minHeight: 44)
        .opacity(enabled ? 1 : 0.35)
        .contentShape(Rectangle())
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
/// iPad, with buttons to move between them, and in a sheet on iPhone.
struct EpisodePanel: View {
    var steps = false
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
                    SeasonChips(sp: sp) { se in model.playSeason(se.seriesId) }
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

// MARK: - The system's player

/// PlayerControllerView shows the system's player, with its controls,
/// picture in picture and the speeds it offers.
private struct PlayerControllerView: UIViewControllerRepresentable {
    let player: Player

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        PlayerHost.shared.controller(for: player)
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

/// PlayerHost keeps the one player view controller there is, so picture
/// in picture goes on when the player's screen closes, and comes back to
/// the screen it left. It also watches for a press and hold on the video.
@MainActor
final class PlayerHost: NSObject, @MainActor AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    static let shared = PlayerHost()
    /// How far a held finger swipes to lock double speed on, or off.
    private static let swipe: CGFloat = 40

    let hold = SpeedHold()
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
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        vc.delegate = self
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        press.delegate = self
        vc.view.addGestureRecognizer(press)
        self.vc = vc
        return vc
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
            hold.done = nil
            hold.active = true
        case .changed:
            let dy = y - holdFrom
            let swiped = player.doubleSpeed == .locked ? dy < -Self.swipe : dy > Self.swipe
            if swiped != hold.swiped {
                hold.swiped = swiped
            }
        case .ended, .cancelled:
            let was = player.doubleSpeed
            player.endHold(swiped: g.state == .ended && hold.swiped)
            hold.active = false
            hold.swiped = false
            switch (was, player.doubleSpeed) {
            case (.held, .locked): hold.done = "已锁定 2 倍速，长按上滑可取消"
            case (.locked, .off): hold.done = "已" + restoring(player.baseRate)
            default: break
            }
        default:
            break
        }
    }

    /// Leaves the player's own controls, its scrubber and buttons, to
    /// themselves.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view, v !== g.view {
            if v is UIControl {
                return false
            }
            view = v.superview
        }
        return true
    }

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

/// SpeedHold is a press and hold on the video as it goes, and what the last
/// one did, for SpeedHint to show.
@MainActor @Observable
final class SpeedHold {
    var active = false
    /// Whether the finger has swiped far enough that letting go flips the
    /// lock.
    var swiped = false
    /// What the last hold changed, said for a moment after.
    var done: String?
}
