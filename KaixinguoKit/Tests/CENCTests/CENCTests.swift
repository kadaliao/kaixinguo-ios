import CommonCrypto
import Foundation
import Testing

@testable import CENC

/// The ways a file can keep its sample encryption info.
enum Info {
    case senc // in a senc box inside stbl
    case sencSubsamples // in a senc box, with subsamples
    case saio // in mdat, which saiz sizes and saio places
}

/// A small CENC file built from scratch: an encrypted video track whose
/// samples were encrypted with CommonCrypto's own CTR mode, so the test
/// does not check the decryptor against itself.
struct TestFile {
    var file: [UInt8] = [] // encrypted
    var clear: [UInt8] = [] // what decrypting it must give
    let key: [UInt8] = (0..<16).map { UInt8($0 * 7 + 3) }

    init(info: Info, moovLast: Bool = false, samples count: Int = 12) {
        var rng = SplitMix(seed: 42)
        let sizes = (0..<count).map { _ in 3000 + Int(rng.next() % 9000) }
        let plain = sizes.map { n in (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
        let ivs = (0..<count).map { _ in (0..<8).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
        let subs: [[(clear: Int, enc: Int)]] = sizes.map { n in
            info == .sencSubsamples ? [(100, 1000), (37, n - 100 - 1000 - 37 - 50), (50, 0)] : []
        }
        let encrypted = zip(plain, zip(ivs, subs)).map { p, s in encrypt(p, iv: s.0, subs: s.1) }
        // Two passes: the second knows where mdat's payload starts.
        var payloadAt = 0
        for pass in 0..<2 {
            let aux = info == .saio ? ivs.flatMap { $0 } : []
            let auxAt = payloadAt
            let samplesAt = payloadAt + aux.count
            func build(clear: Bool) -> [UInt8] {
                let ftyp = box("ftyp", Array("isom".utf8) + u32(0) + Array("isomiso2".utf8))
                let moov = Self.moov(clear: clear, info: info, sizes: sizes, ivs: ivs, subs: subs,
                                     chunkAt: samplesAt, auxAt: auxAt)
                let mdat = box("mdat", aux + (clear ? plain : encrypted).flatMap { $0 })
                return moovLast ? ftyp + mdat + moov : ftyp + moov + mdat
            }
            file = build(clear: false)
            clear = build(clear: true)
            if pass == 0 {
                // The payload follows ftyp and moov, or ftyp alone.
                let ftypSize = 8 + 4 + 4 + 8
                let moovSize = file.count - ftypSize - 8 - aux.count - encrypted.reduce(0) { $0 + $1.count }
                payloadAt = moovLast ? ftypSize + 8 : ftypSize + moovSize + 8
            }
        }
    }

    static func moov(clear: Bool, info: Info, sizes: [Int], ivs: [[UInt8]], subs: [[(clear: Int, enc: Int)]],
                     chunkAt: Int, auxAt: Int) -> [UInt8] {
        let n = sizes.count
        let tenc = fullBox("tenc", [0, 0, 1, 8] + [UInt8](repeating: 0xab, count: 16))
        let sinf = box(clear ? "free" : "sinf",
                       box("frma", Array("hvc1".utf8))
                           + fullBox("schm", Array("cenc".utf8) + u32(0x10000))
                           + box("schi", tenc))
        let entry = box(clear ? "hvc1" : "encv", [UInt8](repeating: 0, count: 78) + box("hvcC", [1, 2, 3, 4]) + sinf)
        let stsd = fullBox("stsd", u32(1) + entry)
        let stsz = fullBox("stsz", u32(0) + u32(UInt32(n)) + sizes.flatMap { u32(UInt32($0)) })
        // Two chunks, to walk stsc's runs: the first holds 5 samples.
        let first = 5
        let stsc = fullBox("stsc", u32(2) + u32(1) + u32(UInt32(first)) + u32(1) + u32(2) + u32(UInt32(n - first)) + u32(1))
        let second = chunkAt + sizes.prefix(first).reduce(0, +)
        let stco = fullBox("stco", u32(2) + u32(UInt32(chunkAt)) + u32(UInt32(second)))
        var protection: [UInt8] = []
        switch info {
        case .senc, .sencSubsamples:
            var body = u32(UInt32(n))
            for k in 0..<n {
                body += ivs[k]
                if info == .sencSubsamples {
                    body += u16(UInt16(subs[k].count))
                    for s in subs[k] {
                        body += u16(UInt16(s.clear)) + u32(UInt32(s.enc))
                    }
                }
            }
            protection = fullBox(clear ? "free" : "senc", flags: info == .sencSubsamples ? 2 : 0, body)
        case .saio:
            protection = fullBox(clear ? "free" : "saiz", [8] + u32(UInt32(n)))
                + fullBox(clear ? "free" : "saio", u32(1) + u32(UInt32(auxAt)))
        }
        let stbl = box("stbl", stsd + stsz + stsc + stco + protection)
        let trak = box("trak", box("mdia", box("minf", stbl)))
        let pssh = fullBox(clear ? "free" : "pssh", [UInt8](repeating: 0x11, count: 20))
        return box("moov", trak + pssh)
    }

    var fetch: Fetch {
        let file = file
        return { off, n in Array(file[Int(off)..<Int(off + n)]) }
    }
}

@Test(arguments: [Info.senc, .sencSubsamples, .saio])
func decryptsWholeFile(info: Info) async throws {
    let s = TestFile(info: info)
    let layout = try await Layout.open(total: Int64(s.file.count), key: s.key, fetch: s.fetch)
    #expect(layout.isProtected)
    var out = s.file
    layout.decrypt(&out, at: 0)
    #expect(out == s.clear)
}

/// Any range decrypts to the same bytes as the whole, as a player seeking
/// through the stream needs.
@Test(arguments: [Info.senc, .sencSubsamples, .saio])
func decryptsInPieces(info: Info) async throws {
    let s = TestFile(info: info)
    let layout = try await Layout.open(total: Int64(s.file.count), key: s.key, fetch: s.fetch)
    var rng = SplitMix(seed: 7)
    for _ in 0..<10 {
        var out = s.file
        var off = 0
        while off < out.count {
            let n = min(1 + Int(rng.next() % 9000), out.count - off)
            var piece = Array(out[off..<(off + n)])
            layout.decrypt(&piece, at: Int64(off))
            out.replaceSubrange(off..<(off + n), with: piece)
            off += n
        }
        #expect(out == s.clear)
    }
}

/// A file that keeps moov after mdat, past the first read, is found.
@Test func findsMoovAfterMdat() async throws {
    let s = TestFile(info: .senc, moovLast: true)
    #expect(s.file.count > 64 << 10)
    let layout = try await Layout.open(total: Int64(s.file.count), key: s.key, fetch: s.fetch)
    var out = s.file
    layout.decrypt(&out, at: 0)
    #expect(out == s.clear)
}

@Test func rejectsBadKey() async throws {
    let s = TestFile(info: .senc)
    await #expect(throws: CENCError.self) {
        try await Layout.open(total: Int64(s.file.count), key: [1, 2, 3], fetch: s.fetch)
    }
}

/// Decrypts a real episode when CENC_SAMPLE names one and CENC_KEY holds
/// its key. CENC_CLEAR, when set, names the clear file the macOS app's Go
/// decryptor made of it, which this one must match byte for byte.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CENC_SAMPLE"] != nil))
func decryptsRealEpisode() async throws {
    let env = ProcessInfo.processInfo.environment
    let src = try [UInt8](Data(contentsOf: URL(fileURLWithPath: env["CENC_SAMPLE"]!)))
    let key = hexBytes(env["CENC_KEY"] ?? "")
    let layout = try await Layout.open(total: Int64(src.count), key: key) { off, n in
        Array(src[Int(off)..<Int(off + n)])
    }
    #expect(layout.isProtected)
    var whole = src
    layout.decrypt(&whole, at: 0)
    if let path = env["CENC_CLEAR"] {
        let want = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(whole == want, "differs from the Go decryptor's output")
    }
    var rng = SplitMix(seed: 1)
    for round in 0..<5 {
        var pieces = src
        var off = 0
        while off < pieces.count {
            let n = min(1 + Int(rng.next() % 70000), pieces.count - off)
            pieces.withUnsafeMutableBytes { b in
                layout.decrypt(UnsafeMutableRawBufferPointer(rebasing: b[off..<(off + n)]), at: Int64(off))
            }
            off += n
        }
        #expect(pieces == whole, "round \(round): pieces differ from the whole")
    }
}

// MARK: - Helpers

func encrypt(_ plain: [UInt8], iv: [UInt8], subs: [(clear: Int, enc: Int)]) -> [UInt8] {
    // The encrypted ranges, as one CTR stream.
    var ranges: [Range<Int>] = []
    if subs.isEmpty {
        ranges = [0..<plain.count]
    } else {
        var pos = 0
        for s in subs {
            pos += s.clear
            ranges.append(pos..<(pos + s.enc))
            pos += s.enc
        }
    }
    let stream = ranges.flatMap { plain[$0] }
    let enc = ctr(stream, key: (0..<16).map { UInt8($0 * 7 + 3) }, iv: iv + [UInt8](repeating: 0, count: 8))
    var out = plain
    var at = 0
    for r in ranges {
        out.replaceSubrange(r, with: enc[at..<(at + r.count)])
        at += r.count
    }
    return out
}

func ctr(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
    var cryptor: CCCryptorRef?
    CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                            CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                            CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
    defer { CCCryptorRelease(cryptor) }
    var out = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved)
    return out
}

func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
    u32(UInt32(8 + body.count)) + Array(type.utf8) + body
}

func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ body: [UInt8]) -> [UInt8] {
    box(type, [version, UInt8(flags >> 16 & 0xff), UInt8(flags >> 8 & 0xff), UInt8(flags & 0xff)] + body)
}

func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

func hexBytes(_ s: String) -> [UInt8] {
    let chars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines))
    return stride(from: 0, to: chars.count - 1, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
}

/// SplitMix is a small seeded generator, so the samples are the same on
/// every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
