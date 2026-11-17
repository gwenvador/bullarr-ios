import SwiftUI

/// Les 5 rubriques de la barre latérale de Bullarr (nav.js : Suivi et Actions sont des groupes).
enum Section: String, CaseIterable, Identifiable {
    // Pas d'onglets : « Hors ligne » s'ouvre par un bouton de la barre d'outils (subTab 1).
    case library = "Bibliothèque"
    case search = "Recherche"
    // Lecteurs seulement : leurs demandes de BD (les administrateurs les traitent dans Validation).
    case requests = "Demandes"
    case tracking = "Suivi"
    case actions = "Actions"
    case config = "Réglages"

    var id: String { rawValue }

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
        case .requests: return "tray.full"
        case .tracking: return "chart.xyaxis.line"
        case .actions: return "wrench.and.screwdriver"
        case .config: return "gearshape"
        }
    }

    var subs: [String] {
        switch self {
        case .library, .search, .requests: return []
        case .tracking: return ["Activité", "Nouveautés", "Validation", "Historique"]
        case .actions: return ["Enrichir", "Surveillance", "Vérification"]
        case .config: return ["Profil", "Indexeurs", "Clients", "Notifications", "Imports", "Recherche", "Surveillance", "Apparence", "Upscaling", "Accès", "Utilisateurs", "IA", "Web", "À propos"]
        }
    }
}
