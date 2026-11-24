import Foundation
import Openhongguo
import Synchronization
import Testing

@testable import KaixinguoKit

/// Fallback is a catalog whose two signings answer as local and remote say:
/// nil for an answer.
final class Fallback: Sendable {
    let localCatalog = FakeCatalog(), remoteCatalog = FakeCatalog()
    let catalog: FallbackCatalog
    let clock = Clock()

    final class Clock: Sendable {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    }

    struct Answers {
        var local: ErrorCode?
        var remote: ErrorCode?
        var asked: [String] = []
    }
    let answers = Mutex(Answers())

    init(signer: Bool = true) {
        let remote = remoteCatalog, clock = clock
        catalog = FallbackCatalog(
            local: localCatalog,
            store: .memory(signer ? SignerSettings(url: "https://signer.example.com") : SignerSettings()),
            now: { clock.now.withLock { $0 } },
            makeRemote: { _ in remote })
    }

    func set(local: ErrorCode?, remote: ErrorCode?) {
        answers.withLock { $0.local = local; $0.remote = remote }
    }

    /// Plays, and says who answered, or with what error it failed.
    func play() async -> Result<String, OpenhongguoError> {
        do {
            return .success(try await catalog.call { c in
                let remote = (c as AnyObject) === self.remoteCatalog
                let code = self.answers.withLock {
                    $0.asked.append(remote ? "remote" : "local")
                    return remote ? $0.remote : $0.local
                }
                if let code {
                    throw OpenhongguoError(code: code, message: "")
                }
                return remote ? "remote" : "local"
            })
        } catch {
            return .failure(error as! OpenhongguoError)
        }
    }

    func took() -> [String] {
        answers.withLock {
            defer { $0.asked = [] }
            return $0.asked
        }
    }

    func wait(_ t: TimeInterval) { clock.now.withLock { $0 += t } }
}

extension Result where Failure == OpenhongguoError {
    var code: ErrorCode? {
        if case .failure(let e) = self { return e.code }
        return nil
    }
}

@Suite struct SignerTests {
    // While the built-in signing works, the signing service is not asked.
    @Test func builtinSigningFirst() async throws {
        let f = Fallback()
        #expect(try await f.play().get() == "local")
        #expect(f.took() == ["local"])
    }

    // Errors that are not the signing's are not retried with the service.
    @Test func otherErrorsStay() async {
        let f = Fallback()
        f.set(local: .contentUnavailable, remote: nil)
        #expect(await f.play().code == .contentUnavailable)
        #expect(f.took() == ["local"])
    }

    // When the server stops taking the built-in signing, playback is signed
    // by the service, and goes to the service first after that, until the
    // service fails and the built-in signing works again.
    @Test func fallBackToSigner() async throws {
        let f = Fallback()
        f.set(local: .anonymousLimited, remote: nil)
        #expect(try await f.play().get() == "remote")
        #expect(f.took() == ["local", "remote"])
        #expect(try await f.play().get() == "remote")
        #expect(f.took() == ["remote"])

        f.set(local: nil, remote: .signerUnavailable)
        #expect(try await f.play().get() == "local")
        #expect(f.took() == ["remote", "local"])
        #expect(!f.catalog.remoteFirst)
        _ = await f.play()
        #expect(f.took() == ["local"])
    }

    // A rejected signature falls back too.
    @Test func rejectedSignatureFallsBack() async throws {
        let f = Fallback()
        f.set(local: .signatureRejected, remote: nil)
        #expect(try await f.play().get() == "remote")
        #expect(f.took() == ["local", "remote"])
    }

    // After half an hour with the service, the built-in signing is tried
    // first again; if it works, the service is not asked.
    @Test func builtinAgainAfterAWhile() async throws {
        let f = Fallback()
        f.set(local: .anonymousLimited, remote: nil)
        _ = await f.play()
        _ = f.took()
        f.wait(29 * 60)
        #expect(f.catalog.remoteFirst)
        f.wait(2 * 60)
        #expect(!f.catalog.remoteFirst)
        f.set(local: nil, remote: nil)
        #expect(try await f.play().get() == "local")
        #expect(f.took() == ["local"])
    }

    // With both failing, the error is the built-in signing's, not the
    // service's, whichever was asked first.
    @Test func signerDownKeepsBuiltinError() async {
        let f = Fallback()
        f.set(local: .anonymousLimited, remote: .signerUnavailable)
        #expect(await f.play().code == .anonymousLimited)
        #expect(!f.catalog.remoteFirst)

        f.set(local: .anonymousLimited, remote: nil)
        _ = await f.play() // the service first from now on
        f.set(local: .rateLimited, remote: .signerUnavailable)
        #expect(await f.play().code == .rateLimited)
        #expect(f.took() == ["local", "remote", "local", "remote", "remote", "local"])
    }

    // Without a service, nothing is retried.
    @Test func noSigner() async {
        let f = Fallback(signer: false)
        f.set(local: .anonymousLimited, remote: nil)
        #expect(await f.play().code == .anonymousLimited)
        #expect(f.took() == ["local"])
    }

    // Only playback goes to the service: an empty search stays the
    // built-in signing's.
    @Test func onlyPlaybackFallsBack() async throws {
        let f = Fallback()
        f.localCatalog.update { $0.search = { _, _ in throw OpenhongguoError(code: .anonymousLimited, message: "") } }
        await #expect(throws: OpenhongguoError.self) {
            try await f.catalog.search("x", options: SearchOptions())
        }
        _ = try? await f.catalog.resolvePlayback("e1")
        #expect(f.localCatalog.calls == ["search:x:", "resolve:e1"])
        #expect(f.remoteCatalog.calls == ["resolve:e1"])
    }

    // Applying settings saves them and rebuilds the service's client; an
    // empty address turns it off, and drops the token.
    @Test func applySettings() async throws {
        let store = SignerStore.memory()
        let made = Mutex<[SignerSettings]>([])
        let c = FallbackCatalog(local: FakeCatalog(), store: store) { s in
            made.withLock { $0.append(s) }
            return FakeCatalog()
        }
        #expect(made.withLock { $0 }.isEmpty)
        try c.apply(SignerSettings(url: " https://signer.example.com ", token: " tok "))
        let s = SignerSettings(url: "https://signer.example.com", token: "tok")
        #expect(store.load() == s)
        #expect(c.settings == s)
        #expect(made.withLock { $0 } == [s])
        try c.apply(SignerSettings(url: "", token: "tok"))
        #expect(store.load() == SignerSettings())
        #expect(made.withLock { $0 }.count == 1)

        // What was saved is what a new launch falls back to.
        try c.apply(s)
        _ = FallbackCatalog(local: FakeCatalog(), store: store) { s in
            made.withLock { $0.append(s) }
            return FakeCatalog()
        }
        #expect(made.withLock { $0 } == [s, s, s])
    }

    @Test func checkURL() {
        let cases: [String: Bool] = [
            "": true, "https://pp.example.com": true, "http://127.0.0.1:19830": true,
            "pp.example.com": false, "ftp://x": false, "https://": false,
        ]
        for (raw, ok) in cases {
            #expect((checkSignerURL(raw) == "") == ok, "\(raw)")
        }
    }
}

// MARK: - Checking a service

/// FakeSigner answers the requests of a session made with it as an
/// openhongguo-signer would.
final class FakeSigner: URLProtocol, @unchecked Sendable {
    struct Service {
        var ready = true
        var token = "right"
        var requests: [String] = []
    }
    static let service = Mutex(Service())

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeSigner.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        guard url.host == "signer.example.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let s = Self.service.withLock {
            $0.requests.append("\(request.httpMethod ?? "GET") \(url.path)")
            return $0
        }
        let (code, body): (Int, String)
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/ready"):
            (code, body) = (200, #"{"service":"openhongguo-signer","ready":\#(s.ready)}"#)
        case ("POST", "/feature-hash"):
            if !s.token.isEmpty, request.value(forHTTPHeaderField: "X-Signer-Token") != s.token {
                (code, body) = (401, #"{"error":"unauthorized"}"#)
            } else {
                (code, body) = (400, #"{"error":"url is required"}"#)
            }
        default:
            (code, body) = (404, "404 page not found")
        }
        let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// The settings' check tells a service that is not ready, a wrong token and
// a right one apart. It runs serially: the fake service is shared.
@Suite(.serialized) struct ProbeTests {
    let session = FakeSigner.session()

    func probe(_ url: String, _ token: String) async -> String? {
        do {
            try await probeSigner(url, token: token, session: session)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func checks() async {
        FakeSigner.service.withLock { $0 = FakeSigner.Service() }
        #expect(await probe("https://signer.example.com/", "right") == nil)
        #expect(FakeSigner.service.withLock { $0.requests } == ["GET /ready", "POST /feature-hash"])
        #expect(await probe("https://signer.example.com", "wrong") == "token 不对")
        #expect(await probe("https://signer.example.com", "") == "签名服务要求填写 token")
        #expect(await probe("https://signer.example.com/nothing", "right") == "这个地址不是签名服务（HTTP 404）")
        #expect(await probe("https://elsewhere.example.com", "right") == "连不上签名服务")

        FakeSigner.service.withLock { $0.ready = false }
        #expect(await probe("https://signer.example.com", "right") == "签名服务还在启动，稍后再试")

        // A service with no token takes any.
        FakeSigner.service.withLock { $0 = FakeSigner.Service(token: "") }
        #expect(await probe("https://signer.example.com", "") == nil)
    }
}
