import Foundation
import UIKit

struct ReaderMeta: Hashable {
    let volumeId: Int
    let seriesTitle: String?
    let label: String?
    let title: String?
    let pageCount: Int
    let seriesId: Int?
    /// Avancement Komga renvoyé par le serveur : page à reprendre (1-based) et album lu en entier.
    let resumePage: Int?
    let readCompleted: Bool
}

func parseReaderMeta(_ volumeId: Int, _ o: JSONDict) throws -> ReaderMeta {
    guard let pageCount = o.int("page_count") else {
        throw ApiException("GET /api/volumes/\(volumeId)/reader : le nombre de pages est absent de la réponse.")
    }
    return ReaderMeta(
        volumeId: volumeId, seriesTitle: o.str("series_title"), label: o.str("label"), title: o.str("title"),
        pageCount: pageCount,
        seriesId: o.int("series_id"),
        resumePage: { let p = o.int("resume_page") ?? 0; return p > 0 ? p : nil }(),
        readCompleted: o.bool("read_completed") == true,
    )
}

/**
 * Albums copiés sur l'appareil pour la lecture hors ligne : les pages telles que le lecteur de
 * Bullarr les sert (GET /api/volumes/<id>/reader/page/<n>). Un album n'est « complet » qu'une
 * fois meta.json écrit, en dernier.
 */
final class OfflineStore: @unchecked Sendable {
    struct Item { let meta: ReaderMeta; let sizeBytes: Int64; let savedAt: Date }

    let root: URL

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func dir(_ id: Int) -> URL { root.appendingPathComponent("\(id)", isDirectory: true) }
    func pageFile(_ id: Int, _ page: Int) -> URL { dir(id).appendingPathComponent("\(page).img") }

    func hasPage(_ id: Int, _ page: Int) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: pageFile(id, page).path)
        return (attrs?[.size] as? Int64 ?? 0) > 0
    }

    func pagesOnDisk(_ id: Int) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir(id), includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "img" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
            .count ?? 0
    }

    func metaOf(_ id: Int) -> ReaderMeta? {
        guard let data = try? Data(contentsOf: dir(id).appendingPathComponent("meta.json")),
              let o = try? JSONSerialization.jsonObject(with: data) as? JSONDict, o.bool("complete") == true,
              let savedAt = o.double("saved_at")
        else { return nil }
        guard let meta = try? parseReaderMeta(o.int("volume_id") ?? id, o) else { return nil }
        return meta
    }

    func savedAt(_ id: Int) -> Date {
        guard let data = try? Data(contentsOf: dir(id).appendingPathComponent("meta.json")),
              let o = try? JSONSerialization.jsonObject(with: data) as? JSONDict,
              let t = o.double("saved_at")
        else { return .distantPast }
        return Date(timeIntervalSince1970: t)
    }

    func sizeOf(_ id: Int) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(id), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { acc, f in acc + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func list() -> [Item] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d -> Item? in
            guard let id = Int(d.lastPathComponent), let meta = metaOf(id) else { return nil }
            return Item(meta: meta, sizeBytes: sizeOf(id), savedAt: savedAt(id))
        }.sorted { $0.savedAt > $1.savedAt }
    }

    func savePage(_ id: Int, _ page: Int, _ bytes: Data) throws {
        try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        let tmp = dir(id).appendingPathComponent("\(page).tmp")
        try bytes.write(to: tmp)
        let target = pageFile(id, page)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    func saveMeta(_ meta: ReaderMeta) {
        let o: JSONDict = [
            "volume_id": meta.volumeId,
            "series_id": meta.seriesId ?? NSNull(),
            "series_title": meta.seriesTitle ?? NSNull(),
            "label": meta.label ?? NSNull(),
            "title": meta.title ?? NSNull(),
            "page_count": meta.pageCount,
            "complete": true,
            "saved_at": Date().timeIntervalSince1970,
        ]
        try? FileManager.default.createDirectory(at: dir(meta.volumeId), withIntermediateDirectories: true)
        let tmp = dir(meta.volumeId).appendingPathComponent("meta.tmp")
        if let data = try? JSONSerialization.data(withJSONObject: o) {
            try? data.write(to: tmp)
            try? FileManager.default.removeItem(at: dir(meta.volumeId).appendingPathComponent("meta.json"))
            try? FileManager.default.moveItem(at: tmp, to: dir(meta.volumeId).appendingPathComponent("meta.json"))
        }
    }

    func delete(_ id: Int) {
        try? FileManager.default.removeItem(at: dir(id))
    }

    /// Rattache à leur identifiant actuel les copies dont le tome a changé d'id côté Bullarr.
    /// Renvoie le nombre de copies rattachées.
    @discardableResult
    func adopt(_ seriesId: Int, _ current: [(Int, String)]) -> Int {
        let ids = Set(current.map { $0.0 })
        var orphans = list().filter { $0.meta.seriesId == seriesId && !ids.contains($0.meta.volumeId) }
        var n = 0
        for (id, label) in current {
            if metaOf(id) != nil { continue }
            guard let match = orphans.first(where: { $0.meta.label == label }) else { continue }
            let from = dir(match.meta.volumeId)
            let to = dir(id)
            guard !FileManager.default.fileExists(atPath: to.path) else { continue }
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch { continue }
            saveMeta(ReaderMeta(volumeId: id, seriesTitle: match.meta.seriesTitle, label: match.meta.label, title: match.meta.title, pageCount: match.meta.pageCount, seriesId: match.meta.seriesId, resumePage: match.meta.resumePage, readCompleted: match.meta.readCompleted))
            orphans.removeAll { $0.meta.volumeId == match.meta.volumeId }
            n += 1
        }
        return n
    }

    /// Espace libre sur l'appareil, pour prévenir avant un gros téléchargement.
    var freeBytes: Int64 {
        if let v = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage {
            return v
        }
        return 0
    }
}

struct OfflineProgress: Equatable {
    let done: Int
    let total: Int
    var error: String? = nil
    var paused: Bool = false
}

import Combine

/// Téléchargements en cours (tant que l'app est ouverte ; un téléchargement interrompu reprend où il s'était arrêté).
@MainActor
final class OfflineManager: ObservableObject {
    let store = OfflineStore()
    @Published var active: [Int: OfflineProgress] = [:]
    @Published var titles: [Int: String] = [:]
    /// Incrémenté à chaque changement du contenu du disque : les listes se rafraîchissent.
    @Published var version: Int = 0
    @Published var running: Bool = false

    private var jobs: [Int: Task<Void, Never>] = [:]
    private var pausing = Set<Int>()
    private let gate = AsyncSemaphore(3)
    private let apiProvider: () -> BullarrApi?

    init(apiProvider: @escaping () -> BullarrApi?) {
        self.apiProvider = apiProvider
    }

    /// Albums hors ligne par série (id de série, sinon titre pour les copies anciennes sans id).
    func downloadedBySeries() -> ([Int: Int], [String: Int]) {
        _ = version
        let items = store.list()
        var byId = [Int: Int]()
        for i in items.compactMap(\.meta.seriesId) { byId[i, default: 0] += 1 }
        var byTitle = [String: Int]()
        for t in items.filter({ $0.meta.seriesId == nil }).compactMap(\.meta.seriesTitle) { byTitle[t, default: 0] += 1 }
        return (byId, byTitle)
    }

    func adopt(_ seriesId: Int, _ current: [(Int, String)]) {
        Task.detached { [store] in
            if store.adopt(seriesId, current) > 0 {
                await MainActor.run { self.version += 1 }
            }
        }
    }

    func isDownloaded(_ id: Int) -> Bool { _ = version; return store.metaOf(id) != nil }

    func start(_ volumeId: Int, _ title: String) {
        guard let client = apiProvider() else { return }
        if let job = jobs[volumeId], !job.isCancelled { return }
        pausing.remove(volumeId)
        titles[volumeId] = title
        active[volumeId] = OfflineProgress(done: store.pagesOnDisk(volumeId), total: 0)
        running = true
        jobs[volumeId] = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await client.getObject("api/volumes/\(volumeId)/reader")
                let meta = try parseReaderMeta(volumeId, raw)
                let needed = (1...meta.pageCount).filter { !store.hasPage(volumeId, $0) }
                // Prévient avant de remplir le stockage : ~1 Mo par page en moyenne.
                if Int64(needed.count) * 1_500_000 > store.freeBytes {
                    throw ApiException("Pas assez de place sur l'appareil pour \(meta.pageCount) pages.")
                }
                let doneCounter = Counter(start: meta.pageCount - needed.count)
                await MainActor.run { self.active[volumeId] = OfflineProgress(done: doneCounter.current, total: meta.pageCount) }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for n in needed {
                        group.addTask { [gate, store, weak self] in
                            try await gate.withPermit {
                                let bytes = try await client.getBytes("api/volumes/\(volumeId)/reader/page/\(n)")
                                try store.savePage(volumeId, n, bytes)
                            }
                            let v = doneCounter.increment()
                            await MainActor.run { self?.active[volumeId] = OfflineProgress(done: v, total: meta.pageCount) }
                        }
                    }
                    try await group.waitForAll()
                }
                try Task.checkCancellation()
                store.saveMeta(meta)
                await MainActor.run { self.active.removeValue(forKey: volumeId); self.version += 1; self.refreshRunning() }
            } catch is CancellationError {
                await MainActor.run {
                    // Pause : l'entrée reste, avec les pages déjà reçues ; sinon l'arrêt la retire.
                    if pausing.contains(volumeId) {
                        let p = active[volumeId] ?? OfflineProgress(done: 0, total: 0)
                        active[volumeId] = OfflineProgress(done: p.done, total: p.total, error: nil, paused: true)
                    } else {
                        active.removeValue(forKey: volumeId)
                    }
                    pausing.remove(volumeId)
                    jobs.removeValue(forKey: volumeId)
                    refreshRunning()
                }
            } catch {
                await MainActor.run {
                    let p = active[volumeId] ?? OfflineProgress(done: 0, total: 0)
                    active[volumeId] = OfflineProgress(done: p.done, total: p.total, error: readable(error), paused: false)
                    jobs.removeValue(forKey: volumeId)
                    refreshRunning()
                }
            }
        }
    }

    /// Met en pause : les pages reçues sont gardées, [start] reprend où le téléchargement s'était arrêté.
    func pause(_ volumeId: Int) {
        guard let p = active[volumeId], p.error == nil, !p.paused else { return }
        pausing.insert(volumeId)
        active[volumeId] = OfflineProgress(done: p.done, total: p.total, error: nil, paused: true)
        jobs.removeValue(forKey: volumeId)?.cancel()
        refreshRunning()
    }

    func resume(_ volumeId: Int) {
        if active[volumeId]?.paused == true { start(volumeId, titles[volumeId] ?? "Album \(volumeId)") }
    }

    /// Arrête le téléchargement ; les pages déjà reçues sont gardées pour reprendre.
    func cancel(_ volumeId: Int) {
        pausing.remove(volumeId)
        jobs.removeValue(forKey: volumeId)?.cancel()
        jobs.removeValue(forKey: volumeId)
        active.removeValue(forKey: volumeId)
        refreshRunning()
    }

    func delete(_ volumeId: Int) {
        cancel(volumeId)
        Task.detached { [store] in
            store.delete(volumeId)
            await MainActor.run { self.version += 1 }
        }
    }

    /// Sommes pour la notification : albums en cours, pages faites au total, en pause.
    func runningState() -> (count: Int, done: Int, total: Int, paused: Int) {
        let r = active.values.filter { $0.error == nil && !$0.paused }
        let p = active.values.filter { $0.error == nil && $0.paused }
        return (r.count, (r + p).reduce(0) { $0 + $1.done }, (r + p).reduce(0) { $0 + $1.total }, p.count)
    }

    private func refreshRunning() {
        running = active.values.contains { $0.error == nil && !$0.paused }
    }
}

/// Sémaphore asynchrone bornant le nombre de téléchargements parallèles.
actor AsyncSemaphore {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits: Int

    init(_ permits: Int) { self.permits = permits }

    func acquire() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        permits += 1
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            permits -= 1
            w.resume()
        }
    }
}

extension AsyncSemaphore {
    func withPermit<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let v = try await body()
            release()
            return v
        } catch {
            release()
            throw error
        }
    }
}

/// Compteur thread-safe pour l'avancement.
final class Counter: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()
    init(start: Int) { value = start }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    var v: Int { current }
    /// Alias lisible de current.
    var val: Int { current }
    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
