import Foundation
import Openhongguo
import Security
import Synchronization

/// FallbackCatalog asks the SDK's client, which signs with the SDK's
/// built-in signing. Playback, which the server's changes to signing broke
/// each time, can fall back to an openhongguo-signer service the viewer set
/// up: when the built-in signing gets nothing back and the service gets an
/// answer, playback uses the service for a while. Everything else always
/// goes to the built-in signing, so an empty answer that is just empty, like
/// a search with no hits, never reaches the service. The two clients keep
/// separate anonymous devices, so a device reset on one does not overwrite
/// the other's.
public final class FallbackCatalog: Catalog {
    /// How long playback keeps signing with the service after the built-in
    /// signing failed where the service succeeded, before trying the
    /// built-in signing again.
    static let remoteFor: TimeInterval = 30 * 60

    let local: any Catalog
    private let store: SignerStore
    private let makeRemote: @Sendable (SignerSettings) throws -> any Catalog
    private let now: @Sendable () -> Date

    private struct State {
        var settings = SignerSettings()
        var remote: (any Catalog)?
        var until = Date.distantPast // remote first until then
    }
    private let state = Mutex(State())

    /// A catalog that signs with local's built-in signing, and whose
    /// playback falls back to the service store keeps, made by makeRemote.
    public init(local: any Catalog, store: SignerStore,
                now: @escaping @Sendable () -> Date = Date.init,
                makeRemote: @escaping @Sendable (SignerSettings) throws -> any Catalog) {
        self.local = local
        self.store = store
        self.now = now
        self.makeRemote = makeRemote
        let s = store.load()
        // A service that cannot be made is as good as none until the viewer
        // sets it again.
        try? install(s)
    }

    /// The signing service playback falls back to; an empty URL for none.
    public var settings: SignerSettings { state.withLock { $0.settings } }

    /// Saves s and has playback fall back to its service from now on, or to
    /// none when its URL is empty.
    public func apply(_ s: SignerSettings) throws {
        var s = s
        s.url = s.url.trimmingCharacters(in: .whitespacesAndNewlines)
        s.token = s.url.isEmpty ? "" : s.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try s.url.isEmpty ? nil : makeRemote(s)
        try store.save(s)
        state.withLock { $0 = State(settings: s, remote: remote) }
    }

    private func install(_ s: SignerSettings) throws {
        let remote = try s.url.isEmpty ? nil : makeRemote(s)
        state.withLock { $0 = State(settings: s, remote: remote) }
    }

    /// Whether playback goes to the service first now.
    var remoteFirst: Bool {
        let t = now()
        return state.withLock { $0.remote != nil && t < $0.until }
    }

    /// The catalogs to ask, in turn: the one whose signing worked last first,
    /// and nil for no second.
    private func order() -> (first: any Catalog, second: (any Catalog)?, remoteFirst: Bool) {
        let t = now()
        return state.withLock {
            if let r = $0.remote, t < $0.until {
                return (r, local, true)
            }
            return (local, $0.remote, false)
        }
    }

    /// Notes that the service's signing got the answer where the built-in
    /// signing did not, or the other way around.
    private func worked(remote: Bool) {
        let t = now()
        state.withLock { $0.until = remote ? t.addingTimeInterval(Self.remoteFor) : .distantPast }
    }

    /// Runs f with the catalog whose signing works now. When both fail, the
    /// error is the built-in signing's: a service that is down is no news
    /// to a viewer whose built-in signing has its own reason.
    func call<T: Sendable>(_ f: @Sendable (any Catalog) async throws -> T) async throws -> T {
        let (first, other, remoteFirst) = order()
        let firstError: Error
        do {
            return try await f(first)
        } catch {
            guard other != nil, signingFailed(error) || isCode(error, .signerUnavailable) else { throw error }
            firstError = error
        }
        guard let second = other else { throw firstError }
        log(firstError)
        do {
            let v = try await f(second)
            worked(remote: !remoteFirst)
            return v
        } catch {
            log(error)
            throw remoteFirst ? error : firstError
        }
    }

    private func log(_ error: Error) {
        if isCode(error, .signerUnavailable), ProcessInfo.processInfo.environment["KX_DEBUG"] != nil {
            print("signer:", error)
        }
    }

    // MARK: - Catalog

    public func resolvePlayback(_ episodeId: String) async throws -> PlaybackResult {
        try await call { try await $0.resolvePlayback(episodeId) }
    }

    public func discover(_ options: DiscoverOptions) async throws -> Page<SeriesSummary> {
        try await local.discover(options)
    }
    public func search(_ query: String, options: SearchOptions) async throws -> Page<SeriesSummary> {
        try await local.search(query, options: options)
    }
    public func suggest(_ prefix: String) async throws -> [Suggestion] { try await local.suggest(prefix) }
    public func hotSearch() async throws -> HotSearch { try await local.hotSearch() }
    public func newReleases(_ query: NewReleaseQuery) async throws -> NewReleasePage {
        try await local.newReleases(query)
    }
    public func getSeries(_ seriesId: String) async throws -> Series { try await local.getSeries(seriesId) }
    public func getSeriesBatch(_ seriesIds: [String]) async throws -> [SeriesDetail] {
        try await local.getSeriesBatch(seriesIds)
    }
    public func listEpisodes(_ seriesId: String, options: EpisodeOptions) async throws -> Page<Episode> {
        try await local.listEpisodes(seriesId, options: options)
    }
    public func listDanmaku(_ seriesId: String, episodeId: String, options: DanmakuOptions) async throws -> DanmakuPage {
        try await local.listDanmaku(seriesId, episodeId: episodeId, options: options)
    }
    public func seasons(_ seriesId: String) async throws -> Album { try await local.seasons(seriesId) }
    public func shortRank(_ query: ShortRankQuery) async throws -> ShortRanking { try await local.shortRank(query) }
}

/// Reports an error the built-in signing may be behind: when the server
/// stops accepting it, requests come back empty or rejected.
func signingFailed(_ error: Error) -> Bool {
    isCode(error, .anonymousLimited, .signatureRejected)
}

// MARK: - Settings

/// SignerSettings is the signing service playback falls back to: an
/// openhongguo-signer the viewer deployed, and its token if it has one.
public struct SignerSettings: Equatable, Sendable {
    public var url = ""
    public var token = ""

    public init(url: String = "", token: String = "") {
        self.url = url
        self.token = token
    }
}

/// SignerStore keeps the settings: the address in the defaults, the token,
/// a secret, in the keychain.
public struct SignerStore: Sendable {
    public var load: @Sendable () -> SignerSettings
    public var save: @Sendable (SignerSettings) throws -> Void

    public init(load: @escaping @Sendable () -> SignerSettings,
                save: @escaping @Sendable (SignerSettings) throws -> Void) {
        self.load = load
        self.save = save
    }

    /// The app's own: the defaults and the keychain.
    public static let standard = SignerStore(
        load: {
            let url = UserDefaults.standard.string(forKey: "signer_url") ?? ""
            return SignerSettings(url: url, token: url.isEmpty ? "" : Keychain.read(account: "signer_token"))
        },
        save: { s in
            try Keychain.write(s.token, account: "signer_token")
            if s.url.isEmpty {
                UserDefaults.standard.removeObject(forKey: "signer_url")
            } else {
                UserDefaults.standard.set(s.url, forKey: "signer_url")
            }
        })

    /// One that keeps the settings only while the process runs.
    public static func memory(_ initial: SignerSettings = SignerSettings()) -> SignerStore {
        let kept = Mutex(initial)
        return SignerStore(load: { kept.withLock { $0 } }, save: { s in kept.withLock { $0 = s } })
    }
}

/// Keychain holds the app's secrets as generic passwords, readable only
/// while the device is unlocked, and only on this device.
enum Keychain {
    static let service = "com.kadaliao.kaixinguo"

    static func read(account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keeps value, or deletes the secret when it is empty.
    static func write(_ value: String, account: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError("钥匙串保存失败（\(status)）")
        }
    }
}

extension OpenhongguoClient {
    /// The client that signs with the service s, its anonymous device kept
    /// in a file of its own next to the built-in signing's, profile.
    public static func signer(_ s: SignerSettings, beside profile: URL) throws -> OpenhongguoClient {
        let dir = profile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = profile.deletingPathExtension().lastPathComponent + "-signer.json"
        return try app(profile: dir.appendingPathComponent(name), signer: s)
    }
}

// MARK: - Checking a service

/// What is wrong with a service's address, or "".
public func checkSignerURL(_ raw: String) -> String {
    let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty {
        return ""
    }
    guard let u = URLComponents(string: raw), let scheme = u.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else {
        return "请填写以 http:// 或 https:// 开头的地址"
    }
    return ""
}

/// Asks the service at url whether it is ready to sign and takes token, and
/// says what went wrong if not.
public func probeSigner(_ url: String, token: String, session: URLSession = signerSession) async throws {
    var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
        base.removeLast()
    }
    guard let ready = URL(string: base + "/ready"), let hash = URL(string: base + "/feature-hash") else {
        throw AppError("请填写以 http:// 或 https:// 开头的地址")
    }
    struct Ready: Decodable { var ready = false }
    guard let (code, body) = try? await signerDo(session, URLRequest(url: ready)) else {
        throw AppError("连不上签名服务")
    }
    if code != 200 {
        throw AppError("这个地址不是签名服务（HTTP \(code)）")
    }
    if (try? JSONDecoder().decode(Ready.self, from: body))?.ready != true {
        throw AppError("签名服务还在启动，稍后再试")
    }
    // Signing nothing: the service checks the token before the request,
    // which it then refuses for having no URL.
    var req = URLRequest(url: hash)
    req.httpMethod = "POST"
    req.httpBody = Data("{}".utf8)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if !token.isEmpty {
        req.setValue(token, forHTTPHeaderField: "X-Signer-Token")
    }
    guard let (code, _) = try? await signerDo(session, req) else {
        throw AppError("连不上签名服务")
    }
    switch code {
    case 400:
        return
    case 401:
        throw AppError(token.isEmpty ? "签名服务要求填写 token" : "token 不对")
    default:
        throw AppError("签名服务返回 HTTP \(code)")
    }
}

/// The session the check uses: nothing kept, and an answer within 15 seconds.
public let signerSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 15
    c.timeoutIntervalForResource = 20
    return URLSession(configuration: c)
}()

private func signerDo(_ session: URLSession, _ req: URLRequest) async throws -> (Int, Data) {
    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (http.statusCode, data.prefix(1 << 16))
}
