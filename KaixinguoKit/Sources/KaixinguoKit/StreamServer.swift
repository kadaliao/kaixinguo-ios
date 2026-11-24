import Foundation
import Network
import Synchronization

/// StreamServer serves episodes, decrypted, over plain HTTP on the local
/// network, for a device that fetches the video itself: an Apple TV, or a
/// television, that AirPlay sends the episode to. Each file is a
/// `StreamLoader`'s, at a path only it knows, and takes ranges as a CDN
/// would; the loader downloads and decrypts them as they go out.
///
/// It listens only while something is cast, on a port the system picks.
public final class StreamServer: @unchecked Sendable {
    public static let shared = StreamServer()

    private let queue = DispatchQueue(label: "kaixinguo.server")
    // On the queue.
    private var listener: NWListener?
    private var ready: [CheckedContinuation<UInt16, Error>] = []
    private var files: [String: WeakLoader] = [:] // by the loader's ID

    private struct WeakLoader {
        weak var loader: StreamLoader?
    }

    init() {}

    /// The URL another device on the network plays the loader's file from,
    /// at `host`: this device's Wi-Fi address unless given. The server
    /// starts listening if it wasn't.
    public func url(for loader: StreamLoader, host: String? = nil) async throws -> URL {
        guard let host = host ?? Self.wifiAddress() else {
            throw AppError("没有连接 Wi-Fi，无法投屏")
        }
        let port = try await start()
        queue.sync {
            files = files.filter { $0.value.loader != nil }
            files[loader.id] = WeakLoader(loader: loader)
        }
        return URL(string: "http://\(host):\(port)/episode/\(loader.id).mp4")!
    }

    /// Stops listening, as casting ends.
    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            files = [:]
            fail(AppError("投屏已停止"))
        }
    }

    // MARK: - Listening

    private func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                if let listener, let port = listener.port?.rawValue, listener.state == .ready {
                    c.resume(returning: port)
                    return
                }
                ready.append(c)
                guard listener == nil else { return }
                let l: NWListener
                do {
                    let params = NWParameters.tcp
                    params.allowLocalEndpointReuse = true
                    l = try NWListener(using: params)
                } catch {
                    fail(error)
                    return
                }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { [weak self, weak l] state in
                    guard let self, let l else { return }
                    switch state {
                    case .ready:
                        let port = l.port?.rawValue ?? 0
                        let waiting = ready
                        ready = []
                        for c in waiting {
                            c.resume(returning: port)
                        }
                    case .failed(let error):
                        debugLog("server: \(error)")
                        l.cancel()
                        if listener === l {
                            listener = nil
                        }
                        fail(error)
                    default:
                        break
                    }
                }
                listener = l
                l.start(queue: queue)
            }
        }
    }

    private func fail(_ error: Error) {
        let waiting = ready
        ready = []
        for c in waiting {
            c.resume(throwing: error)
        }
    }

    // MARK: - Answering

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHead(conn, Data())
    }

    /// Reads the request up to the blank line after its headers.
    private func readHead(_ conn: NWConnection, _ got: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { [weak self] data, _, done, error in
            guard let self else { return }
            var got = got
            if let data {
                got.append(data)
            }
            if let end = got.range(of: Data("\r\n\r\n".utf8)) {
                answer(conn, String(decoding: got[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || got.count > 64 << 10 {
                conn.cancel()
            } else {
                readHead(conn, got)
            }
        }
    }

    private func answer(_ conn: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else {
            reply(conn, status: "400 Bad Request")
            return
        }
        let method = parts[0], path = parts[1]
        guard method == "GET" || method == "HEAD" else {
            reply(conn, status: "405 Method Not Allowed")
            return
        }
        let id = path.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? ""
        guard path.hasPrefix("/episode/"), let loader = files[id]?.loader else {
            reply(conn, status: "404 Not Found")
            return
        }
        var range: String?
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":"),
               line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                range = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let wanted = range, get = method == "GET"
        loader.size { [weak self] result in
            guard let self else { return }
            queue.async { [self] in
                switch result {
                case .success(let size):
                    respond(conn, loader, size: size, range: wanted, body: get)
                case .failure(let error):
                    debugLog("server: \(error)")
                    reply(conn, status: "502 Bad Gateway")
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, _ loader: StreamLoader, size: Int64, range: String?, body: Bool) {
        var headers = ["Content-Type: video/mp4", "Accept-Ranges: bytes"]
        let status: String
        let a: Int64, b: Int64
        if let range {
            guard let (from, to) = byteRange(range, size: size) else {
                reply(conn, status: "416 Range Not Satisfiable", headers: ["Content-Range: bytes */\(size)"])
                return
            }
            (a, b) = (from, to)
            status = "206 Partial Content"
            headers.append("Content-Range: bytes \(a)-\(b)/\(size)")
        } else {
            (a, b) = (0, size - 1)
            status = "200 OK"
        }
        headers.append("Content-Length: \(b - a + 1)")
        guard body else {
            reply(conn, status: status, headers: headers, length: true)
            return
        }
        let sink = HTTPSink(conn)
        conn.send(content: Data(responseHead(status, headers).utf8), completion: .contentProcessed { _ in })
        // The client hanging up stops the download for it.
        watchClose(conn, sink, loader)
        loader.send(sink, from: a, to: b + 1)
    }

    private func watchClose(_ conn: NWConnection, _ sink: HTTPSink, _ loader: StreamLoader) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            if done || error != nil {
                sink.cancel()
                loader.stop(sink)
            } else {
                self?.watchClose(conn, sink, loader)
            }
        }
    }

    /// Answers with headers and no body, then hangs up.
    private func reply(_ conn: NWConnection, status: String, headers: [String] = [], length: Bool = false) {
        let all = length ? headers : headers + ["Content-Length: 0"]
        conn.send(content: Data(responseHead(status, all).utf8), contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func responseHead(_ status: String, _ headers: [String]) -> String {
        (["HTTP/1.1 \(status)"] + headers + ["Connection: close", "", ""]).joined(separator: "\r\n")
    }

    // MARK: - Where this device is

    /// This device's address on Wi-Fi, IPv4.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0",
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                found = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                break
            }
        }
        return found
    }
}

/// The bytes a Range header asks for of a file `size` long, first and last
/// included: "bytes=a-b", "bytes=a-" or the last n, "bytes=-n"; only the
/// first range of several. Nil when none of it is in the file.
func byteRange(_ header: String, size: Int64) -> (Int64, Int64)? {
    guard header.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
    let spec = header.dropFirst(6).split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let first = Int64(parts[0].trimmingCharacters(in: .whitespaces))
    let last = Int64(parts[1].trimmingCharacters(in: .whitespaces))
    switch (first, last) {
    case (let a?, let b?):
        guard a <= b, a < size else { return nil }
        return (a, min(b, size - 1))
    case (let a?, nil):
        guard a < size else { return nil }
        return (a, size - 1)
    case (nil, let n?):
        guard n > 0 else { return nil }
        return (max(0, size - n), size - 1)
    default:
        return nil
    }
}

/// HTTPSink sends a range on to a client of the server as it arrives,
/// holding the download off while much is still on its way out.
final class HTTPSink: RangeSink, @unchecked Sendable {
    /// How much may wait to go out before the download holds off, and how
    /// little before it goes on.
    static let high = 4 << 20, low = 1 << 20

    private let conn: NWConnection
    private struct State {
        var cancelled = false
        var outstanding = 0
        var ready: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())

    init(_ conn: NWConnection) {
        self.conn = conn
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func cancel() {
        let ready = state.withLock { s in
            s.cancelled = true
            defer { s.ready = [] }
            return s.ready
        }
        for r in ready {
            r()
        }
    }

    func respond(_ data: Data) -> Bool {
        let n = data.count
        let full = state.withLock { s in
            s.outstanding += n
            return s.outstanding > Self.high
        }
        conn.send(content: data, completion: .contentProcessed { [self] error in
            let ready = state.withLock { s in
                s.outstanding -= n
                if error != nil {
                    s.cancelled = true
                }
                guard s.outstanding < Self.low || s.cancelled else { return [] as [@Sendable () -> Void] }
                defer { s.ready = [] }
                return s.ready
            }
            for r in ready {
                r()
            }
        })
        return !full
    }

    func whenReady(_ ready: @escaping @Sendable () -> Void) {
        let now = state.withLock { s in
            if s.outstanding < Self.low || s.cancelled {
                return true
            }
            s.ready.append(ready)
            return false
        }
        if now {
            ready()
        }
    }

    func finish(_ error: Error?) {
        if error != nil {
            conn.cancel()
            return
        }
        let conn = conn
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }
}
