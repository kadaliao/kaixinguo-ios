import AVFoundation
import Foundation
import Openhongguo
import Synchronization
import Testing

@testable import KaixinguoKit

/// FixtureProtocol serves files from memory as a CDN would, a range at a
/// time, in pieces; a path it has no file for answers 404.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let files = Mutex<[String: Data]>([:])
    static let requests = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.requests.withLock { $0.append("\(url.path) \(range)") }
        guard let data = Self.files.withLock({ $0[url.path] }) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var a = 0, b = data.count - 1
        if let spec = range.split(separator: "=").last {
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            a = Int(parts[0]) ?? 0
            b = min(Int(parts[1]) ?? b, data.count - 1)
        }
        let body = data.subdata(in: a..<(b + 1))
        let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes \(a)-\(b)/\(data.count)", "Content-Length": "\(body.count)", "Content-Type": "video/mp4",
        ])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        var off = 0
        while off < body.count {
            let n = min(48 << 10, body.count - off)
            client?.urlProtocol(self, didLoad: body.subdata(in: off..<(off + n)))
            off += n
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Plays a real encrypted episode through the loader when CENC_SAMPLE names
/// one and CENC_KEY holds its key: AVFoundation reads it as a playable
/// MP4, decodes its frames, and plays it. The first source is broken, so
/// the backup serves it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CENC_SAMPLE"] != nil))
func playsEncryptedEpisode() async throws {
    let env = ProcessInfo.processInfo.environment
    let data = try Data(contentsOf: URL(fileURLWithPath: env["CENC_SAMPLE"]!))
    FixtureProtocol.files.withLock { $0["/ep.mp4"] = data }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let loader = StreamLoader(sources: [URL(string: "https://fixture.test/broken.mp4")!,
                                        URL(string: "https://fixture.test/ep.mp4")!],
                              key: hexBytes(env["CENC_KEY"] ?? ""), configuration: config)
    defer { loader.invalidate() }
    let asset = loader.makeAsset()
    let (playable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
    #expect(playable)
    #expect(duration.seconds > 10)
    #expect(tracks.contains { $0.mediaType == .video })

    let gen = AVAssetImageGenerator(asset: asset)
    let (frame, _) = try await gen.image(at: CMTime(seconds: duration.seconds / 2, preferredTimescale: 600))
    #expect(frame.width > 0)

    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    player.isMuted = true
    player.play()
    for _ in 0..<100 where player.currentTime().seconds < 1 {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(player.currentTime().seconds >= 1, "\(String(describing: player.currentItem?.error))")
    player.pause()

    // A seek far in reads from there, not from the start.
    FixtureProtocol.requests.withLock { $0 = [] }
    await player.seek(to: CMTime(seconds: duration.seconds - 20, preferredTimescale: 600))
    player.play()
    for _ in 0..<50 where player.currentTime().seconds < duration.seconds - 19 {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(player.currentTime().seconds >= duration.seconds - 19)
    player.pause()
}

/// Plays the first episode of a recommended series through the real SDK
/// and CDN, when KX_ONLINE is set: the whole way, from the anonymous
/// device to frames on screen, and the danmaku over them.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["KX_ONLINE"] != nil))
func playsOnline() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kxg-online-\(UUID().uuidString)")
    let client = try OpenhongguoClient.create(profile: dir.appendingPathComponent("anonymous.json"),
                                              options: ClientOptions(retryAttempts: 3, deviceResets: 3))
    let model = AppModel(catalog: client, dataDir: dir, cacheDir: dir)
    model.player.av.isMuted = true
    model.home.loadMore()
    for _ in 0..<600 where model.home.cards.isEmpty && model.home.error == nil {
        try await Task.sleep(for: .milliseconds(100))
    }
    let card = try #require(model.home.cards.first, "no recommendations: \(friendly(model.home.error))")
    model.player.play(card.id, 1)
    for _ in 0..<900 {
        if case .failed = model.player.state { break }
        if model.player.state == .playing && model.player.av.currentTime().seconds > 2 { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(model.player.state == .playing, "\(card.title): \(model.player.state)")
    #expect(model.player.av.currentTime().seconds > 2)
    #expect(model.history.get(card.id)?.episode == 1)

    // The episode's danmaku read to the last page; an episode may have none.
    let reel = try #require(model.player.danmaku())
    for _ in 0..<300 where reel.loading {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!reel.loading)
    #expect(reel.error == nil, "\(friendly(reel.error))")

    // The cover downloads, as HEIC, and keeps on disk.
    let cover = await model.covers.image(card.cover)
    #expect(cover != nil)
    #expect(model.covers.jpegData(card.cover) != nil)
}
