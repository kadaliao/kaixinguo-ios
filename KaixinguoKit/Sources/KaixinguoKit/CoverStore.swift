import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// CoverStore downloads posters once, keeps them on disk as JPEG, scaled
/// down, and in memory as bitmaps while there is room. The CDN serves
/// HEIC, which ImageIO reads on every Apple system.
public final class CoverStore: Sendable {
    /// The longest side covers are kept at, in pixels: a grid's poster on a
    /// 3× screen, or the series page's.
    static let maxPixels = 600

    let dir: URL
    // NSCache is safe to use from any thread.
    nonisolated(unsafe) private let memory: NSCache<NSString, Cover>
    private let session: URLSession
    private let loading = Mutex<[String: Task<Cover?, Never>]>([:])

    /// Cover is a decoded poster, shareable between threads.
    final class Cover: Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = NSCache<NSString, Cover>()
        cache.totalCostLimit = 96 << 20
        memory = cache
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil // the store is the cache
        session = URLSession(configuration: config)
    }

    /// The cover at `raw` if memory has it: views show it at once, without
    /// a fade.
    public func cached(_ raw: String) -> CGImage? {
        memory.object(forKey: Self.key(raw) as NSString)?.image
    }

    /// The cover at `raw`, from memory, the disk or the CDN.
    public func image(_ raw: String) async -> CGImage? {
        guard !raw.isEmpty else { return nil }
        let k = Self.key(raw)
        if let c = memory.object(forKey: k as NSString) {
            return c.image
        }
        let task = loading.withLock { tasks in
            if let t = tasks[k] {
                return t
            }
            let t = Task.detached(priority: .userInitiated) { [self] in await load(k, raw) }
            tasks[k] = t
            return t
        }
        let cover = await task.value
        loading.withLock { _ = $0.removeValue(forKey: k) }
        if let cover {
            memory.setObject(cover, forKey: k as NSString, cost: cover.image.bytesPerRow * cover.image.height)
        }
        return cover?.image
    }

    /// The cover's JPEG, if the disk has it.
    public func jpegData(_ raw: String) -> Data? {
        try? Data(contentsOf: file(Self.key(raw)))
    }

    /// Names a cover by its URL without the query, whose signature changes
    /// from one response to the next.
    static func key(_ raw: String) -> String {
        var name = raw
        if let u = URLComponents(string: raw) {
            name = (u.host ?? "") + u.path
        }
        return Insecure.SHA1.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ k: String) -> URL { dir.appendingPathComponent(k + ".jpg") }

    private func load(_ k: String, _ raw: String) async -> Cover? {
        let path = file(k)
        if let src = CGImageSourceCreateWithURL(path as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return Cover(img)
        }
        guard let url = URL(string: raw),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        save(img, to: path)
        return Cover(img)
    }

    private func save(_ img: CGImage, to path: URL) {
        let tmp = path.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            _ = try? FileManager.default.replaceItemAt(path, withItemAt: tmp)
        }
    }
}
