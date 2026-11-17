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
                RootView()
                    .environment(model)
                    .environment(router)
                    .onOpenURL { router.openLink($0, model) }
                    #if DEBUG
                    // `-KXOpen kaixinguo://…` at launch opens the link, without the
                    // system asking first: how the screenshots get to each page.
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
}

/// AppDelegate tells the system which ways the screen may turn: just the
/// one the player's button turned it to, while that holds.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Rotation.shared.mask
    }
}
