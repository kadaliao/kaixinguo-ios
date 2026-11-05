// CENC turns a progressive MP4 encrypted with the 'cenc' scheme (AES-CTR,
// ISO/IEC 23001-7) into a clear one, a byte range at a time.
//
// Decryption never changes a byte's position: samples are decrypted in
// place and the boxes that mark the file as protected are renamed to boxes
// of the same size ('encv' → 'hvc1', 'sinf' → 'free', …). So any range of
// the clear file is the same range of the encrypted file, decrypted, and a
// player can seek through a stream that is decrypted as it downloads.
//
// It is a port of the macOS app's internal/cenc package, and must stay
// byte for byte in step with it.

import CommonCrypto
import Foundation

/// Fetch reads `count` bytes of the file at `offset`.
public typealias Fetch = @Sendable (_ offset: Int64, _ count: Int64) async throws -> [UInt8]

public struct CENCError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Layout is what `decrypt` needs to know about one file: where its samples
/// are, their IVs, and the patched header.
public struct Layout: Sendable {
    let key: [UInt8]
    let moovOffset: Int64
    let moov: [UInt8] // the patched moov box, written over the original
    let samples: [Sample] // protected samples, sorted by offset

    /// Whether the file had any encrypted samples.
    public var isProtected: Bool { !samples.isEmpty }

    /// Reads the moov box of a file of `total` bytes through `fetch` and
    /// returns its layout for the content key.
    public static func open(total: Int64, key: [UInt8], fetch: @escaping Fetch) async throws -> Layout {
        let (offset, moov) = try await findMoov(total: total, fetch: fetch)
        return try await parse(moovOffset: offset, moov: moov, key: key, fetch: fetch)
    }

    /// Builds the layout of a file whose moov box, at `moovOffset`, is
    /// `moov`. `fetch` reads auxiliary data that saio places outside moov;
    /// it may be nil when the file keeps its IVs in senc boxes.
    public static func parse(moovOffset: Int64, moov: [UInt8], key: [UInt8], fetch: Fetch?) async throws -> Layout {
        guard [16, 24, 32].contains(key.count) else {
            throw CENCError("cenc: invalid key size \(key.count)")
        }
        let buf = Buffer(moov)
        guard let root = Box.parse(buf, at: 0, limit: buf.count), root.type == "moov" else {
            throw CENCError("cenc: not a moov box")
        }
        var samples: [Sample] = []
        for b in root.children() {
            switch b.type {
            case "trak":
                samples += try await parseTrak(b, moovOffset: moovOffset, fetch: fetch)
            case "pssh":
                b.rename("free")
            default:
                break
            }
        }
        samples.sort { $0.offset < $1.offset }
        return Layout(key: key, moovOffset: moovOffset, moov: buf.bytes, samples: samples)
    }

    /// Turns `buf`, the bytes of the file at `offset`, into the clear file's.
    public func decrypt(_ buf: UnsafeMutableRawBufferPointer, at offset: Int64) {
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self), buf.count > 0 else { return }
        let end = offset + Int64(buf.count)
        // The patched header.
        let mEnd = moovOffset + Int64(moov.count)
        if offset < mEnd && end > moovOffset {
            let a = max(offset, moovOffset), b = min(end, mEnd)
            moov.withUnsafeBufferPointer { m in
                (base + Int(a - offset)).update(from: m.baseAddress! + Int(a - moovOffset), count: Int(b - a))
            }
        }
        // The samples.
        var i = firstSample(endingAfter: offset)
        while i < samples.count && samples[i].offset < end {
            let s = samples[i]
            i += 1
            guard let subs = s.subsamples else {
                let a = max(offset, s.offset), b = min(end, s.offset + Int64(s.size))
                xor(base + Int(a - offset), count: Int(b - a), iv: s.iv, at: a - s.offset)
                continue
            }
            // Subsamples: the encrypted parts make one CTR stream.
            var pos = s.offset, stream: Int64 = 0
            for sub in subs {
                pos += Int64(sub.clear)
                let encEnd = pos + Int64(sub.encrypted)
                let a = max(offset, pos), b = min(end, encEnd)
                if a < b {
                    xor(base + Int(a - offset), count: Int(b - a), iv: s.iv, at: stream + (a - pos))
                }
                stream += Int64(sub.encrypted)
                pos = encEnd
            }
        }
    }

    /// Decrypts `data`, the bytes of the file at `offset`, in place.
    public func decrypt(_ data: inout Data, at offset: Int64) {
        data.withUnsafeMutableBytes { decrypt($0, at: offset) }
    }

    /// Decrypts `bytes`, the bytes of the file at `offset`, in place.
    public func decrypt(_ bytes: inout [UInt8], at offset: Int64) {
        bytes.withUnsafeMutableBytes { decrypt($0, at: offset) }
    }

    /// The index of the first sample that ends after `offset`.
    private func firstSample(endingAfter offset: Int64) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].offset + Int64(samples[mid].size) > offset {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }

    /// Applies the keystream of `iv`, from byte `at` of its stream, to the
    /// `count` bytes at `dst`. The counter is the IV's low 64 bits, as CENC
    /// and ffmpeg count blocks.
    private func xor(_ dst: UnsafeMutablePointer<UInt8>, count: Int, iv: IV, at: Int64) {
        guard count > 0 else { return }
        let firstBlock = UInt64(at / 16)
        let skip = Int(at % 16)
        let blocks = (skip + count + 15) / 16
        // The counter blocks, all at once, and their encryption in one call.
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        counters.withUnsafeMutableBytes { c in
            for k in 0..<blocks {
                c.storeBytes(of: iv.high.bigEndian, toByteOffset: k * 16, as: UInt64.self)
                c.storeBytes(of: (iv.low &+ firstBlock &+ UInt64(k)).bigEndian, toByteOffset: k * 16 + 8, as: UInt64.self)
            }
        }
        var stream = [UInt8](repeating: 0, count: blocks * 16)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            counters.withUnsafeBytes { c in
                stream.withUnsafeMutableBytes { s in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, k.count, nil, c.baseAddress, c.count, s.baseAddress, s.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return } // the key size was checked: this does not happen
        stream.withUnsafeBufferPointer { s in
            for k in 0..<count {
                dst[k] ^= s[skip + k]
            }
        }
    }
}

// MARK: - The moov box

struct IV: Sendable {
    var high: UInt64 = 0
    var low: UInt64 = 0

    /// Reads an IV of 8 or 16 bytes; an 8-byte IV is the high half.
    init(_ bytes: ArraySlice<UInt8>) {
        var all = [UInt8](repeating: 0, count: 16)
        for (k, b) in bytes.prefix(16).enumerated() {
            all[k] = b
        }
        high = be64(all, 0)
        low = be64(all, 8)
    }

    init() {}
}

struct Subsample: Sendable {
    var clear: UInt32
    var encrypted: UInt32
}

struct Sample: Sendable {
    var offset: Int64
    var size: UInt32
    var iv: IV
    var subsamples: [Subsample]? // nil: the whole sample is encrypted
}

/// findMoov walks the top-level boxes until it finds moov, which faststart
/// files keep before mdat and others after it.
func findMoov(total: Int64, fetch: Fetch) async throws -> (Int64, [UInt8]) {
    let probe: Int64 = 64 << 10
    let head = try await fetch(0, min(probe, total))
    var off: Int64 = 0
    while off + 8 <= total {
        let hdr: [UInt8]
        if off + 16 <= Int64(head.count) {
            hdr = Array(head[Int(off)..<Int(off) + 16])
        } else {
            hdr = try await fetch(off, min(16, total - off))
        }
        guard hdr.count >= 8 else { throw CENCError("cenc: short box header at \(off)") }
        var size = Int64(be32(hdr, 0))
        let type = fourCC(hdr, 4)
        if size == 1 && hdr.count >= 16 {
            size = Int64(bitPattern: be64(hdr, 8))
        } else if size == 0 {
            size = total - off
        }
        if size < 8 || off + size > total {
            throw CENCError("cenc: bad box \"\(type)\" at \(off)")
        }
        if type == "moov" {
            if off + size <= Int64(head.count) {
                return (off, Array(head[Int(off)..<Int(off + size)]))
            }
            let moov = try await fetch(off, size)
            guard Int64(moov.count) == size else { throw CENCError("cenc: short moov box") }
            return (off, moov)
        }
        off += size
    }
    throw CENCError("cenc: no moov box")
}

/// Track is what one trak says about its protection.
private struct Track {
    var ivSize = 0
    var constIV: ArraySlice<UInt8> = []
    var isProtected = false
    var sizes: [UInt32] = []
    var offsets: [Int64] = []
    var ivs: [IV] = []
    var subs: [[Subsample]?] = []
    var senc = false
    var saizDefault = 0
    var saizSizes: [UInt8] = []
    var saioOffsets: [Int64] = []
}

private func parseTrak(_ trak: Box, moovOffset: Int64, fetch: Fetch?) async throws -> [Sample] {
    guard let stbl = trak.find("mdia", "minf", "stbl") else { return [] }
    guard let stsd = stbl.find("stsd"), stsd.bodyCount >= 8 else { return [] }
    guard let entry = Box.parse(stsd.buf, at: stsd.bodyAt + 8, limit: stsd.end) else { return [] }
    let buf = entry.buf
    var start: Int
    switch entry.type {
    case "encv":
        start = 78
    case "enca":
        start = 28
        if entry.bodyCount >= 10 {
            switch be16(buf.bytes, entry.bodyAt + 8) { // QuickTime sound versions
            case 1: start += 16
            case 2: start += 36
            default: break
            }
        }
    default:
        return [] // a clear track
    }
    var t = Track()
    var format = ""
    for b in entry.children(from: start) where b.type == "sinf" {
        if let frma = b.find("frma"), frma.bodyCount >= 4 {
            format = fourCC(buf.bytes, frma.bodyAt)
        }
        if let schm = b.find("schm"), schm.bodyCount >= 8 {
            let scheme = fourCC(buf.bytes, schm.bodyAt + 4)
            if scheme != "cenc" {
                throw CENCError("cenc: scheme \"\(scheme)\" is not supported")
            }
        }
        guard let tenc = b.find("schi", "tenc"), tenc.bodyCount >= 24 else {
            throw CENCError("cenc: no tenc box")
        }
        let body = tenc.body
        t.isProtected = body[body.startIndex + 6] != 0
        t.ivSize = Int(body[body.startIndex + 7])
        if t.isProtected && t.ivSize == 0 && body.count >= 25 {
            let n = Int(body[body.startIndex + 24])
            if body.count >= 25 + n {
                t.constIV = body[(body.startIndex + 25)..<(body.startIndex + 25 + n)]
            }
        }
        b.rename("free")
    }
    if format.isEmpty {
        throw CENCError("cenc: no original format")
    }
    entry.rename(format)
    if !t.isProtected {
        return []
    }

    var stsc: [UInt32] = []
    for b in stbl.children() {
        let body = b.body
        let p0 = body.startIndex
        switch b.type {
        case "stsz":
            guard body.count >= 12 else { throw CENCError("cenc: bad stsz") }
            let fixed = be32(buf.bytes, p0 + 4), n = Int(be32(buf.bytes, p0 + 8))
            t.sizes = (0..<n).map { k in
                if fixed != 0 { return fixed }
                return 12 + 4 * k + 4 <= body.count ? be32(buf.bytes, p0 + 12 + 4 * k) : 0
            }
        case "stsc":
            guard body.count >= 8 else { throw CENCError("cenc: bad stsc") }
            let n = Int(be32(buf.bytes, p0 + 4))
            var k = 0
            while k < n && 8 + 12 * k + 12 <= body.count {
                let e = p0 + 8 + 12 * k
                stsc += [be32(buf.bytes, e), be32(buf.bytes, e + 4)]
                k += 1
            }
        case "stco", "co64":
            guard body.count >= 8 else { throw CENCError("cenc: bad \(b.type)") }
            let n = Int(be32(buf.bytes, p0 + 4))
            let w = b.type == "co64" ? 8 : 4
            t.offsets = []
            t.offsets.reserveCapacity(n)
            var k = 0
            while k < n && 8 + w * k + w <= body.count {
                let e = p0 + 8 + w * k
                t.offsets.append(w == 4 ? Int64(be32(buf.bytes, e)) : Int64(bitPattern: be64(buf.bytes, e)))
                k += 1
            }
        case "senc":
            try parseSenc(&t, body)
            b.rename("free")
        case "saiz":
            guard body.count >= 4 else { throw CENCError("cenc: bad saiz") }
            var p = 4
            if body[p0 + 3] & 1 != 0 {
                p += 8
            }
            guard body.count >= p + 5 else { throw CENCError("cenc: bad saiz") }
            t.saizDefault = Int(body[p0 + p])
            let n = Int(be32(buf.bytes, p0 + p + 1))
            if t.saizDefault == 0 && body.count >= p + 5 + n {
                t.saizSizes = Array(body[(p0 + p + 5)..<(p0 + p + 5 + n)])
            }
            b.rename("free")
        case "saio":
            guard body.count >= 4 else { throw CENCError("cenc: bad saio") }
            var p = 4
            if body[p0 + 3] & 1 != 0 {
                p += 8
            }
            guard body.count >= p + 4 else { throw CENCError("cenc: bad saio") }
            let n = Int(be32(buf.bytes, p0 + p))
            let w = body[p0] == 1 ? 8 : 4
            var k = 0
            while k < n && p + 4 + w * k + w <= body.count {
                let e = p0 + p + 4 + w * k
                t.saioOffsets.append(w == 4 ? Int64(be32(buf.bytes, e)) : Int64(bitPattern: be64(buf.bytes, e)))
                k += 1
            }
            b.rename("free")
        default:
            break
        }
    }
    if !t.senc {
        try await readAux(&t, moov: buf.bytes, moovOffset: moovOffset, fetch: fetch)
    }
    return try addSamples(t, stsc: stsc)
}

private func parseSenc(_ t: inout Track, _ body: ArraySlice<UInt8>) throws {
    guard body.count >= 8 else { throw CENCError("cenc: bad senc") }
    t.senc = true
    let bytes = Array(body)
    let flags = be32(bytes, 0) & 0xffffff
    let n = Int(be32(bytes, 4))
    _ = try readInfo(&t, bytes[8...], count: n, subsamples: flags & 2 != 0, sizes: nil)
}

/// Reads `count` samples' IVs, and their subsamples when `subsamples`,
/// from `b`. `sizes`, when given, is each sample's info size, which says
/// whether it has subsamples.
@discardableResult
private func readInfo(_ t: inout Track, _ b: ArraySlice<UInt8>, count n: Int, subsamples: Bool,
                      sizes: ((Int) -> Int)?) throws -> Int {
    let base = b.startIndex
    var p = 0
    t.ivs = Array(repeating: IV(), count: n)
    t.subs = Array(repeating: nil, count: n)
    for k in 0..<n {
        let start = p
        if t.ivSize > 0 {
            guard p + t.ivSize <= b.count else { throw CENCError("cenc: sample info is short") }
            t.ivs[k] = IV(b[(base + p)..<(base + p + t.ivSize)])
            p += t.ivSize
        } else {
            t.ivs[k] = IV(t.constIV)
        }
        var has = subsamples
        if let sizes {
            has = sizes(k) > t.ivSize
        }
        if has {
            guard p + 2 <= b.count else { throw CENCError("cenc: subsample count is short") }
            let m = Int(UInt16(b[base + p]) << 8 | UInt16(b[base + p + 1]))
            p += 2
            guard p + 6 * m <= b.count else { throw CENCError("cenc: subsamples are short") }
            var subs: [Subsample] = []
            subs.reserveCapacity(m)
            for _ in 0..<m {
                let clear = UInt32(b[base + p]) << 8 | UInt32(b[base + p + 1])
                let enc = UInt32(b[base + p + 2]) << 24 | UInt32(b[base + p + 3]) << 16
                    | UInt32(b[base + p + 4]) << 8 | UInt32(b[base + p + 5])
                subs.append(Subsample(clear: clear, encrypted: enc))
                p += 6
            }
            t.subs[k] = subs
        }
        if let sizes {
            p = start + sizes(k)
        }
    }
    return p
}

/// Reads the sample info that saiz sizes and saio places, inside moov or
/// through fetch.
private func readAux(_ t: inout Track, moov: [UInt8], moovOffset: Int64, fetch: Fetch?) async throws {
    guard t.saioOffsets.count == 1 else { throw CENCError("cenc: no sample encryption info") }
    let n = t.sizes.count
    let saizDefault = t.saizDefault, saizSizes = t.saizSizes, ivSize = t.ivSize
    let size: (Int) -> Int = { k in
        if saizDefault != 0 { return saizDefault }
        if k < saizSizes.count { return Int(saizSizes[k]) }
        return ivSize
    }
    var total = 0
    for k in 0..<n {
        total += size(k)
    }
    let off = t.saioOffsets[0]
    let b: ArraySlice<UInt8>
    if off >= moovOffset && off + Int64(total) <= moovOffset + Int64(moov.count) {
        let a = Int(off - moovOffset)
        b = moov[a..<(a + total)]
    } else if let fetch {
        b = try await fetch(off, Int64(total))[...]
    } else {
        throw CENCError("cenc: sample info is outside moov")
    }
    try readInfo(&t, b, count: n, subsamples: false, sizes: size)
}

/// Places the track's samples in the file from its chunks.
private func addSamples(_ t: Track, stsc: [UInt32]) throws -> [Sample] {
    guard !stsc.isEmpty, !t.offsets.isEmpty else { throw CENCError("cenc: no chunks") }
    guard t.ivs.count >= t.sizes.count else {
        throw CENCError("cenc: \(t.ivs.count) IVs for \(t.sizes.count) samples")
    }
    var out: [Sample] = []
    out.reserveCapacity(t.sizes.count)
    var k = 0
    var e = 0
    while e < stsc.count {
        let first = Int(stsc[e]) - 1, per = Int(stsc[e + 1])
        var last = t.offsets.count
        if e + 2 < stsc.count {
            last = Int(stsc[e + 2]) - 1
        }
        var chunk = max(first, 0)
        while chunk < last && chunk < t.offsets.count {
            var off = t.offsets[chunk]
            var j = 0
            while j < per && k < t.sizes.count {
                out.append(Sample(offset: off, size: t.sizes[k], iv: t.ivs[k], subsamples: t.subs[k]))
                off += Int64(t.sizes[k])
                k += 1
                j += 1
            }
            chunk += 1
        }
        e += 2
    }
    if k != t.sizes.count {
        throw CENCError("cenc: chunks hold \(k) of \(t.sizes.count) samples")
    }
    return out
}

// MARK: - Boxes

/// Buffer is the moov box, shared by the boxes inside it, which rename
/// themselves in place.
final class Buffer {
    var bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var count: Int { bytes.count }
}

/// Box is an MP4 box inside a buffer that it can rename in place.
struct Box {
    let buf: Buffer
    let at: Int // the header
    let bodyAt: Int
    let end: Int
    let type: String

    var bodyCount: Int { end - bodyAt }
    /// The body, indexed as the buffer is.
    var body: ArraySlice<UInt8> { buf.bytes[bodyAt..<end] }

    /// Reads the box at `at`, which must end by `limit`.
    static func parse(_ buf: Buffer, at: Int, limit: Int) -> Box? {
        guard at + 8 <= limit else { return nil }
        var size = Int(be32(buf.bytes, at))
        var hdr = 8
        if size == 1 {
            guard at + 16 <= limit else { return nil }
            let big = be64(buf.bytes, at + 8)
            guard big <= UInt64(Int.max) else { return nil }
            size = Int(big)
            hdr = 16
        } else if size == 0 {
            size = limit - at
        }
        guard size >= hdr, at + size <= limit else { return nil }
        return Box(buf: buf, at: at, bodyAt: at + hdr, end: at + size, type: fourCC(buf.bytes, at + 4))
    }

    func children() -> [Box] { children(from: 0) }

    /// Lists the boxes in the body from byte `start` of it on.
    func children(from start: Int) -> [Box] {
        var out: [Box] = []
        var at = bodyAt + start
        while at < end, let c = Box.parse(buf, at: at, limit: end) {
            out.append(c)
            at = c.end
        }
        return out
    }

    /// Follows a path of child box types.
    func find(_ path: String...) -> Box? {
        var cur = self
        for type in path {
            guard let next = cur.children().first(where: { $0.type == type }) else { return nil }
            cur = next
        }
        return cur
    }

    func rename(_ type: String) {
        let t = Array(type.utf8)
        guard t.count == 4 else { return }
        buf.bytes.replaceSubrange((at + 4)..<(at + 8), with: t)
    }
}

// MARK: - Bytes

func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
    UInt16(b[i]) << 8 | UInt16(b[i + 1])
}

func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}

func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
}

func fourCC(_ b: [UInt8], _ i: Int) -> String {
    String(decoding: b[i..<(i + 4)], as: UTF8.self)
}
