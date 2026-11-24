import AVFoundation
import CENC
import Foundation
import UniformTypeIdentifiers

/// StreamLoader plays one episode's file on the CDN through AVFoundation.
/// The asset it makes has a URL of its own scheme, so AVFoundation asks the
/// loader for each byte range it wants; the loader downloads the range and
/// decrypts it in place as it streams, so playback starts at once and can
/// seek anywhere. It is the iOS app's counterpart of the macOS app's proxy.
///
/// Its state belongs to its queue, where AVFoundation and URLSession call
/// it. Call `invalidate` when done with it: URLSession holds its delegate
/// until then.
public final class StreamLoader: NSObject, @unchecked Sendable {
    static let scheme = "kaixinguo-stream"

    /// The URL the asset plays.
    public let url: URL
    /// What tells this loader's file from others, in its URLs.
    let id = UUID().uuidString
    let sources: [URL]
    let key: [UInt8]?
    let queue = DispatchQueue(label: "kaixinguo.stream")
    private var session: URLSession!
    private let headSession: URLSession

    // On the queue.
    private var file: (size: Int64, layout: Layout?)?
    private var failure: Error?
    private var preparing = false
    private var waiting: [Waiter] = []
    private var transfers: [Int: Transfer] = [:] // by task identifier
    private var good = 0 // the source that answered
    private var invalidated = false
    /// The file from its first byte, decrypted, as far as it has been read
    /// ahead: the head read to learn the file, and what `preload` adds.
    private var prefix = Data()
    private var preloading = false

    /// What waits for the file to be learned; `soft` for a read ahead,
    /// whose failure doesn't stop the episode trying again as it plays.
    private struct Waiter {
        let soft: Bool
        let then: (Result<Int64, Error>) -> Void
    }

    /// A range a sink wants, on its way from the CDN.
    private final class Transfer {
        let request: RangeSink
        let task: URLSessionDataTask
        let source: Int
        var next: Int64 // where the next byte that arrives belongs
        let end: Int64 // past the last byte wanted
        var skip: Int64 = 0 // bytes to drop from a CDN that sent the whole file
        let tries: Int // downloads of this range that broke off before

        init(request: RangeSink, task: URLSessionDataTask, source: Int, start: Int64, end: Int64,
             tries: Int) {
            self.request = request
            self.task = task
            self.source = source
            next = start
            self.end = end
            self.tries = tries
        }
    }

    /// Makes the file at `sources` (a CDN URL and its backup) playable;
    /// `key` decrypts it, and is nil for a clear file.
    public convenience init(sources: [URL], key: [UInt8]?) {
        self.init(sources: sources, key: key, configuration: .default)
    }

    init(sources: [URL], key: [UInt8]?, configuration config: URLSessionConfiguration) {
        self.sources = sources
        self.key = key
        url = URL(string: "\(Self.scheme)://episode/\(id).mp4")!
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        headSession = URLSession(configuration: config)
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    /// The asset to play. The asset holds the loader weakly: keep the
    /// loader while the asset plays.
    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Stops every download and lets the loader go.
    public func invalidate() {
        queue.async { [self] in
            invalidated = true
            for t in transfers.values {
                t.task.cancel()
            }
            transfers = [:]
            prefix = Data()
            session.invalidateAndCancel()
            headSession.invalidateAndCancel()
        }
    }

    // MARK: - Learning the file

    /// Calls `then` on the queue with the file's size, once it is known.
    private func withFile(soft: Bool = false, _ then: @escaping (Result<Int64, Error>) -> Void) {
        if let file {
            then(.success(file.size))
        } else if let failure {
            then(.failure(failure))
        } else {
            waiting.append(Waiter(soft: soft, then: then))
            prepare()
        }
    }

    /// Learns the file's size and, for an encrypted one, its layout, then
    /// serves what waited for them.
    private func prepare() {
        guard !preparing else { return }
        preparing = true
        let sources = sources, key = key
        Task {
            var outcome: Result<(Int64, Layout?, Int, [UInt8]), Error> = .failure(AppError("没有视频地址"))
            for (i, source) in sources.enumerated() {
                do {
                    let (head, total) = try await fetch(source, 0, 64 << 10 - 1)
                    var layout: Layout?
                    if let key {
                        layout = try await Layout.open(total: total, key: key) { [self] off, n in
                            if off + n <= Int64(head.count) {
                                return Array(head[Int(off)..<Int(off + n)])
                            }
                            return try await fetch(source, off, off + n - 1).0
                        }
                    }
                    outcome = .success((total, layout, i, head))
                    break
                } catch {
                    debugLog("stream: \(source.host() ?? ""): \(error)")
                    outcome = .failure(error)
                }
            }
            queue.async { [self, outcome] in
                preparing = false
                let ws = waiting
                waiting = []
                switch outcome {
                case .success(let (size, layout, i, head)):
                    file = (size, layout)
                    good = i
                    var clear = Data(head)
                    layout?.decrypt(&clear, at: 0)
                    if prefix.isEmpty {
                        prefix = clear
                    }
                    for w in ws {
                        w.then(.success(size))
                    }
                case .failure(let error):
                    // A read ahead that failed leaves the episode to try
                    // again as it plays.
                    if ws.contains(where: { !$0.soft }) {
                        failure = error
                    }
                    for w in ws {
                        w.then(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - Reading ahead

    /// Reads the file's first `bytes` ahead, decrypted, so the episode
    /// starts at once when it plays: what AVFoundation or a device on the
    /// network asks for of them is served from memory.
    public func preload(_ bytes: Int64) {
        queue.async { [self] in
            guard !invalidated, !preloading else { return }
            preloading = true
            withFile(soft: true) { [self] result in
                guard case .success(let size) = result, !invalidated else {
                    preloading = false
                    return
                }
                let from = Int64(prefix.count), to = min(size, bytes)
                guard from < to else {
                    preloading = false
                    return
                }
                let source = sources[good]
                Task {
                    let got = try? await fetch(source, from, to - 1).0
                    queue.async { [self] in
                        preloading = false
                        guard let got, !invalidated, Int64(prefix.count) == from else { return }
                        var clear = Data(got)
                        file?.layout?.decrypt(&clear, at: from)
                        prefix.append(clear)
                        debugLog("stream: read ahead \(prefix.count) bytes")
                    }
                }
            }
        }
    }

    /// How many bytes from the start are read ahead; for tests.
    func preloaded() async -> Int {
        await withCheckedContinuation { c in
            queue.async { [self] in c.resume(returning: prefix.count) }
        }
    }

    /// Reads bytes a to b of `source`, and the file's size.
    private func fetch(_ source: URL, _ a: Int64, _ b: Int64) async throws -> ([UInt8], Int64) {
        var req = URLRequest(url: source)
        req.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
        let (data, resp) = try await headSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AppError("CDN 没有回应") }
        switch http.statusCode {
        case 206:
            guard let total = totalSize(http), total > 0 else { throw AppError("CDN 没有告知文件大小") }
            return ([UInt8](data), total)
        case 200: // the whole file, the range ignored
            let all = [UInt8](data)
            guard Int64(all.count) > a else { throw AppError("CDN 返回的文件太短") }
            return (Array(all[Int(a)..<Int(min(b + 1, Int64(all.count)))]), Int64(all.count))
        default:
            throw AppError("CDN 返回 \(http.statusCode)")
        }
    }

    // MARK: - Serving ranges

    /// Serves what a loading request of AVFoundation's wants.
    private func serve(_ req: AVAssetResourceLoadingRequest) {
        guard let file else { return }
        guard !invalidated else {
            req.finishLoading(with: CancellationError())
            return
        }
        if let info = req.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            info.contentLength = file.size
            info.isByteRangeAccessSupported = true
        }
        guard let data = req.dataRequest else {
            req.finishLoading()
            return
        }
        let start = data.currentOffset
        let end = data.requestsAllDataToEndOfResource
            ? file.size : min(file.size, data.requestedOffset + Int64(data.requestedLength))
        read(LoadingSink(req), from: start, to: end)
    }

    /// Sends bytes start..<end of the file to `sink`: from memory as far as
    /// they were read ahead, the rest from the CDN.
    private func read(_ sink: RangeSink, from start: Int64, to end: Int64) {
        guard !invalidated else {
            sink.finish(CancellationError())
            return
        }
        var start = start
        if start < Int64(prefix.count), start < end {
            let upto = min(end, Int64(prefix.count))
            let more = sink.respond(prefix.subdata(in: Int(start)..<Int(upto)))
            start = upto
            if start < end && !more {
                sink.whenReady { [self, start] in
                    queue.async { [self] in
                        if !sink.isCancelled {
                            read(sink, from: start, to: end)
                        }
                    }
                }
                return
            }
        }
        if start >= end {
            sink.finish(nil)
            return
        }
        transfer(sink, from: start, to: end, source: good)
    }

    private func transfer(_ req: RangeSink, from start: Int64, to end: Int64, source: Int, tries: Int = 0) {
        var r = URLRequest(url: sources[source])
        r.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: r)
        transfers[task.taskIdentifier] = Transfer(request: req, task: task, source: source, start: start, end: end,
                                                     tries: tries)
        task.resume()
    }

    /// Stops what goes to `sink`, which no longer wants it.
    private func cancel(_ sink: RangeSink) {
        for (id, t) in transfers where t.request === sink || (t.request as? LoadingSink)?.matches(sink) == true {
            t.task.cancel()
            transfers[id] = nil
        }
    }

    // MARK: - Over HTTP

    /// Learns the file's size, on the queue, for a response over HTTP.
    func size(_ then: @escaping @Sendable (Result<Int64, Error>) -> Void) {
        queue.async { [self] in
            guard !invalidated else {
                then(.failure(CancellationError()))
                return
            }
            withFile { then($0) }
        }
    }

    /// Sends bytes start..<end of the file to a response over HTTP.
    func send(_ sink: RangeSink, from start: Int64, to end: Int64) {
        queue.async { [self] in
            withFile { [self] result in
                switch result {
                case .success:
                    if !sink.isCancelled {
                        read(sink, from: start, to: end)
                    }
                case .failure(let error):
                    sink.finish(error)
                }
            }
        }
    }

    /// Stops sending to a response over HTTP, whose client went away.
    func stop(_ sink: RangeSink) {
        queue.async { [self] in cancel(sink) }
    }
}

/// RangeSink is where a range of the file goes, as it arrives: a loading
/// request of AVFoundation's, or a response of `StreamServer`'s. The
/// loader calls it on its queue.
protocol RangeSink: AnyObject, Sendable {
    var isCancelled: Bool { get }
    /// Takes the next bytes; false when it holds enough not yet sent on,
    /// and the loader should wait for `whenReady` before sending more.
    func respond(_ data: Data) -> Bool
    /// Calls `ready`, on any queue, once it takes more again.
    func whenReady(_ ready: @escaping @Sendable () -> Void)
    func finish(_ error: Error?)
}

/// LoadingSink passes a range to the loading request that wants it.
private final class LoadingSink: RangeSink, @unchecked Sendable { // used on the loader's queue
    let req: AVAssetResourceLoadingRequest

    init(_ req: AVAssetResourceLoadingRequest) {
        self.req = req
    }

    var isCancelled: Bool { req.isCancelled }

    func respond(_ data: Data) -> Bool {
        req.dataRequest?.respond(with: data)
        return true
    }

    func whenReady(_ ready: @escaping @Sendable () -> Void) {
        ready()
    }

    func finish(_ error: Error?) {
        if let error {
            req.finishLoading(with: error)
        } else {
            req.finishLoading()
        }
    }

    func matches(_ other: RangeSink) -> Bool {
        (other as? LoadingSink)?.req === req
    }
}

extension StreamLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard req.request.url?.scheme == Self.scheme, !invalidated else { return false }
        withFile { [self] result in
            guard !req.isCancelled else { return }
            switch result {
            case .success:
                serve(req)
            case .failure(let error):
                req.finishLoading(with: error)
            }
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel req: AVAssetResourceLoadingRequest) {
        cancel(LoadingSink(req))
    }
}

extension StreamLoader: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let t = transfers[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            // The range must start where it was asked to.
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let first = cr.split(separator: " ").last?.split(separator: "-").first, Int64(first) != t.next {
                completionHandler(.cancel)
                return
            }
        case 200:
            t.skip = t.next
        default:
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let t = transfers[dataTask.taskIdentifier], !t.request.isCancelled else { return }
        var chunk = data
        if t.skip > 0 {
            let drop = Int(min(t.skip, Int64(chunk.count)))
            chunk = chunk.dropFirst(drop)
            t.skip -= Int64(drop)
        }
        chunk = Data(chunk.prefix(Int(t.end - t.next)))
        guard !chunk.isEmpty else { return }
        file?.layout?.decrypt(&chunk, at: t.next)
        let more = t.request.respond(chunk)
        t.next += Int64(chunk.count)
        good = t.source
        if t.next >= t.end {
            transfers[dataTask.taskIdentifier] = nil
            dataTask.cancel() // a CDN that sent the whole file sends more
            t.request.finish(nil)
        } else if !more {
            // Holds off the CDN until the sink has sent on what it holds.
            dataTask.suspend()
            t.request.whenReady { [weak dataTask] in dataTask?.resume() }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = transfers.removeValue(forKey: task.taskIdentifier), !t.request.isCancelled else { return }
        if t.next >= t.end {
            t.request.finish(nil)
            return
        }
        // The download broke off, or never started: go on from where it
        // stopped, from the other source when there is one.
        if t.tries < 2 && !invalidated {
            let other = (t.source + 1) % sources.count
            transfer(t.request, from: t.next, to: t.end, source: other, tries: t.tries + 1)
            return
        }
        t.request.finish(error ?? AppError("视频下载中断"))
    }
}

/// The file's size from a response to a range request.
private func totalSize(_ http: HTTPURLResponse) -> Int64? {
    if let cr = http.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
        return Int64(cr[cr.index(after: slash)...])
    }
    return http.expectedContentLength > 0 ? http.expectedContentLength : nil
}
