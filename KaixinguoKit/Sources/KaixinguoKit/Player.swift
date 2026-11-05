import AVFoundation
import Foundation
import Observation
import Openhongguo
#if os(iOS)
import AVKit // AVPlayerItem.externalMetadata
import MediaPlayer
#endif

/// Player is the episode the player shows, and the AVPlayer that plays it.
/// It belongs to the main actor.
@MainActor @Observable
public final class Player {
    public enum State: Equatable {
        case idle
        case resolving // finding the episode's file
        case buffering // the video loads
        case playing
        case failed(String)
    }

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored public let av = AVPlayer()

    public private(set) var seriesID: String?
    public private(set) var number = 0
    public private(set) var state: State = .idle
    /// Whether the player's screen shows.
    public var isPresented = false
    /// Whether picture in picture shows the video, so leaving the screen
    /// keeps it playing.
    public var inPictureInPicture = false

    @ObservationIgnored var start: Double = 0 // where to start, in seconds
    @ObservationIgnored var gen = 0 // tells this start from later ones
    @ObservationIgnored var pending = false // waits for the series to load
    @ObservationIgnored var episodeID = "" // the episode the item plays
    @ObservationIgnored var seekOnReady: Double = 0
    @ObservationIgnored var futures: [String: Future] = [:]
    @ObservationIgnored var loaders: [StreamLoader] = []
    @ObservationIgnored var itemStatus: NSKeyValueObservation?
    @ObservationIgnored var observers: [Any] = []

    /// Future is an episode's playback model being resolved, shared by the
    /// start of the episode and the prefetch before it.
    @MainActor final class Future {
        var task: Task<PlaybackResult, Error>!
        var outcome: Result<PlaybackResult, Error>?
    }

    init(app: AppModel) {
        self.app = app
        av.allowsExternalPlayback = false // AirPlay can't fetch from the loader
        observe()
    }

    /// The series playing, once its page has loaded.
    public var page: SeriesPage? {
        seriesID.map { app.seriesEntry($0) }
    }

    // MARK: - Starting an episode

    /// Opens the player on episode n of the series, from start seconds in.
    public func play(_ seriesID: String, _ n: Int, start: Double = 0) {
        gen += 1
        self.seriesID = seriesID
        number = n
        self.start = start
        pending = false
        state = .resolving
        // In picture in picture the next episode plays in the window, and
        // the old one stays until it does: taking it away ends the window.
        if !inPictureInPicture {
            isPresented = true
        }
        stopItem(keep: inPictureInPicture)
        let sp = app.seriesEntry(seriesID)
        guard sp.series != nil else {
            pending = true // fillPending starts it
            if !sp.loading {
                app.loadSeries(sp)
            }
            return
        }
        startEpisode(sp)
    }

    /// Starts the episode that waited for its series, or says why it
    /// can't.
    func fillPending(_ sp: SeriesPage) {
        guard pending, seriesID == sp.id else { return }
        pending = false
        if sp.series == nil {
            state = .failed(friendly(sp.error))
            return
        }
        startEpisode(sp)
    }

    func startEpisode(_ sp: SeriesPage) {
        guard let ep = sp.episode(number) else {
            state = .failed("没有第 \(number) 集")
            return
        }
        guard ep.playable else {
            state = .failed("这一集需要登录才能观看")
            return
        }
        guard !sp.isBook else {
            state = .failed("这是小说或有声书，不能播放")
            return
        }
        state = .resolving
        sp.reveal(number)
        record(sp, number, position: start, duration: 0, finished: false)
        let gen = gen, start = start
        let f = resolve(ep)
        Task {
            let result = await f.task.result
            guard self.gen == gen else { return }
            do {
                let item = try makeItem(result.get(), sp, ep)
                state = .buffering
                episodeID = ep.id
                seekOnReady = start
                watch(item)
                av.replaceCurrentItem(with: item)
                av.play()
            } catch {
                state = .failed(friendly(error))
                futures[ep.id] = nil // try afresh next time
            }
        }
    }

    /// The episode's playback model, resolving it unless a prefetch did or
    /// is doing it.
    func resolve(_ ep: Episode) -> Future {
        if let f = futures[ep.id] {
            switch f.outcome {
            case nil:
                return f
            case .success(let r) where !expired(r.playback):
                return f
            default:
                break
            }
        }
        let f = Future()
        let catalog = app.catalog, id = ep.id
        f.task = Task {
            do {
                let r = try await catalog.resolvePlayback(id)
                f.outcome = .success(r)
                return r
            } catch {
                f.outcome = .failure(error)
                throw error
            }
        }
        futures[ep.id] = f
        return f
    }

    /// The item that plays the best stream of the model, decrypting it
    /// with its key.
    func makeItem(_ r: PlaybackResult, _ sp: SeriesPage, _ ep: Episode) throws -> AVPlayerItem {
        let pb = r.playback
        guard let s = bestStream(pb.streams), let url = URL(string: s.url) else {
            throw AppError("这一集没有可以播放的视频")
        }
        if s.hls || s.dash || !pb.audioUrl.isEmpty {
            throw AppError("暂不支持这种视频格式")
        }
        var key: [UInt8]?
        if pb.protected || s.protected {
            guard let k = r.contentKey else {
                throw r.contentKeyError ?? AppError("无法解密这一集")
            }
            key = hexBytes(k.key)
            guard key?.count == 16 else { throw AppError("无法解密这一集") }
        }
        var sources = [url]
        if let backup = URL(string: s.backupUrl), s.backupUrl != s.url {
            sources.append(backup)
        }
        let loader = StreamLoader(sources: sources, key: key)
        // Keep the last few: the one playing, and one the player may
        // still read.
        loaders.append(loader)
        while loaders.count > 3 {
            loaders.removeFirst().invalidate()
        }
        let item = AVPlayerItem(asset: loader.makeAsset())
        #if os(iOS)
        item.externalMetadata = metadata(sp, ep)
        #endif
        return item
    }

    /// Lets the episode go, as another starts; `keep` leaves it on screen,
    /// paused, until the next replaces it.
    func stopItem(keep: Bool = false) {
        av.pause()
        itemStatus = nil
        episodeID = "" // what the old item does no longer counts
        if !keep {
            av.replaceCurrentItem(with: nil)
        }
    }

    // MARK: - Moving between episodes

    /// Plays the episode d after the one playing, if there is one.
    public func step(_ d: Int) {
        guard let sp = page else { return }
        if d > 0 {
            if let next = app.following(sp, number) {
                play(next.seriesID, next.number)
            }
        } else if sp.episode(number + d) != nil {
            play(sp.id, number + d)
        }
    }

    public var hasNext: Bool {
        guard let sp = page else { return false }
        return app.following(sp, number) != nil
    }

    public var hasPrevious: Bool {
        page?.episode(number - 1) != nil
    }

    /// Tries the episode again, afresh, from where the viewer got to.
    public func retry() {
        guard let seriesID else { return }
        var from = start
        if let w = app.history.get(seriesID), w.episode == number, !w.finished {
            from = max(from, w.position - 3)
        }
        play(seriesID, number, start: from)
    }

    /// Pauses, as the viewer leaves the player, unless picture in picture
    /// goes on showing it. An episode still on its way won't start.
    public func leave() {
        isPresented = false
        guard !inPictureInPicture else { return }
        av.pause()
        if state == .resolving {
            gen += 1
            pending = false
            state = .idle
        }
    }

    // MARK: - What the video does

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let item = self.av.currentItem, ObjectIdentifier(item) == id else { return }
                self.ended()
            }
        })
        observers.append(av.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        })
        observers.append(av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 3, preferredTimescale: 600),
                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.progress() }
        })
        #if os(iOS)
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.step(1) }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.step(-1) }
            return .success
        }
        #endif
    }

    private func watch(_ item: AVPlayerItem) {
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let id = ObjectIdentifier(item), status = item.status
            Task { @MainActor in self?.itemStatusChanged(id, status) }
        }
    }

    private func itemStatusChanged(_ id: ObjectIdentifier, _ status: AVPlayerItem.Status) {
        guard let item = av.currentItem, ObjectIdentifier(item) == id else { return }
        switch status {
        case .readyToPlay:
            if seekOnReady > 0 {
                av.seek(to: CMTime(seconds: seekOnReady, preferredTimescale: 600))
                seekOnReady = 0
            }
        case .failed:
            debugLog("player: \(String(describing: item.error))")
            state = .failed("视频加载失败，请重试")
            futures[episodeID] = nil
        default:
            break
        }
    }

    private func timeControlChanged() {
        guard !episodeID.isEmpty, let sp = page else { return }
        switch av.timeControlStatus {
        case .playing:
            if state != .playing {
                state = .playing
                prefetch(sp)
            }
        case .waitingToPlayAtSpecifiedRate:
            if state == .playing {
                state = .buffering
            }
        case .paused:
            progress()
        @unknown default:
            break
        }
    }

    /// Resolves the next episode while this one plays.
    private func prefetch(_ sp: SeriesPage) {
        if let next = sp.episode(number + 1), next.playable {
            _ = resolve(next)
        } else if let ns = sp.nextSeason() {
            _ = app.seriesPage(ns.seriesId) // its episodes, ready to go on
        }
    }

    private func progress() {
        guard !episodeID.isEmpty, let sp = page, let item = av.currentItem else { return }
        let t = item.currentTime().seconds
        guard t.isFinite, t > 0 else { return }
        let d = item.duration.seconds
        record(sp, number, position: t, duration: d.isFinite ? d : 0, finished: false)
    }

    /// On to the next episode, or the next season's first.
    private func ended() {
        guard let sp = page else { return }
        episodeID = "" // the pause that follows the end is no progress
        record(sp, number, position: 0, duration: 0, finished: true)
        if let next = app.following(sp, number) {
            play(next.seriesID, next.number)
        }
    }

    func record(_ sp: SeriesPage, _ n: Int, position: Double, duration: Double, finished: Bool) {
        guard let s = sp.series else { return }
        app.history.record(Watch(seriesID: sp.id, title: s.title, cover: s.coverUrl, episode: n, position: position,
                                 duration: duration, total: sp.episodes.count, finished: finished,
                                 watched: watchedEnough(position, duration, finished: finished) ? [n] : []))
    }

    #if os(iOS)
    /// What Now Playing and the lock screen show.
    private func metadata(_ sp: SeriesPage, _ ep: Episode) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m
        }
        var out = [
            item(.commonIdentifierTitle, (sp.series?.title ?? "") as NSString),
            item(.iTunesMetadataTrackSubTitle, "第 \(ep.number) 集" as NSString),
        ]
        if let cover = sp.series?.coverUrl, let jpeg = app.covers.jpegData(cover) {
            out.append(item(.commonIdentifierArtwork, jpeg as NSData))
        }
        return out
    }
    #endif
}

/// The best stream of a model: the tallest, then the richest.
func bestStream(_ streams: [Openhongguo.Stream]) -> Openhongguo.Stream? {
    func height(_ s: Openhongguo.Stream) -> Int {
        if s.height > 0 { return s.height }
        let digits = Int(s.definition.prefix { $0.isASCII && $0.isNumber }) ?? 0
        return digits > 0 ? digits : s.width
    }
    return streams.filter { !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
        .max { (height($0), $0.bitrate) < (height($1), $1.bitrate) }
}

/// Whether an episode counts as watched: played to its end, or nine tenths
/// of the way, since viewers often skip its last seconds for the next.
func watchedEnough(_ position: Double, _ duration: Double, finished: Bool) -> Bool {
    finished || (duration > 0 && position >= duration * 0.9)
}

/// Whether the model's CDN URLs expire within a minute.
func expired(_ pb: Playback) -> Bool {
    pb.expiresAt > 0 && Date(timeIntervalSince1970: TimeInterval(pb.expiresAt)) < Date().addingTimeInterval(60)
}

func hexBytes(_ s: String) -> [UInt8] {
    let chars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines))
    guard chars.count % 2 == 0 else { return [] }
    var out: [UInt8] = []
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return [] }
        out.append(b)
    }
    return out
}
