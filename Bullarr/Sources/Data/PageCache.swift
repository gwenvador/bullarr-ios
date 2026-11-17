import Foundation
import UIKit

/**
 * Pages du lecteur : GET /api/volumes/<id>/reader/page/<n> (images de ~1 Mo, 1920×2650).
 * Cache en mémoire borné en octets, téléchargements dédoublonnés, 3 à la fois.
 */
final class PageCache: @unchecked Sendable {
    static let shared = PageCache()

    /// Au-delà, l'image est réduite : le rendu à l'écran n'en a pas besoin et la mémoire non plus.
    private let maxSide = 3200

    private let lock = NSLock()
    private var cache: LRUCache<UIImage>!
    private var inflight: [String: Task<UIImage, Error>] = [:]
    private let gate = AsyncSemaphore(3)

    // Miniatures : petites images (≈ 300 px) dérivées des pages, cache à part et plus léger.
    private var thumbs: LRUCache<UIImage>!
    private let thumbGate = AsyncSemaphore(2)
    private let thumbSide = 320

    private init() {
        // Les bitmaps vivent côté GPU : on peut en garder davantage (160 Mo côté Android).
        cache = LRUCache(limitBytes: 160 * 1024 * 1024, sizeOf: { $0.pixelBytes })
        thumbs = LRUCache(limitBytes: 24 * 1024 * 1024, sizeOf: { $0.pixelBytes })
    }

    private func key(_ volumeId: Int, _ page: Int) -> String { "\(volumeId):\(page)" }

    func cached(_ volumeId: Int, _ page: Int) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache.get(key(volumeId, page))
    }

    func get(_ api: BullarrApi, _ volumeId: Int, _ page: Int, offline: OfflineStore? = nil) async throws -> UIImage {
        let k = key(volumeId, page)
        lock.lock()
        if let img = cache.get(k) { lock.unlock(); return img }
        let existing = inflight[k]
        lock.unlock()
        if let existing { return try await existing.value }
        let task = Task<UIImage, Error> {
            try await self.gate.withPermit {
                // Copie hors ligne d'abord : aucun réseau nécessaire.
                if let offline = offline {
                    let f = offline.pageFile(volumeId, page)
                    if let data = try? Data(contentsOf: f), data.count > 0,
                       let img = decode(data, page: page) { return img }
                }
                let bytes = try await api.getBytes("api/volumes/\(volumeId)/reader/page/\(page)")
                guard let img = decode(bytes, page: page) else {
                    throw ApiException("Page \(page) : l'image reçue est illisible (\(bytes.count) octets).")
                }
                return img
            }
        }
        lock.lock()
        inflight[k] = task
        lock.unlock()
        defer {
            lock.lock(); inflight.removeValue(forKey: k); lock.unlock()
        }
        let img = try await task.value
        lock.lock(); cache.put(k, img); lock.unlock()
        return img
    }

    private func decode(_ bytes: Data, page: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(src) > 0
        else { return nil }
        // Décodage réduit directement au chargement (équivalent d'inSampleSize).
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Miniature d'une page : page déjà en mémoire, copie hors ligne, miniature du serveur ou, à défaut, page réduite.
    func thumb(_ api: BullarrApi, _ volumeId: Int, _ page: Int, offline: OfflineStore? = nil) async throws -> UIImage {
        let k = key(volumeId, page)
        lock.lock()
        if let img = thumbs.get(k) { lock.unlock(); return img }
        lock.unlock()
        return try await thumbGate.withPermit {
            lock.lock()
            if let img = thumbs.get(k) { lock.unlock(); return img }
            lock.unlock()
            let small: UIImage
            lock.lock()
            let full = cache.get(k)
            lock.unlock()
            if let full {
                small = downsample(full, maxSide: thumbSide) ?? full
            } else {
                let bytes: Data
                if let offline = offline {
                    let f = offline.pageFile(volumeId, page)
                    if let data = try? Data(contentsOf: f), data.count > 0 {
                        bytes = data
                    } else {
                        // Miniature servie par Bullarr ; à défaut (serveur plus ancien), la page entière.
                        if let tb = try? await api.getBytes("api/volumes/\(volumeId)/reader/thumb/\(page)") {
                            bytes = tb
                        } else {
                            bytes = try await api.getBytes("api/volumes/\(volumeId)/reader/page/\(page)")
                        }
                    }
                } else {
                    if let tb = try? await api.getBytes("api/volumes/\(volumeId)/reader/thumb/\(page)") {
                        bytes = tb
                    } else {
                        bytes = try await api.getBytes("api/volumes/\(volumeId)/reader/page/\(page)")
                    }
                }
                guard let img = decode(bytes, page: page) else {
                    throw ApiException("Page \(page) : l'image reçue est illisible (\(bytes.count) octets).")
                }
                small = downsample(img, maxSide: thumbSide) ?? img
            }
            lock.lock(); thumbs.put(k, small); lock.unlock()
            return small
        }
    }

    private func downsample(_ img: UIImage, maxSide: Int) -> UIImage? {
        let side = max(img.size.width, img.size.height) * img.scale
        guard side > CGFloat(maxSide) else { return nil }
        let ratio = CGFloat(maxSide) / side
        let size = CGSize(width: img.size.width * ratio, height: img.size.height * ratio)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    func clear() {
        lock.lock()
        thumbs.evictAll()
        for t in inflight.values { t.cancel() }
        inflight.removeAll()
        cache.evictAll()
        lock.unlock()
    }
}

extension UIImage {
    /// Taille mémoire approximative des pixels décodés.
    var pixelBytes: Int {
        guard let cg = cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}

/// Cache LRU borné en octets (équivalent d'android.util.LruCache).
final class LRUCache<Value: AnyObject> {
    private final class Entry { let key: String; let value: Value; let cost: Int
        init(key: String, value: Value, cost: Int) { self.key = key; self.value = value; self.cost = cost }
    }
    private var entries: [Entry] = []
    private var total = 0
    private let limitBytes: Int
    private let sizeOf: (Value) -> Int
    private let lock = NSRecursiveLock()

    init(limitBytes: Int, sizeOf: @escaping (Value) -> Int) {
        self.limitBytes = limitBytes
        self.sizeOf = sizeOf
    }

    func get(_ key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let e = entries.remove(at: i)
        entries.append(e) // MRU à la fin
        return e.value
    }

    func put(_ key: String, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.key == key }) { entries.remove(at: i) }
        entries.append(Entry(key: key, value: value, cost: sizeOf(value)))
        trim()
    }

    func evictAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); total = 0
    }

    private func trim() {
        total = entries.reduce(0) { $0 + $1.cost }
        while total > limitBytes, !entries.isEmpty {
            let e = entries.removeFirst()
            total -= e.cost
        }
    }
}

/// Couvertures servies par Bullarr sous /covers/… (route publique serve_cover). Cache
/// mémoire réduit en taille ; une couverture absente donne simplement nil.
final class CoverLoader: @unchecked Sendable {
    static let shared = CoverLoader()

    private var cache: LRUCache<UIImage>!
    private var failed = Set<String>()
    private let lock = NSLock()
    private let gate = AsyncSemaphore(6)

    // Disque : les octets de chaque couverture, pour ne pas tout retélécharger à chaque lancement.
    private var dir: URL?
    private let maxAgeMs: TimeInterval = 7 * 24 * 3600
    private let maxDiskBytes: Int64 = 250 * 1024 * 1024

    private init() {
        // Mémoire ~64 Mo (1/6 du tas Android ≈ plusieurs dizaines de Mo).
        cache = LRUCache(limitBytes: 64 * 1024 * 1024, sizeOf: { $0.pixelBytes })
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        DispatchQueue.global().async { [weak self] in self?.trim() }
    }

    /// Vide le cache disque (déconnexion, changement de serveur).
    func clearDisk() {
        guard let dir else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    private func fileOf(_ url: String) -> URL? {
        guard let dir else { return nil }
        let h = HexSha1.of(url)
        return dir.appendingPathComponent(h)
    }

    private func trim() {
        guard let dir else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        var total: Int64 = 0
        for f in files {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if total > maxDiskBytes { try? FileManager.default.removeItem(at: f) }
        }
    }

    func cached(_ url: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache.get(url)
    }

    /// [key] sépare une version agrandie de la miniature mise en cache sous [url].
    func load(_ url: String, targetWidthPx: Int, key: String? = nil) async -> UIImage? {
        let k = key ?? url
        lock.lock()
        if let img = cache.get(k) { lock.unlock(); return img }
        let failedAlready = failed.contains(url)
        lock.unlock()
        if failedAlready { return nil }
        return await gate.withPermit {
            if let file = fileOf(url) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                let mod = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let fresh = size > 0 && Date().timeIntervalSince(mod) < maxAgeMs
                var bytes: Data?
                if fresh, let data = try? Data(contentsOf: file) { bytes = data }
                if bytes == nil {
                    // Téléchargement sans auth (route publique /covers/…).
                    var fetched: Data?
                    if let target = URL(string: url) {
                        if let (data, resp) = try? await BullarrApi.sharedClient.data(from: target),
                           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                            fetched = data
                            try? data.write(to: file)
                        }
                    }
                }
                if bytes == nil, let data = try? Data(contentsOf: file) { bytes = data }
                guard let data = bytes, let img = decode(data, targetWidthPx: targetWidthPx) else {
                    lock.lock(); failed.insert(url); lock.unlock()
                    return nil
                }
                lock.lock(); cache.put(k, img); lock.unlock()
                return img
            }
            return nil
        }
    }

    private func decode(_ bytes: Data, targetWidthPx: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetWidthPx * 2,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

import CryptoKit

enum HexSha1 {
    static func of(_ s: String) -> String {
        let digest = CryptoKit.Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
