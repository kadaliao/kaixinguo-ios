import AVFoundation
import KaixinguoKit
import SwiftUI

/// 开心果 on Apple TV: the same catalog and player as on iPhone and iPad,
/// from KaixinguoKit, with views made for the remote.
@main
struct KaixinguoTVApp: App {
    @State private var model: AppModel?
    @State private var startError = ""
    @Environment(\.scenePhase) private var phase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        do {
            _model = State(initialValue: try AppModel.live())
        } catch {
            _startError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                TVRootView()
                    .environment(model)
            } else {
                ContentUnavailableView("开心果打不开", systemImage: "exclamationmark.triangle", description: Text(startError))
            }
        }
        .onChange(of: phase) {
            if phase != .active {
                model?.player.recordProgress()
            }
            if phase == .background {
                model?.flush()
            }
        }
    }
}

/// SeriesRoute is a series' page, pushed onto the stack.
struct SeriesRoute: Hashable {
    let id: String
}

/// TVRootView is the recommended series, the pages pushed over them, and
/// the player over everything.
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [SeriesRoute] = []

    var body: some View {
        let player = model.player
        NavigationStack(path: $path) {
            TVDiscoverView()
                .navigationDestination(for: SeriesRoute.self) { TVSeriesView(id: $0.id) }
        }
        .fullScreenCover(isPresented: Binding(get: { player.isPresented }, set: { if !$0 { player.leave() } })) {
            TVPlayerView()
                .environment(model)
        }
        #if DEBUG
        // `-KXOpen kaixinguo://series/<id>` or `kaixinguo://play/<id>?episode=<n>`
        // at launch goes straight there: how screenshots and tests reach a
        // page without a remote.
        .task {
            if let link = UserDefaults.standard.string(forKey: "KXOpen"), let url = URL(string: link) {
                open(url)
            }
        }
        #endif
    }

    #if DEBUG
    private func open(_ url: URL) {
        guard url.scheme == "kaixinguo", let id = url.pathComponents.dropFirst().first else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host() {
        case "series":
            path.append(SeriesRoute(id: id))
        case "play":
            if let n = query.first(where: { $0.name == "episode" })?.value.flatMap(Int.init) {
                model.player.play(id, n)
            } else {
                model.playSeason(id)
            }
        default:
            break
        }
    }
    #endif
}
