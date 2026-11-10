import AVFoundation
import KaixinguoKit
import SwiftUI

@main
struct KaixinguoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel?
    @State private var startError = ""
    @State private var router: Router
    @Environment(\.scenePhase) private var phase

    init() {
        // Play with the ringer off, and on in picture in picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let router = Router()
        _router = State(initialValue: router)
        do {
            let model = try AppModel.live()
            if !Self.fresh, let s = model.lastSession() {
                router.restore(s)
                model.restore(s)
            }
            Self.keep(model, router)
            _model = State(initialValue: model)
        } catch {
            _startError = State(initialValue: error.localizedDescription)
        }
    }

    /// Saves where the viewer is each time it changes, so the next launch
    /// opens there again: the pages, and the episode, even as picture in
    /// picture goes on to the next one with the app in the background.
    private static func keep(_ model: AppModel, _ router: Router) {
        let s = withObservationTracking {
            router.session(model)
        } onChange: {
            Task { @MainActor in keep(model, router) }
        }
        model.save(s)
    }

    /// Whether to open as on the first launch, rather than where the last
    /// one left off: for the interface tests, and for screenshots, which
    /// open a link of their own.
    private static var fresh: Bool {
        #if DEBUG
        let d = UserDefaults.standard
        return d.bool(forKey: "KXFresh") || d.string(forKey: "KXOpen") != nil
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .environment(router)
                    .onOpenURL { open($0, model) }
                    #if DEBUG
                    // `-KXOpen kaixinguo://…` at launch opens the link, without the
                    // system asking first: how the screenshots get to each page.
                    .task {
                        if let link = UserDefaults.standard.string(forKey: "KXOpen"), let url = URL(string: link) {
                            open(url, model)
                        }
                    }
                    #endif
            } else {
                ContentUnavailableView("开心果打不开", systemImage: "exclamationmark.triangle", description: Text(startError))
            }
        }
        .onChange(of: phase) {
            if phase != .active {
                model?.player.recordProgress() // to the second, should the app not come back
            }
            if phase == .background {
                model?.flush() // what was saved last reaches the disk
            }
        }
        .commands {
            CommandMenu("浏览") {
                Button("搜索") { router.tab = .search }
                    .keyboardShortcut("f")
                Button("返回") { router.back() }
                    .keyboardShortcut("[")
            }
        }
    }

    /// Opens a link: kaixinguo://series/<id>, kaixinguo://play/<id>?episode=<n>,
    /// kaixinguo://search?q=<words>, or a tab, as kaixinguo://rank.
    private func open(_ url: URL, _ model: AppModel) {
        guard url.scheme == "kaixinguo" else { return }
        let id = url.pathComponents.dropFirst().first
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // A link to a page shows it, rather than the player the app may
        // have opened again over it, where it was left.
        if url.host() != "play" && model.player.isPresented {
            model.player.leave()
        }
        switch url.host() {
        case "series":
            if let id { router.open(.series(id)) }
        case "play":
            guard let id else { return }
            if let n = query.first(where: { $0.name == "episode" })?.value.flatMap(Int.init) {
                model.player.play(id, n)
            } else {
                model.playSeason(id)
            }
        case "discover": router.tab = .discover
        case "rank": router.tab = .rank
        case "new": router.tab = .new
        case "mine": router.tab = .mine
        case "search":
            router.tab = .search
            if let q = query.first(where: { $0.name == "q" })?.value { router.search(q) }
        default:
            break
        }
    }
}

/// AppDelegate tells the system which ways the screen may turn: just the
/// one the player's button turned it to, while that holds.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Rotation.shared.mask
    }
}
