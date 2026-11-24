import Foundation
import Testing

@testable import KaixinguoKit

@Test func readsByteRanges() {
    #expect(byteRange("bytes=0-99", size: 1000)! == (0, 99))
    #expect(byteRange("bytes=500-", size: 1000)! == (500, 999))
    #expect(byteRange("bytes=900-2000", size: 1000)! == (900, 999))
    #expect(byteRange("bytes=-100", size: 1000)! == (900, 999))
    #expect(byteRange("bytes=-5000", size: 1000)! == (0, 999))
    #expect(byteRange("bytes=0-1, 5-9", size: 1000)! == (0, 1))
    #expect(byteRange("bytes=1000-", size: 1000) == nil)
    #expect(byteRange("bytes=9-3", size: 1000) == nil)
    #expect(byteRange("items=0-1", size: 1000) == nil)
    #expect(byteRange("bytes=-0", size: 1000) == nil)
}

@Test func softensLoudSamples() {
    #expect(soften(0.5) == 0.5)
    #expect(soften(-0.8) == -0.8)
    #expect(soften(1.2) < 1 && soften(1.2) > 0.9)
    #expect(soften(-3) >= -1 && soften(-3) < -0.99)
    #expect(soften(0.9) < soften(1.0))
}

/// Serves a file over HTTP as a CDN would, from a loader whose start was
/// read ahead: ranges, the whole file, its head alone, and what isn't
/// there. What was read ahead isn't downloaded again.
@Test func servesOverHTTP() async throws {
    var bytes = [UInt8](repeating: 0, count: 3 << 20)
    for i in bytes.indices {
        bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13)
    }
    let data = Data(bytes)
    FixtureProtocol.files.withLock { $0["/clear.mp4"] = data }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let loader = StreamLoader(sources: [URL(string: "https://fixture.test/clear.mp4")!], key: nil,
                              configuration: config)
    defer { loader.invalidate() }

    loader.preload(1 << 20)
    for _ in 0..<100 where await loader.preloaded() < 1 << 20 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await loader.preloaded() == 1 << 20)

    let server = StreamServer()
    defer { server.stop() }
    let url = try await server.url(for: loader, host: "127.0.0.1")
    let http = URLSession(configuration: .ephemeral)

    FixtureProtocol.requests.withLock { $0 = [] }
    var req = URLRequest(url: url)
    req.setValue("bytes=100-1999999", forHTTPHeaderField: "Range")
    var (body, resp) = try await http.data(for: req)
    var r = try #require(resp as? HTTPURLResponse)
    #expect(r.statusCode == 206)
    #expect(r.value(forHTTPHeaderField: "Content-Range") == "bytes 100-1999999/\(data.count)")
    #expect(body == data.subdata(in: 100..<2_000_000))
    let asked = FixtureProtocol.requests.withLock { $0 }
    #expect(asked == ["/clear.mp4 bytes=\(1 << 20)-1999999"], "\(asked)")

    // Within what was read ahead: nothing from the CDN.
    FixtureProtocol.requests.withLock { $0 = [] }
    req.setValue("bytes=10-20", forHTTPHeaderField: "Range")
    (body, _) = try await http.data(for: req)
    #expect(body == data.subdata(in: 10..<21))
    #expect(FixtureProtocol.requests.withLock { $0 }.isEmpty)

    (body, resp) = try await http.data(from: url)
    r = try #require(resp as? HTTPURLResponse)
    #expect(r.statusCode == 200)
    #expect(body == data)

    var head = URLRequest(url: url)
    head.httpMethod = "HEAD"
    (_, resp) = try await http.data(for: head)
    r = try #require(resp as? HTTPURLResponse)
    #expect(r.statusCode == 200)
    #expect(r.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
    #expect(r.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")

    req.setValue("bytes=\(data.count)-", forHTTPHeaderField: "Range")
    (_, resp) = try await http.data(for: req)
    #expect((resp as? HTTPURLResponse)?.statusCode == 416)

    let other = url.deletingLastPathComponent().appendingPathComponent("nothing.mp4")
    (_, resp) = try await http.data(from: other)
    #expect((resp as? HTTPURLResponse)?.statusCode == 404)
}
