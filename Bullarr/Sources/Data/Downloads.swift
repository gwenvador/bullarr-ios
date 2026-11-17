import Foundation

/// Où rattacher un téléchargement dans Bullarr (série/tome), comme le font les pages web.
struct Tracking: Equatable {
    var seriesId: Int? = nil
    var volumeId: Int? = nil
    var volumeNumber: Int? = nil
    var sourceLink: String? = nil
}

/**
 * Un fichier à envoyer. Les corps reprennent ceux de search.js / ebdz-latest.js.
 * Clé qui identifie le fichier pour marquer « Envoyé » dans l'app : `key`.
 */
enum DownloadJob: Equatable {
    case torrent(url: String, name: String, tracking: Tracking)
    case ed2k(link: String, name: String, tracking: Tracking)
    case telegram(channel: String, messageId: Int64, channelTitle: String?, name: String, tracking: Tracking)
    case fourtoutici(fileId: String, name: String, tracking: Tracking)
    case vk(url: String, name: String, tracking: Tracking)

    var name: String {
        switch self {
        case .torrent(_, let name, _), .ed2k(_, let name, _), .telegram(_, _, _, let name, _),
             .fourtoutici(_, let name, _), .vk(_, let name, _): return name
        }
    }

    var tracking: Tracking {
        switch self {
        case .torrent(_, _, let t), .ed2k(_, _, let t), .telegram(_, _, _, _, let t),
             .fourtoutici(_, _, let t), .vk(_, _, let t): return t
        }
    }

    var key: String {
        switch self {
        case .torrent(let url, _, _), .vk(let url, _, _): return url
        case .ed2k(let link, _, _): return link
        case .telegram(let channel, let messageId, _, _, _): return "tg:\(channel)/\(messageId)"
        case .fourtoutici(let fileId, _, _): return "4t:\(fileId)"
        }
    }

    func withTracking(_ t: Tracking) -> DownloadJob {
        switch self {
        case .torrent(let url, let name, _): return .torrent(url: url, name: name, tracking: t)
        case .ed2k(let link, let name, _): return .ed2k(link: link, name: name, tracking: t)
        case .telegram(let channel, let messageId, let channelTitle, let name, _):
            return .telegram(channel: channel, messageId: messageId, channelTitle: channelTitle, name: name, tracking: t)
        case .fourtoutici(let fileId, let name, _): return .fourtoutici(fileId: fileId, name: name, tracking: t)
        case .vk(let url, let name, _): return .vk(url: url, name: name, tracking: t)
        }
    }
}

struct DownloadClient: Hashable { let key: String; let label: String }

let TORRENT_CLIENTS = [
    DownloadClient(key: "qbittorrent", label: "qBittorrent"),
    DownloadClient(key: "rtorrent", label: "rTorrent"),
    DownloadClient(key: "deluge", label: "Deluge"),
]

/// Client fixe pour les sources autres que torrent ; nil = choisir parmi les clients torrent activés.
func fixedClient(_ job: DownloadJob) -> DownloadClient? {
    switch job {
    case .torrent: return nil
    case .ed2k: return DownloadClient(key: "emule", label: "aMule")
    case .telegram: return DownloadClient(key: "telegram", label: "Telegram")
    case .fourtoutici: return DownloadClient(key: "fourtoutici", label: "Fourtoutici")
    case .vk: return DownloadClient(key: "vk", label: "VK")
    }
}

/// Réponse de POST /api/import/replacement-required : le tome a-t-il déjà un fichier, et lequel.
struct Replacement { let hasFile: Bool; let volumeId: Int? }

func replacementRequired(_ api: BullarrApi, _ job: DownloadJob) async -> Replacement? {
    let t = job.tracking
    guard let seriesId = t.seriesId else { return nil }
    let body: JSONDict = [
        "series_id": seriesId,
        "volume_id": t.volumeId ?? NSNull(),
        "volume_number": t.volumeNumber ?? NSNull(),
        "title": job.name,
    ]
    guard let o = try? await api.postObject("api/import/replacement-required", body) else { return nil }
    return Replacement(hasFile: (o.bool("existing") ?? false) && (o.bool("has_file") ?? false), volumeId: o.int("volume_id"))
}

func sendDownload(_ api: BullarrApi, _ job: DownloadJob, _ client: DownloadClient, _ forceReplace: Bool, _ qbCategory: String?) async throws {
    let t = job.tracking
    var body: JSONDict = [
        "series_id": t.seriesId ?? NSNull(),
        "volume_id": t.volumeId ?? NSNull(),
        "volume_number": t.volumeNumber ?? NSNull(),
        "force_replace": forceReplace,
    ]
    if let link = t.sourceLink { body["source_link"] = link }
    let path: String
    switch job {
    case .torrent(let url, let name, _):
        body["torrent_url"] = url
        body["title"] = name
        body["source"] = "prowlarr"
        if client.key == "qbittorrent", let cat = qbCategory { body["category"] = cat }
        path = "api/\(client.key)/add"
    case .ed2k(let link, let name, _):
        body["link"] = link
        body["title"] = name
        body["source"] = "ebdz"
        path = "api/emule/add"
    case .telegram(let channel, let messageId, let channelTitle, let name, _):
        body["channel"] = channel
        body["message_id"] = messageId
        body["channel_title"] = channelTitle ?? ""
        body["filename"] = name
        body["source"] = "telegram"
        path = "api/telegram-channels/download"
    case .fourtoutici(let fileId, let name, _):
        body["file_id"] = fileId
        body["filename"] = name
        body["source"] = "fourtoutici"
        path = "api/fourtoutici/download"
    case .vk(let url, let name, _):
        body["url"] = url
        body["filename"] = name
        path = "api/vk/download"
    }
    _ = try await api.postObject(path, body)
}
