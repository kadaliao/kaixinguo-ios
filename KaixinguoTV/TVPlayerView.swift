import AVKit
import KaixinguoKit
import SwiftUI

/// TVPlayerView is the episode playing, in the system's player with its
/// own controls: the remote scrubs and pauses, swiping down shows the
/// episode's info, and Menu leaves.
struct TVPlayerView: View {
    @Environment(AppModel.self) private var model

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
                    Button("重试") { player.retry() }
                }
            } else {
                SystemPlayer(player: player, next: player.hasNext ? player.number + 1 : nil)
                    .ignoresSafeArea()
                if player.state == .resolving {
                    ProgressView()
                }
            }
        }
    }
}

/// SystemPlayer is the system's player view controller, playing the
/// player's AVPlayer, with a button to the next episode while there is
/// one.
private struct SystemPlayer: UIViewControllerRepresentable {
    let player: Player
    /// The next episode's number, if there is a next one; nil otherwise.
    let next: Int?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player.av
        vc.allowsPictureInPicturePlayback = false
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        guard next != nil else {
            vc.contextualActions = []
            return
        }
        let player = player
        vc.contextualActions = [
            UIAction(title: "下一集", image: UIImage(systemName: "forward.end.fill")) { _ in
                player.step(1)
            },
        ]
    }
}
