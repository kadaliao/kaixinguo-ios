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
    func seasons(_ seriesId: String) async throws -> Album
    func shortRank(_ query: ShortRankQuery) async throws -> ShortRanking
    func resolvePlayback(_ episodeId: String) async throws -> PlaybackResult
}

extension OpenhongguoClient: Catalog {}

extension OpenhongguoClient {
    /// The client the app uses, its anonymous device kept in Application
    /// Support. KX_DEBUG in the environment logs each request.
    public static func app() throws -> OpenhongguoClient {
        var options = ClientOptions(retryAttempts: 3, deviceResets: 3)
        if ProcessInfo.processInfo.environment["KX_DEBUG"] != nil {
            options.logger = { print("sdk:", $0) }
        }
        return try create(options: options)
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
        case .challengeRequired, .deviceRejected:
            return "服务器暂时拒绝了请求，请稍后再试"
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
