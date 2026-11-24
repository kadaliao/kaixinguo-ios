import Foundation
import Openhongguo

/// Catalog is what the app asks of the Hongguo SDK. OpenhongguoClient is
/// the real one; the tests have one that needs no network.
public protocol Catalog: Sendable {
    func discover(_ options: DiscoverOptions) async throws -> Page<SeriesSummary>
    func search(_ query: String, options: SearchOptions) async throws -> Page<SeriesSummary>
    func suggest(_ prefix: String) async throws -> [Suggestion]
    func hotSearch() async throws -> HotSearch
    func newReleases(_ query: NewReleaseQuery) async throws -> NewReleasePage
    func getSeries(_ seriesId: String) async throws -> Series
    func getSeriesBatch(_ seriesIds: [String]) async throws -> [SeriesDetail]
    func listEpisodes(_ seriesId: String, options: EpisodeOptions) async throws -> Page<Episode>
    func listDanmaku(_ seriesId: String, episodeId: String, options: DanmakuOptions) async throws -> DanmakuPage
    func seasons(_ seriesId: String) async throws -> Album
    func shortRank(_ query: ShortRankQuery) async throws -> ShortRanking
    func resolvePlayback(_ episodeId: String) async throws -> PlaybackResult
}

extension OpenhongguoClient: Catalog {}

extension OpenhongguoClient {
    /// The client the app uses, its anonymous device kept in profile, or
    /// in Application Support when nil. It signs with the SDK's built-in
    /// signing, or with the signing service signer when its URL is set.
    /// KX_DEBUG in the environment logs each request.
    public static func app(profile: URL? = nil, signer: SignerSettings = SignerSettings()) throws -> OpenhongguoClient {
        var options = ClientOptions(retryAttempts: 3, deviceResets: 3)
        if !signer.url.isEmpty {
            options.signerUrl = signer.url
            options.signerToken = signer.token.isEmpty ? nil : signer.token
        }
        if ProcessInfo.processInfo.environment["KX_DEBUG"] != nil {
            let tag = signer.url.isEmpty ? "sdk:" : "sdk (signer):"
            options.logger = { print(tag, $0) }
        }
        return try create(profile: profile, options: options)
    }
}

/// Says what went wrong in the viewer's words.
public func friendly(_ error: Error?) -> String {
    guard let error else { return "" }
    if let e = error as? OpenhongguoError {
        switch e.code {
        case .transport:
            return "网络连接不稳定，请稍后重试"
        case .rateLimited:
            return "请求太频繁，请稍等片刻再试"
        case .anonymousLimited:
            return "这一集暂时无法匿名播放，可以稍后再试"
        case .authenticationRequired:
            return "这一集需要登录才能观看"
        case .contentUnavailable, .albumUnavailable:
            return "内容已下架或不存在"
        case .challengeRequired, .deviceRejected, .signatureRejected:
            return "服务器暂时拒绝了请求，请稍后再试"
        case .signerUnavailable:
            return "签名服务暂时连不上，请稍后再试"
        default:
            return e.message
        }
    }
    if error is URLError {
        return "网络连接不稳定，请稍后重试"
    }
    return error.localizedDescription
}

/// AppError is a failure the app itself describes.
public struct AppError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

func isCode(_ error: Error, _ codes: ErrorCode...) -> Bool {
    guard let e = error as? OpenhongguoError else { return false }
    return codes.contains(e.code)
}
