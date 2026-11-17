import KaixinguoKit
import SwiftUI

/// Route is a page a tab's stack can push.
enum Route: Hashable {
    case series(String)
}

/// Router is where the viewer is: the tab, and the pages pushed in each.
@MainActor @Observable
final class Router {
    enum Tab: String, Hashable {
        case discover, rank, new, mine, search
    }

    var tab: Tab = .discover
    var paths: [Tab: [Route]] = [:]
    /// What the search field holds, and the search whose results show.
    var searchText = ""
    var searchQuery = ""

    func path(_ t: Tab) -> Binding<[Route]> {
        Binding(get: { self.paths[t] ?? [] }, set: { self.paths[t] = $0 })
    }

    /// Pushes the page in the tab showing.
    func open(_ r: Route) {
        paths[tab, default: []].append(r)
    }

    /// Shows the page in place of the one on top, as another season of
    /// the same series: Back still leaves the series.
    func replaceTop(_ r: Route) {
        var p = paths[tab] ?? []
        if p.isEmpty {
            p.append(r)
        } else {
            p[p.count - 1] = r
        }
        paths[tab] = p
    }

    /// Shows the results for q in the search tab.
    func search(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchText = q
        searchQuery = q
    }

    func back() {
        if paths[tab]?.isEmpty == false {
            paths[tab]?.removeLast()
        }
    }
}

extension Router {
    /// Where the viewer is, the model's part included, to open there again
    /// on the next launch.
    func session(_ model: AppModel) -> Session {
        var s = model.session
        s.tab = tab.rawValue
        for (t, path) in paths where !path.isEmpty {
            s.pages[t.rawValue] = path.map { r in
                switch r {
                case .series(let id): id
                }
            }
        }
        s.searchText = searchText
        s.searchQuery = searchQuery
        return s
    }

    /// Opens the tab, the pages and the search the session had open.
    func restore(_ s: Session) {
        tab = Tab(rawValue: s.tab) ?? .discover
        for (name, ids) in s.pages {
            if let t = Tab(rawValue: name) {
                paths[t] = ids.map(Route.series)
            }
        }
        searchText = s.searchText
        searchQuery = s.searchQuery
    }
}

extension Router {
    /// Saves where the viewer is each time it changes, so the next launch
    /// opens there again: the pages, and the episode, even as picture in
    /// picture goes on to the next one with the app in the background.
    func keep(_ model: AppModel) {
        let s = withObservationTracking {
            session(model)
        } onChange: {
            Task { @MainActor in self.keep(model) }
        }
        model.save(s)
    }

    /// Whether to open as on the first launch, rather than where the last
    /// one left off: for the interface tests, and for screenshots, which
    /// open a link of their own.
    static var launchFresh: Bool {
        #if DEBUG
        let d = UserDefaults.standard
        return d.bool(forKey: "KXFresh") || d.string(forKey: "KXOpen") != nil
        #else
        false
        #endif
    }

    /// Opens a link: kaixinguo://series/<id>, kaixinguo://play/<id>?episode=<n>,
    /// kaixinguo://search?q=<words>, or a tab, as kaixinguo://rank.
    func openLink(_ url: URL, _ model: AppModel) {
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
            if let id { open(.series(id)) }
        case "play":
            guard let id else { return }
            if let n = query.first(where: { $0.name == "episode" })?.value.flatMap(Int.init) {
                model.player.play(id, n)
            } else {
                model.playSeason(id)
            }
        case "discover": tab = .discover
        case "rank": tab = .rank
        case "new": tab = .new
        case "mine": tab = .mine
        case "search":
            tab = .search
            if let q = query.first(where: { $0.name == "q" })?.value { search(q) }
        default:
            break
        }
    }
}
