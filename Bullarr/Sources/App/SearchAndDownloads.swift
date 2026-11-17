import Foundation
import SwiftUI

/// Tome visé quand la recherche part d'une fiche série : rattache le téléchargement à ce tome.
// (SearchContext est défini dans AppState.swift.)

enum SourceState {
    case loading
    case done([SearchResult])
    case failed(String)
}

@MainActor
final class SearchState: ObservableObject {
    @Published var title = ""
    @Published var volume = ""
    @Published var context: SearchContext?
    @Published var enabledSources: [String: Bool]
    @Published var sources: [String: SourceState] = [:]
    /// Sections repliées dans la liste des résultats (gardé d'une recherche à l'autre).
    @Published var collapsed: [String: Bool] = [:]
    @Published private(set) var lastQuery: String?

    private var tasks: [Task<Void, Never>] = []
    private let apiProvider: () -> BullarrApi?

    init(apiProvider: @escaping () -> BullarrApi?) {
        self.apiProvider = apiProvider
        enabledSources = Dictionary(uniqueKeysWithValues: SEARCH_SOURCES.map { ($0.0, true) })
    }

    func prefill(_ ctx: SearchContext) {
        context = ctx
        title = ctx.seriesTitle
        volume = ctx.volumeNumber.map { "\($0)" } ?? ""
        search()
    }

    func clearContext() { context = nil }

    func search() {
        guard let client = apiProvider() else { return }
        let t = title.trimmed
        if t.isEmpty { return }
        // Un autre titre que la série visée : nouvelle recherche, plus rattachée à cette série.
        if let ctx = context, t != ctx.seriesTitle { context = nil }
        tasks.forEach { $0.cancel() }
        tasks = []
        sources.removeAll()
        let vol = Int(volume.trimmed)
        let ctx = context
        // Un numéro de tome visé ne garde que les résultats de ce tome (pas une intégrale, un HS ou un épisode).
        let onlyThisTome = vol != nil && (ctx == nil || (!ctx!.isIntegral && !ctx!.isHs && !ctx!.isEpisode))
        lastQuery = [t, vol.map { "tome \($0)" }].compactMap { $0 }.joined(separator: " · ")
        tasks = SEARCH_SOURCES.filter { enabledSources[$0.0] == true }.map { (source, _) -> Task<Void, Never> in
            let key = source
            sources[key] = .loading
            return Task { [weak self] in
                var body: JSONDict = ["title": t, "volume_num": vol ?? NSNull(), "sources": [key]]
                if let ctx = ctx {
                    body["series_id"] = ctx.seriesId
                    body["is_integral"] = ctx.isIntegral
                    body["is_hs"] = ctx.isHs
                    body["is_episode"] = ctx.isEpisode
                }
                do {
                    let o = try await client.postObject("api/missing-monitor/search", body)
                    var results = parseSearchResults(o)
                    // Tomes confirmés d'abord ; l'ordre du serveur est gardé dans chaque groupe.
                    if onlyThisTome, let v = vol { results = results.filter { $0.volumeNumber == v } }
                    results = results.enumerated().sorted { a, b in
                        let aBad = a.element.unconfirmed != nil
                        let bBad = b.element.unconfirmed != nil
                        if aBad != bBad { return !aBad }
                        return a.offset < b.offset
                    }.map(\.element)
                    self?.sources[key] = .done(results)
                } catch {
                    self?.sources[key] = .failed(readable(error))
                }
            }
        }
    }
}

/// Confirmation d'un envoi : fichier, clients possibles, remplacement éventuel.
struct PendingSend {
    let job: DownloadJob
    let context: String?
    let warning: String?
    let clients: [DownloadClient]
    var chosen: DownloadClient?
    let replace: Bool
}

/**
 * Envoi de fichiers aux clients de Bullarr, partagé par Recherche et Nouveautés.
 * Un client torrent n'est proposé que s'il est activé dans Bullarr (même règle que nav.js).
 */
@MainActor
final class DownloadController: ObservableObject {
    @Published var choices: (title: String, jobs: [(job: DownloadJob, note: String?)])?
    @Published var pending: PendingSend?
    @Published private(set) var sending = false
    /// Fichiers envoyés pendant cette session : clé → client.
    @Published var sent: [String: String] = [:]
    /// ⚡ en attente de confirmation (Nouveautés).
    @Published var quick: NewsItem?

    /// Callback snackbar fourni par la racine de l'app.
    var showSnackbar: ((String) -> Void)?

    private var torrentClients: [DownloadClient]?
    private var qbCategory: String?

    private let apiProvider: () -> BullarrApi?

    init(apiProvider: @escaping () -> BullarrApi?) {
        self.apiProvider = apiProvider
    }

    private func enabledTorrentClients(_ client: BullarrApi) async -> [DownloadClient] {
        if let torrentClients { return torrentClients }
        var found: [DownloadClient] = []
        for c in TORRENT_CLIENTS {
            if let cfg = try? await client.getObject("api/\(c.key)/config"), cfg.bool("enabled") == true {
                if c.key == "qbittorrent" { qbCategory = cfg.str("default_category") }
                found.append(c)
            }
        }
        torrentClients = found
        return found
    }

    /// Plusieurs fichiers (fil EBDZ) : on choisit d'abord lequel. Le second élément est une note (« Possédé »).
    func choose(_ title: String, _ jobs: [(DownloadJob, String?)]) {
        if jobs.count == 1 { request(jobs[0].0) } else { choices = (title, jobs) }
    }

    func request(_ job: DownloadJob, context: String? = nil, warning: String? = nil) {
        guard let client = apiProvider() else { return }
        choices = nil
        Task {
            let clients: [DownloadClient]
            if let fixed = fixedClient(job) { clients = [fixed] } else { clients = await enabledTorrentClients(client) }
            if clients.isEmpty {
                showSnackbar?("Aucun client torrent activé dans Bullarr (Paramètres → clients de téléchargement).")
                return
            }
            // Fichier déjà présent : on le remplace, en visant le tome existant.
            let rep = await replacementRequired(client, job)
            var target = job
            if rep?.hasFile == true && job.tracking.volumeId == nil && rep?.volumeId != nil {
                var t = job.tracking
                t.volumeId = rep?.volumeId
                target = job.withTracking(t)
            }
            pending = PendingSend(job: target, context: context, warning: warning, clients: clients, chosen: clients.count == 1 ? clients[0] : nil, replace: rep?.hasFile == true)
        }
    }

    /**
     * ⚡ « Ajouter la série et télécharger » (addSeriesAndDownloadNouveautes, ebdz-latest.js) :
     * crée la série depuis Bédéthèque si Bullarr ne la connaît pas, ou l'envoie en
     * validation si aucune fiche ne correspond, puis télécharge la release.
     */
    func runQuick() {
        guard let item = quick, let client = apiProvider() else { return }
        quick = nil
        let known = item.seriesId != nil
        showSnackbar?("« \(item.seriesTitle) » : " + (known ? "envoi en cours…" : "ajout de la série en cours…"))
        Task {
            do {
                var seriesId: Int? = item.seriesId
                if seriesId == nil {
                    do {
                        seriesId = try await resolveSeries(client, item)
                    } catch {
                        var queued = false
                        do { try await queueReview(client, item, readable(error)); queued = true } catch {}
                        showSnackbar?("« \(item.seriesTitle) » : \(readable(error))" + (queued ? " Envoyé en validation." : ""))
                        return
                    }
                }
                let dest = try await downloadRelease(client, item, seriesId!)
                showSnackbar?("« \(item.seriesTitle) » : " + (known ? "" : "série ajoutée, ") + "téléchargement envoyé à \(dest).")
            } catch {
                showSnackbar?("« \(item.seriesTitle) » : \(readable(error))")
            }
        }
    }

    private func resolveSeries(_ client: BullarrApi, _ item: NewsItem) async throws -> Int {
        var url = item.bedethequeUrl.flatMap { $0.hasPrefix("https://www.bedetheque.com/") ? $0 : nil }
        if url == nil {
            let info = try await client.getObject("api/bedetheque/info", query: ["title": item.seriesTitle, "raw": item.rawHint])
            guard let u = info.dict("info")?.str("url") else {
                throw ApiException(info.str("error") ?? "Aucune fiche Bédéthèque confirmée")
            }
            url = u
        }
        let libraries = parseLibraries(try await client.getArray("api/libraries"))
        guard let libraryId = libraries.first?.id else { throw ApiException("Aucune bibliothèque disponible") }
        let added = try await client.postObject("api/bedetheque/add-series", ["url": url!, "library_id": libraryId, "skip_auto_acquire": true])
        guard let id = added.int("series_id") else { throw ApiException("Ajout de la série impossible") }
        return id
    }

    private func queueReview(_ client: BullarrApi, _ item: NewsItem, _ reason: String) async throws {
        let first = item.files.first { !$0.owned }?.job
        var candidate: JSONDict = [
            "source": item.type == .rss ? "prowlarr" : item.type.rawValue.lowercased(),
            "title": item.title,
            "filename": first?.name ?? item.title,
            "info_url": item.link ?? "",
            "bedetheque_url": (item.bedethequeUrl.flatMap { $0.hasPrefix("https://www.bedetheque.com/") ? $0 : nil }) ?? NSNull(),
        ]
        switch first {
        case .torrent(let url, _, _): candidate["link"] = url
        case .vk(let url, _, _): candidate["link"] = url
        case .ed2k(let link, _, _): candidate["link"] = link
        case .telegram(let channel, let messageId, let channelTitle, _, _):
            candidate["channel"] = channel
            candidate["message_id"] = messageId
            candidate["channel_title"] = channelTitle ?? ""
        default: break
        }
        try await client.postObject("api/auto-acquire/reviews/series-match", [
            "series_title": item.seriesTitle,
            "candidates": [candidate],
            "reason": reason,
        ])
    }

    private func downloadRelease(_ client: BullarrApi, _ item: NewsItem, _ seriesId: Int) async throws -> String {
        func tracked(_ job: DownloadJob) -> DownloadJob {
            var t = job.tracking
            t.seriesId = seriesId
            return job.withTracking(t)
        }
        switch item.type {
        case .ebdz:
            // Un fichier par tome, sans ceux déjà possédés (comme _downloadNouveautesRelease).
            var seen = Set<String>()
            let files = item.files.filter { f in
                if f.owned { return false }
                guard let label = f.volumeLabel else { return true }
                return seen.insert(label).inserted
            }
            if files.isEmpty { throw ApiException("Aucun fichier à télécharger : tout est déjà possédé") }
            for f in files {
                let job = tracked(f.job)
                guard let dest = fixedClient(job) else { throw ApiException("Client absent pour \(job.name)") }
                try await sendDownload(client, job, dest, false, nil)
                sent[job.key] = "aMule"
            }
            return files.count > 1 ? "aMule (\(files.count) fichiers)" : "aMule"
        case .telegram, .rss:
            var job = item.files.first.map { tracked($0.job) }
            if job == nil {
                do { job = (try await findProwlarrRelease(client, item)).map { tracked($0) } } catch {}
            }
            guard let j = job else { throw ApiException("Lien de téléchargement introuvable pour cette release") }
            let target: DownloadClient?
            if let fixed = fixedClient(j) { target = fixed } else { target = (await enabledTorrentClients(client)).first }
            guard let target else { throw ApiException("Aucun client torrent activé") }
            try await sendDownload(client, j, target, false, qbCategory)
            sent[j.key] = target.label
            return target.label
        }
    }

    /// Release RSS sans lien direct : retrouvée par recherche Prowlarr exacte (_resolveRssTorrentUrl).
    private func findProwlarrRelease(_ client: BullarrApi, _ item: NewsItem) async throws -> DownloadJob? {
        let res = try await client.getObject("api/search/prowlarr", query: ["q": item.seriesTitle])
        let rows = res.objects("results")
        let exact = rows.filter { ($0.str("title") ?? "").caseInsensitiveCompare(item.title) == .orderedSame }
        let pageLink = item.raw.str("link")
        let release: JSONDict? = pageLink != nil ? exact.first { $0.str("info_url") == pageLink } : (exact.count == 1 ? exact[0] : nil)
        guard let r = release, let dl = r.str("download_url") else { return nil }
        return .torrent(url: dl, name: item.title, tracking: Tracking(sourceLink: pageLink))
    }

    func confirm() {
        guard let p = pending, let target = p.chosen, let client = apiProvider() else { return }
        pending = nil
        Task {
            do {
                try await sendDownload(client, p.job, target, p.replace, qbCategory)
                sent[p.job.key] = target.label
                showSnackbar?("Envoyé à \(target.label) — suivez-le dans Activité.")
            } catch {
                showSnackbar?(readable(error))
            }
        }
    }
}
