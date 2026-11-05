import KaixinguoKit
import SwiftUI

/// RootView is the app's tabs: a tab bar on iPhone, a sidebar on iPad.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        @Bindable var player = model.player
        TabView(selection: $router.tab) {
            Tab("推荐", systemImage: "house", value: Router.Tab.discover) {
                stack(.discover) { DiscoverView() }
            }
            Tab("排行榜", systemImage: "chart.bar", value: Router.Tab.rank) {
                stack(.rank) { RankView() }
            }
            Tab("新剧", systemImage: "calendar", value: Router.Tab.new) {
                stack(.new) { NewReleasesView() }
            }
            Tab("我的", systemImage: "star", value: Router.Tab.mine) {
                stack(.mine) { MineView() }
            }
            Tab(value: Router.Tab.search, role: .search) {
                stack(.search) { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .fullScreenCover(isPresented: Binding(get: { player.isPresented }, set: { if !$0 { player.leave() } })) {
            PlayerScreen()
                .environment(model)
                .environment(router)
        }
    }

    private func stack(_ tab: Router.Tab, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: router.path(tab)) {
            root().navigationDestination(for: Route.self) { route in
                switch route {
                case .series(let id):
                    SeriesView(id: id)
                }
            }
        }
    }
}
