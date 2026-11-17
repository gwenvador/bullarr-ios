import Foundation

/// Album en cours, pour « Continuer la lecture ». page : index 0-based.
struct RecentRead: Hashable {
    let volumeId: Int
    let seriesId: Int?
    let seriesTitle: String?
    let label: String?
    let title: String?
    let page: Int
    let total: Int
    let at: Date
    /// Couverture du tome (liste lue sur le serveur) ; sinon celle de la série.
    var coverPath: String? = nil
}

/// État de lecture d'un album, mémorisé sur l'appareil.
enum ReadStatus: Equatable {
    case unread
    /// page : index 0-based de la dernière page lue.
    case inProgress(page: Int)
    case read
}

/// État de lecture d'un album, mémorisé sur l'appareil (UserDefaults « reader »).
final class ReadingProgress {
    private let d = UserDefaults.standard

    /// Réglage global du lecteur : page à la largeur de l'écran.
    var fitWidth: Bool {
        get { d.bool(forKey: "fit_width") }
        set { d.set(newValue, forKey: "fit_width") }
    }

    /// Réglage global du lecteur : mode webtoon, les pages se suivent à la verticale et on lit en faisant défiler.
    var webtoon: Bool {
        get { d.bool(forKey: "webtoon") }
        set { d.set(newValue, forKey: "webtoon") }
    }

    /// Réglage global : deux pages côte à côte quand le téléphone est en paysage.
    var doublePage: Bool {
        get { d.object(forKey: "double_page") as? Bool ?? true }
        set { d.set(newValue, forKey: "double_page") }
    }

    /// Sens de lecture de droite à gauche (manga), mémorisé par série ; [default] tant que rien n'est choisi.
    func rtl(_ seriesId: Int?, _ default: Bool) -> Bool {
        if let id = seriesId, d.object(forKey: "rtl_\(id)") != nil { return d.bool(forKey: "rtl_\(id)") }
        return `default`
    }

    func setRtl(_ seriesId: Int?, _ value: Bool) {
        if let id = seriesId { d.set(value, forKey: "rtl_\(id)") }
    }

    /// Albums commencés et pas finis, du plus récent au plus ancien (liste de secours quand Komga n'est pas joignable).
    func recent() -> [RecentRead] {
        guard let data = d.string(forKey: "recent")?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return arr.compactMap { el -> RecentRead? in
            guard let o = el as? JSONDict, let v = o.int("v") else { return nil }
            return RecentRead(
                volumeId: v,
                seriesId: { let s = o.int("s") ?? 0; return s != 0 ? s : nil }(),
                seriesTitle: o.str("st"),
                label: o.str("l"),
                title: o.str("t"),
                page: o.int("p") ?? 0,
                total: o.int("n") ?? 0,
                at: Date(timeIntervalSince1970: o.double("at") ?? 0),
            )
        }.filter { get($0.volumeId) != nil }
    }

    private func writeRecent(_ list: [RecentRead]) {
        let arr: [[String: Any]] = list.prefix(20).map { r in
            [
                "v": r.volumeId,
                "s": r.seriesId ?? 0,
                "st": r.seriesTitle ?? "",
                "l": r.label ?? "",
                "t": r.title ?? "",
                "p": r.page,
                "n": r.total,
                "at": r.at.timeIntervalSince1970,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            d.set(String(data: data, encoding: .utf8) ?? "[]", forKey: "recent")
        }
    }

    private func dropRecent(_ volumeId: Int) {
        let list = recent()
        if list.contains(where: { $0.volumeId == volumeId }) { writeRecent(list.filter { $0.volumeId != volumeId }) }
    }

    /// Dernière page lue (0-based), ou nil : jamais lu, ou album fini (on repart du début).
    func get(_ volumeId: Int) -> Int? {
        let p = d.integer(forKey: "page_\(volumeId)")
        return p >= 0 ? p : nil
    }

    func save(_ volumeId: Int, _ page: Int, _ pageCount: Int, meta: ReaderMeta? = nil) {
        if page >= pageCount - 1 {
            d.removeObject(forKey: "page_\(volumeId)")
            d.set(true, forKey: "read_\(volumeId)")
        } else if page > 0 {
            d.set(page, forKey: "page_\(volumeId)")
        }
        if page >= pageCount - 1 { dropRecent(volumeId) }
        else if page > 0, let meta = meta {
            writeRecent([RecentRead(volumeId: volumeId, seriesId: meta.seriesId, seriesTitle: meta.seriesTitle, label: meta.label, title: meta.title, page: page, total: pageCount, at: Date())] +
                recent().filter { $0.volumeId != volumeId })
        }
    }

    func markRead(_ volumeId: Int) {
        d.removeObject(forKey: "page_\(volumeId)")
        d.set(true, forKey: "read_\(volumeId)")
        dropRecent(volumeId)
    }

    func markUnread(_ volumeId: Int) {
        d.removeObject(forKey: "page_\(volumeId)")
        d.removeObject(forKey: "read_\(volumeId)")
        dropRecent(volumeId)
    }

    func status(_ volumeId: Int) -> ReadStatus {
        if let p = get(volumeId) { return .inProgress(page: p) }
        if d.bool(forKey: "read_\(volumeId)") { return .read }
        return .unread
    }
}
