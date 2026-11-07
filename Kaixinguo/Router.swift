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
