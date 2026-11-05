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
    let sources: [URL]
    let key: [UInt8]?
    let queue = DispatchQueue(label: "kaixinguo.stream")
    private var session: URLSession!
    private let headSession: URLSession

    // On the queue.
    private var file: (size: Int64, layout: Layout?)?
    private var failure: Error?
    private var preparing = false
    private var waiting: [AVAssetResourceLoadingRequest] = []
    private var transfers: [Int: Transfer] = [:] // by task identifier
    private var good = 0 // the source that answered
    private var invalidated = false

    /// A range a loading request wants, on its way from the CDN.
    private final class Transfer {
        let request: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        let source: Int
        var next: Int64 // where the next byte that arrives belongs
        let end: Int64 // past the last byte wanted
        var skip: Int64 = 0 // bytes to drop from a CDN that sent the whole file
        let tries: Int // downloads of this range that broke off before

        init(request: AVAssetResourceLoadingRequest, task: URLSessionDataTask, source: Int, start: Int64, end: Int64,
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
        url = URL(string: "\(Self.scheme)://episode/\(UUID().uuidString).mp4")!
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
            session.invalidateAndCancel()
            headSession.invalidateAndCancel()
        }
    }

    // MARK: - Learning the file

    /// Learns the file's size and, for an encrypted one, its layout, then
    /// serves the requests that waited for them.
    private func prepare() {
        guard !preparing else { return }
        preparing = true
        let sources = sources, key = key
        Task {
            var outcome: Result<(Int64, Layout?, Int), Error> = .failure(AppError("没有视频地址"))
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
                    outcome = .success((total, layout, i))
                    break
                } catch {
                    debugLog("stream: \(source.host() ?? ""): \(error)")
                    outcome = .failure(error)
                }
            }
            queue.async { [self, outcome] in
                preparing = false
                switch outcome {
                case .success(let (size, layout, i)):
                    file = (size, layout)
                    good = i
                    let reqs = waiting
                    waiting = []
                    for r in reqs where !r.isCancelled {
                        serve(r)
                    }
                case .failure(let error):
                    failure = error
                    let reqs = waiting
                    waiting = []
                    for r in reqs where !r.isCancelled {
                        r.finishLoading(with: error)
                    }
                }
            }
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
        if start >= end {
            req.finishLoading()
            return
        }
        transfer(req, from: start, to: end, source: good)
    }

    private func transfer(_ req: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64, source: Int,
                          tries: Int = 0) {
        var r = URLRequest(url: sources[source])
        r.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: r)
        transfers[task.taskIdentifier] = Transfer(request: req, task: task, source: source, start: start, end: end,
                                                     tries: tries)
        task.resume()
    }
}

extension StreamLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard req.request.url?.scheme == Self.scheme, !invalidated else { return false }
        if file != nil {
            serve(req)
        } else if let failure {
            req.finishLoading(with: failure)
        } else {
            waiting.append(req)
            prepare()
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel req: AVAssetResourceLoadingRequest) {
        waiting.removeAll { $0 === req }
        for (id, t) in transfers where t.request === req {
            t.task.cancel()
            transfers[id] = nil
        }
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
        t.request.dataRequest?.respond(with: chunk)
        t.next += Int64(chunk.count)
        good = t.source
        if t.next >= t.end {
            transfers[dataTask.taskIdentifier] = nil
            dataTask.cancel() // a CDN that sent the whole file sends more
            t.request.finishLoading()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = transfers.removeValue(forKey: task.taskIdentifier), !t.request.isCancelled else { return }
        if t.next >= t.end {
            t.request.finishLoading()
            return
        }
        // The download broke off, or never started: go on from where it
        // stopped, from the other source when there is one.
        if t.tries < 2 && !invalidated {
            let other = (t.source + 1) % sources.count
            transfer(t.request, from: t.next, to: t.end, source: other, tries: t.tries + 1)
            return
        }
        t.request.finishLoading(with: error ?? AppError("视频下载中断"))
    }
}

/// The file's size from a response to a range request.
private func totalSize(_ http: HTTPURLResponse) -> Int64? {
    if let cr = http.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
        return Int64(cr[cr.index(after: slash)...])
    }
    return http.expectedContentLength > 0 ? http.expectedContentLength : nil
}
