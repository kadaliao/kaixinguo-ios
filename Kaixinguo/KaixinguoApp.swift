import AVFoundation
import KaixinguoKit
import SwiftUI

@main
struct KaixinguoApp: App {
    @State private var model: AppModel?
    @State private var startError = ""
    @State private var router = Router()
    @Environment(\.scenePhase) private var phase

    init() {
        // Play with the ringer off, and on in picture in picture.
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
