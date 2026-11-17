import Foundation
import SwiftUI

/// Filtres de la bibliothèque : plusieurs valeurs d'un même groupe = « ou », groupes différents = « et ».
struct LibraryFilters: Equatable {
    var types: Set<String> = []
    var origins: Set<String> = []
    var decades: Set<Int> = []
    var updated: Set<String> = []
    var volumes: Set<String> = []
    var sizes: Set<String> = []
    var votes: Set<String> = []
    var genres: Set<String> = []
    /// Listes personnelles : clés de LIST_LABELS (« to-read », « favorite »).
    var lists: Set<String> = []
    var tags: Set<String> = []

    var activeCount: Int {
        types.count + origins.count + genres.count + decades.count + updated.count +
            volumes.count + sizes.count + votes.count + lists.count + tags.count
    }
    var isEmpty: Bool { activeCount == 0 }

    func matches(_ s: SeriesSummary, now: Date = Date()) -> Bool {
        (types.isEmpty || types.contains(typeOf(s))) &&
            (origins.isEmpty || origins.contains(s.origin ?? "Autre")) &&
            (decades.isEmpty || { if let y = s.yearInt { return decades.contains(y / 10 * 10) }; return false }()) &&
            (updated.isEmpty || updated.contains { updatedMatches($0, s, now) }) &&
            (genres.isEmpty || s.genres.contains { genres.contains($0) }) &&
            (lists.isEmpty || lists.contains { listMatches($0, s) }) &&
            (tags.isEmpty || s.tags.contains { tags.contains($0) }) &&
            (votes.isEmpty || votes.contains { voteBucket($0, s.votes) }) &&
            (volumes.isEmpty || volumes.contains { volumeBucket($0, s.volumeCount) }) &&
            (sizes.isEmpty || { if let b = s.sizeBytes { return sizes.contains { sizeBucket($0, b) } }; return false }())
    }
}

/** Nombre maximal de tags proposés dans la feuille de filtres. */
let TAG_LIMIT = 40

/// Origine Bédéthèque → type affiché.
let ORIGIN_NAMES = ["Europe": "BD", "USA": "Comics", "Asie": "Manga"]
let TYPE_LABELS: [(String, String)] = [("serie", "Série"), ("oneshot", "One-shot"), ("integrale", "Intégrale")]
let UPDATED_LABELS: [(String, String)] = [("7", "7 derniers jours"), ("30", "30 derniers jours"), ("old", "Plus ancien")]
let VOLUME_LABELS: [(String, String)] = [("0", "Aucun (masquées par défaut)"), ("1", "1"), ("2-5", "2 à 5"), ("6-10", "6 à 10"), ("11-20", "11 à 20"), ("21+", "21 et plus")]
let VOTE_LABELS: [(String, String)] = [("0", "Aucun vote"), ("1-10", "1 à 10"), ("11-50", "11 à 50"), ("51-100", "51 à 100"), ("100+", "Plus de 100")]
let SIZE_LABELS: [(String, String)] = [("<100", "< 100 Mo"), ("100-500", "100 à 500 Mo"), ("500-1000", "500 Mo à 1 Go"), ("1-5", "1 à 5 Go"), (">5", "> 5 Go")]
let LIST_LABELS: [(String, String)] = [("to-read", "À lire plus tard"), ("favorite", "Favoris")]

func listMatches(_ key: String, _ s: SeriesSummary) -> Bool {
    switch key {
    case "to-read": return s.toReadLater
    case "favorite": return s.isFavorite
    default: return false
    }
}

func typeOf(_ s: SeriesSummary) -> String {
    if s.isIntegral { return "integrale" }
    if s.isOneshot { return "oneshot" }
    return "serie"
}

private let scanFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.isLenient = true
    return f
}()

func updatedMatches(_ key: String, _ s: SeriesSummary, _ now: Date) -> Bool {
    guard let last = s.lastScanned, let at = scanFormatter.date(from: String(last.prefix(19))) else { return key == "old" }
    let days = now.timeIntervalSince(at) / 86400
    switch key {
    case "7": return days <= 7
    case "30": return days <= 30
    default: return days > 30
    }
}

func volumeBucket(_ key: String, _ n: Int) -> Bool {
    switch key {
    case "0": return n == 0
    case "1": return n == 1
    case "2-5": return n >= 2 && n <= 5
    case "6-10": return n >= 6 && n <= 10
    case "11-20": return n >= 11 && n <= 20
    default: return n >= 21
    }
}

func voteBucket(_ key: String, _ n: Int) -> Bool {
    switch key {
    case "0": return n == 0
    case "1-10": return n >= 1 && n <= 10
    case "11-50": return n >= 11 && n <= 50
    case "51-100": return n >= 51 && n <= 100
    default: return n > 100
    }
}

private let MO = 1_000_000

func sizeBucket(_ key: String, _ b: Int64) -> Bool {
    switch key {
    case "<100": return b < 100 * MO
    case "100-500": return b >= 100 * MO && b < 500 * MO
    case "500-1000": return b >= 500 * MO && b < 1000 * MO
    case "1-5": return b >= 1000 * MO && b < 5000 * MO
    default: return b >= 5000 * MO
    }
}

/// Tri de la bibliothèque ; l'ordre par défaut de chaque critère est le plus utile (populaire, récent, lourd d'abord).
enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title"
    case popularity = "Popularity"
    case date = "Date"
    case size = "Size"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Alphabétique"
        case .popularity: return "Popularité"
        case .date: return "Date"
        case .size: return "Taille"
        }
    }

    var defaultDesc: Bool { self != .title }

    func sorted(_ list: [SeriesSummary], desc: Bool) -> [SeriesSummary] {
        let cmp: (SeriesSummary, SeriesSummary) -> Bool = { a, b in
            switch self {
            case .title:
                return a.title.lowercased() < b.title.lowercased()
            case .popularity:
                if a.votes != b.votes { return a.votes < b.votes }
                return a.title.lowercased() < b.title.lowercased()
            case .date:
                let x = a.lastScanned ?? "", y = b.lastScanned ?? ""
                if x != y { return x < y }
                return a.title.lowercased() < b.title.lowercased()
            case .size:
                let x = a.sizeBytes ?? -1, y = b.sizeBytes ?? -1
                if x != y { return x < y }
                return a.title.lowercased() < b.title.lowercased()
            }
        }
        let out = list.sorted(by: cmp)
        return desc ? out.reversed() : out
    }
}
