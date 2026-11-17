import Foundation

// Nouveautés : GET /api/ebdz/rss/latest, /api/telegram-channels/latest, /api/ebdz/latest
// (formats relevés dans ebdz/routes.py, telegram_channels/routes.py et ebdz-latest.js).

enum NewsType: String, Hashable, CaseIterable {
    case rss = "RSS"
    case telegram = "Telegram"
    case ebdz = "EBDZ"
}

struct NewsFile: Equatable { let job: DownloadJob; let volumeLabel: String?; let owned: Bool }

struct NewsItem: Identifiable, Equatable {
    let type: NewsType
    let title: String
    let subtitle: String?
    /// Date affichée et clé de tri, « yyyy-MM-dd HH:mm » à l'heure locale.
    let date: String?
    let source: String?
    let sizeBytes: Int64?
    let inLibrary: Bool
    let owned: Bool
    let downloaded: Bool
    let link: String?
    /// Série Bullarr déjà connue pour cette entrée.
    let seriesId: Int?
    /// Titre de série à ajouter (⚡) et fiche Bédéthèque connue.
    let seriesTitle: String
    let rawHint: String
    let bedethequeUrl: String?
    /// Fichiers téléchargeables (vide : rien à envoyer, ex. flux RSS sans lien).
    let files: [NewsFile]
    /// Lien Prowlarr à retrouver par recherche (release RSS sans lien direct).
    let prowlarrIndexerId: Int?
    let raw: JSONDict

    var id: String { "\(type.rawValue)|\(rawHint)|\(date ?? "")|\(title)" }

    /// Égalité utile pour SwiftUI (diff des flux) : l'identité de l'entrée et ses états affichés.
    static func == (a: NewsItem, b: NewsItem) -> Bool {
        a.id == b.id && a.inLibrary == b.inLibrary && a.owned == b.owned && a.downloaded == b.downloaded
            && a.seriesId == b.seriesId && a.files.map(\.job.key) == b.files.map(\.job.key) && a.files.map(\.owned) == b.files.map(\.owned)
    }
}

private let OUT_FORMAT: [CFString: Any] = [:] // (non utilisé, formatage manuel)

/// ISO avec fuseau (RSS) → heure locale ; sinon on garde les 16 premiers caractères.
func localDate(_ s: String?) -> String? {
    guard let s = s else { return nil }
    // Formats ISO courants : 2024-05-03T10:12:00+02:00 ou avec Z.
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = iso.date(from: s)
    if date == nil {
        iso.formatOptions = [.withInternetDateTime]
        date = iso.date(from: s)
    }
    if date == nil {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        date = f.date(from: s)
    }
    if let date = date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
    return String(s.replacingOccurrences(of: "T", with: " ").prefix(16))
}

private func isTorrentUrl(_ url: String) -> Bool {
    let u = url.lowercased()
    if u.hasPrefix("magnet:") { return true }
    if !u.hasPrefix("http") { return false }
    if u.range(of: "\\.torrent([?#]|$)", options: .regularExpression) != nil { return true }
    return u.contains("/download")
}

private func isVkUrl(_ url: String) -> Bool {
    url.range(of: "^https://(m\\.)?vk\\.(com|ru)/doc-?\\d+_\\d+", options: .regularExpression) != nil
}

private func volumeNumberOf(_ label: String?) -> Int? {
    guard let label else { return nil }
    guard let m = label.range(of: "^Tome\\s+(\\d+)$", options: [.regularExpression, .caseInsensitive]) else { return nil }
    return Int(label[m].replacingOccurrences(of: "^Tome\\s+", with: "", options: [.regularExpression, .caseInsensitive]))
}

func parseRss(_ o: JSONDict) -> (items: [NewsItem], errors: [String]) {
    let items = o.objects("entries").map { e -> NewsItem in
        let title = e.str("title") ?? "(sans titre)"
        let seriesId = e.int("series_id")
        let link = e.str("page_link") ?? e.str("link") ?? e.str("comments_link")
        let tracking = Tracking(seriesId: seriesId, sourceLink: e.str("link"))
        let urls = e.objects("download_links").compactMap { $0.str("url") }
        let vk = e.bool("vk") == true
        let files: [DownloadJob] = vk
            ? urls.first.map { [.vk(url: $0, name: e.str("filename") ?? title, tracking: tracking)] } ?? []
            : urls.filter(isTorrentUrl).map { .torrent(url: $0, name: title, tracking: tracking) } +
              urls.filter(isVkUrl).map { .vk(url: $0, name: e.str("filename") ?? title, tracking: tracking) }
        let owned = e.bool("already_owned") == true
        let size = e.long("size") ?? 0
        return NewsItem(
            type: .rss,
            title: title,
            subtitle: e.str("bedetheque_title") ?? e.str("series_title"),
            date: localDate(e.str("date")),
            source: e.str("feed_title") ?? e.str("feed_name"),
            sizeBytes: size > 0 ? size : nil,
            inLibrary: e.bool("already_in_library") == true,
            owned: owned,
            downloaded: e.bool("downloaded") == true,
            link: link,
            seriesId: seriesId,
            seriesTitle: e.str("series_title") ?? e.str("bedetheque_title") ?? e.str("parsed_title")
                ?? { let g = newsGuessSeriesTitle(title); return g.isBlank ? title : g }(),
            rawHint: title,
            bedethequeUrl: e.str("bedetheque_url"),
            files: files.map { NewsFile(job: $0, volumeLabel: nil, owned: owned) },
            prowlarrIndexerId: e.int("prowlarr_indexer_id"),
            raw: e,
        )
    }
    let errors = o.array("errors")?.strings().isEmpty == true ? [String]() : (o.array("errors")?.compactMap { el -> String? in
        if let e = el as? JSONDict {
            let line = [e.str("feed") ?? e.str("name"), e.str("error") ?? e.str("message")].compactMap { $0 }.joined(separator: " : ")
            return line.isBlank ? JSON.stringify(e) : line
        }
        if let s = el as? String { return s }
        return JSON.stringify(el)
    } ?? [])
    return (items, errors)
}

func parseTelegram(_ o: JSONDict) -> [NewsItem] {
    o.objects("files").map { f -> NewsItem in
        let filename = f.str("filename") ?? "(sans nom)"
        let channel: String? = f.str("channel")?.trimmingPrefix("@")
        let messageId = f.long("message_id")
        let seriesId = f.int("series_id")
        let post = (channel != nil && messageId != nil) ? "https://t.me/\(channel!)/\(messageId!)" : nil
        let tracking = Tracking(seriesId: seriesId, volumeNumber: f.int("volume"), sourceLink: post)
        let owned = f.bool("already_owned") == true
        let vol = f.str("parsed_volume")
        let subtitleParts = [f.str("bedetheque_title") ?? f.str("series_title") ?? f.str("parsed_title"), vol].compactMap { $0 }
        return NewsItem(
            type: .telegram,
            title: filename,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            date: f.str("message_date").map { String($0.prefix(16)) },
            source: f.str("channel_title") ?? f.str("channel"),
            sizeBytes: f.long("file_size"),
            inLibrary: f.bool("already_in_library") == true,
            owned: owned,
            downloaded: f.bool("downloaded") == true,
            link: post,
            seriesId: seriesId,
            seriesTitle: f.str("series_title") ?? f.str("bedetheque_title") ?? f.str("parsed_title")
                ?? { let g = newsGuessSeriesTitle(filename); return g.isBlank ? filename : g }(),
            rawHint: filename,
            bedethequeUrl: f.str("bedetheque_url"),
            files: (channel != nil && messageId != nil)
                ? [NewsFile(job: .telegram(channel: channel!, messageId: messageId!, channelTitle: f.str("channel_title"), name: filename, tracking: tracking), volumeLabel: vol, owned: owned)]
                : [],
            prowlarrIndexerId: nil,
            raw: f,
        )
    }
}

/**
 * Rattache une entrée de Nouveautés à une série (ou la change) avec les mêmes routes que le site :
 * RSS et Telegram par nom de fichier ou lien, EBDZ par identifiant de sujet.
 */
func setNewsSeries(_ api: BullarrApi, _ item: NewsItem, _ seriesId: Int) async throws {
    switch item.type {
    case .rss:
        try await api.postObject("api/ebdz/rss/match-override", [
            "link": item.raw.str("link") ?? "",
            "title": item.raw.str("title") ?? item.title,
            "series_id": seriesId,
        ])
    case .telegram:
        try await api.postObject("api/telegram-channels/match-override", [
            "filename": item.raw.str("filename") ?? item.title,
            "series_id": seriesId,
        ])
    case .ebdz:
        try await api.postObject("api/series/\(seriesId)/ebdz-match", ["thread_id": item.raw.str("thread_id") ?? ""])
    }
}

func parseEbdz(_ o: JSONDict) -> [NewsItem] {
    o.objects("sessions").flatMap { s -> [NewsItem] in
        let date = s.str("scraped_at").map { String($0.prefix(16)) }
        return s.objects("results").map { r -> NewsItem in
            let links = r.objects("links")
            let seriesId = r.int("matched_series_id")
            let files: [NewsFile] = links.compactMap { l -> NewsFile? in
                guard let ed2k = l.str("link") else { return nil }
                let vol = l.str("parsed_volume")
                let tracking = Tracking(seriesId: seriesId, volumeId: nil, volumeNumber: l.int("volume") ?? volumeNumberOf(vol), sourceLink: r.str("url"))
                return NewsFile(job: .ed2k(link: ed2k, name: decodeName(l.str("filename") ?? ed2k), tracking: tracking), volumeLabel: vol, owned: l.bool("already_owned") == true)
            }
            let vols = Array(Set(files.compactMap(\.volumeLabel)))
            var filesLine: String? = files.isEmpty ? nil : "\(files.count) fichier(s)"
            if let fl = filesLine, !vols.isEmpty { filesLine = fl + " : " + vols.prefix(4).joined(separator: ", ") }
            let title = r.str("title") ?? "(sans titre)"
            let head = [r.str("matched_series_title"), filesLine].compactMap { $0 }.joined(separator: " · ")
            return NewsItem(
                type: .ebdz,
                // Titre du fil en gras ; série rattachée et fichiers en dessous.
                title: head.isBlank ? "Nouveau fil EBDZ" : head,
                subtitle: title,
                date: date,
                source: r.str("category") ?? "EBDZ",
                sizeBytes: { let total = links.reduce(Int64(0)) { $0 + ($1.long("filesize") ?? 0) }; return total > 0 ? total : nil }(),
                inLibrary: r.bool("already_in_library") == true || r.bool("already_matched_thread") == true,
                owned: !files.isEmpty && files.allSatisfy(\.owned),
                downloaded: false,
                link: r.str("url"),
                seriesId: seriesId,
                seriesTitle: r.str("matched_series_title") ?? r.str("bedetheque_title")
                    ?? { let g = newsGuessSeriesTitle(title); return g.isBlank ? title : g }(),
                rawHint: files.first?.job.name ?? title,
                bedethequeUrl: r.str("matched_bedetheque_url") ?? r.str("bedetheque_url"),
                files: files,
                prowlarrIndexerId: nil,
                raw: r,
            )
        }
    }
}

extension String {
    func trimmingPrefix(_ p: String) -> String { hasPrefix(p) ? String(dropFirst(p.count)) : self }
}

// --- Noms de release (comme _nouveautesPrettyName du site) --------------------------------------

private let NEWS_EXT = try! NSRegularExpression(pattern: "^(.*?)\\.(cbz|cbr|cb7|cbt|pdf|epub|zip|rar|7z)$", options: [.caseInsensitive])
private let NEWS_RELEASE_TAG = try! NSRegularExpression(pattern: "\\s*[\\[(](cbz|cbr|cb7|pdf|epub)[\\])]\\s*(?:-\\s*[\\w.-]+)?\\s*$", options: [.caseInsensitive])
private let NEWS_TOME = try! NSRegularExpression(pattern: "^(.*?)(?:[\\s._\\-(\\[]|^)(?:T|Tome|Vol(?:ume)?\\.?)\\s*\\.?\\s*\\d{1,3}(?!\\d)", options: [.caseInsensitive])
private let NEWS_SPACES = try! NSRegularExpression(pattern: "\\s+")

/// Nom lisible d'une release : sans extension ni « [CBZ]-Groupe », points et _ en espaces.
func newsPrettyName(_ raw: String) -> String {
    var base = raw
    if let m = NEWS_EXT.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
        base = String(raw[Range(m.range(at: 1), in: raw)!])
    }
    if let m = NEWS_RELEASE_TAG.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
       let r = Range(m.range, in: base), r.lowerBound > base.startIndex {
        base = String(base[base.startIndex..<r.lowerBound])
    }
    let dots = base.filter { $0 == "." }.count
    let underscores = base.filter { $0 == "_" }.count
    if (dots > 0 || underscores > 0) && base.filter({ $0 == " " }).count < 3 {
        base = base.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "(?<!\\d)\\.|\\.(?!\\d)", with: " ", options: .regularExpression)
    }
    let collapsed = base.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    return collapsed.isBlank ? raw : collapsed
}

/// Série devinée d'une release sans série reconnue : ce qui précède « T05 », « Tome 5 », « Vol. 5 » ("" si rien).
func newsGuessSeriesTitle(_ raw: String?) -> String {
    guard let raw, !raw.trimmed.isBlank else { return "" }
    let s = newsPrettyName(raw)
    guard let m = NEWS_TOME.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return "" }
    let name = String(s[Range(m.range(at: 1), in: s)!])
        .replacingOccurrences(of: "[\\s._\\-(\\[]+$", with: "", options: .regularExpression)
        .trimmed
    return name.count >= 2 ? name : ""
}
