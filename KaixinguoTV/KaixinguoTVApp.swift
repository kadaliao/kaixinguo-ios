import AVFoundation
import KaixinguoKit
import SwiftUI

/// 开心果 on Apple TV: the same catalog, player and tabs as on iPhone and
/// iPad, from KaixinguoKit, with views made for the remote.
@main
struct KaixinguoTVApp: App {
    @State private var model: AppModel?
    @State private var startError = ""
    @State private var router: Router
    @Environment(\.scenePhase) private var phase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let router = Router()
        _router = State(initialValue: router)
        do {
            let model = try AppModel.live()
            if !Router.launchFresh, let s = model.lastSession() {
                router.restore(s)
                model.restore(s)
            }
            router.keep(model)
            _model = State(initialValue: model)
        } catch {
            _startError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                TVRootView()
                    .environment(model)
                    .environment(router)
                    #if DEBUG
                    // `-KXOpen kaixinguo://…` at launch opens the link: how
                    // screenshots and tests reach a page without a remote.
                    .task {
                        if let link = UserDefaults.standard.string(forKey: "KXOpen"), let url = URL(string: link) {
                            router.openLink(url, model)
                        }
                    }
                    #endif
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

/// TVRootView is the tabs along the top, the pages pushed in each, and the
/// player over everything.
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        let player = model.player
        TabView(selection: $router.tab) {
            Tab("推荐", systemImage: "house", value: Router.Tab.discover) {
                stack(.discover) { TVDiscoverView() }
            }
            Tab("排行榜", systemImage: "chart.bar", value: Router.Tab.rank) {
                stack(.rank) { TVRankView() }
            }
            Tab("新剧", systemImage: "calendar", value: Router.Tab.new) {
                stack(.new) { TVNewView() }
            }
            Tab("我的", systemImage: "star", value: Router.Tab.mine) {
                stack(.mine) { TVMineView() }
            }
            Tab(value: Router.Tab.search, role: .search) {
                stack(.search) { TVSearchView() }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { player.isPresented }, set: { if !$0 { player.leave() } })) {
            TVPlayerView()
                .environment(model)
                .environment(router)
        }
    }

    private func stack(_ tab: Router.Tab, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: router.path(tab)) {
            root().navigationDestination(for: Route.self) { route in
                switch route {
                case .series(let id):
                    TVSeriesView(id: id)
                }
            }
        }
    }
}
