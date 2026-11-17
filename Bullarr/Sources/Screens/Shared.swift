import SwiftUI

// Composants partagés entre les écrans : logos, icônes d'état, puces, dialogues, toasts.

// Logos des sources et des clients (repris de static/img de Bullarr) et drapeaux d'origine.
let LOGO_KEYS: Set<String> = [
    "prowlarr", "ebdz", "telegram", "fourtoutici", "vk", "annas_archive", "rss",
    "qbittorrent", "amule", "emule", "rtorrent", "deluge", "shelfmark", "komga", "ntfy",
    "bedetheque", "fnac", "amazon", "bdfugue",
    // Genre / origine : même convention que la page web (BD = drapeau français).
    "bd", "europe", "comics", "usa", "manga", "asie",
]

/// Clé de logo pour un libellé quelconque (« qBittorrent », « aMule », « Prowlarr — C411 »…).
func logoKey(_ label: String?) -> String? {
    guard let l = label?.lowercased() else { return nil }
    if let exact = LOGO_KEYS.first(where: { l == $0 }) { return exact }
    if l.contains("prowlarr") { return "prowlarr" }
    if l.contains("qbittorrent") { return "qbittorrent" }
    if l.contains("amule") || l.contains("emule") { return "amule" }
    if l.contains("telegram") { return "telegram" }
    if l.contains("vk") { return "vk" }
    if l.contains("anna") { return "annas_archive" }
    if l.contains("fourtoutici") { return "fourtoutici" }
    if l.contains("rtorrent") { return "rtorrent" }
    if l.contains("deluge") { return "deluge" }
    if l.contains("ebdz") { return "ebdz" }
    if l.contains("rss") { return "rss" }
    return nil
}

func hasLogo(_ key: String?) -> Bool {
    guard let key else { return false }
    return LOGO_KEYS.contains(key) || logoKey(key) != nil
}

/// Nom de l'image dans l'asset catalog pour une clé (les clés amule/emule partagent le même visuel).
func logoAsset(_ key: String) -> String {
    switch key {
    case "amule", "emule": return "src_emule"
    case "bd", "europe": return "src_flag_france"
    case "comics", "usa": return "src_flag_us"
    case "manga", "asie": return "src_flag_japan"
    case "annas_archive": return "src_annas_archive"
    default: return "src_\(key)"
    }
}

/// Logo d'une source, d'un client ou d'une origine ; rien si la clé est inconnue.
/// (Sur iOS pas d'infobulle : le libellé reste à côté de l'icône dans l'appelant.)
struct Logo: View {
    let key: String?
    let label: String
    var size: CGFloat = 18
    var tip: Bool = true

    var body: some View {
        if let key, hasLogo(key) {
            Image(logoAsset(logoKey(key) ?? key))
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 5))
                .accessibilityLabel(label)
        }
    }
}

/// Icône d'état avec un court texte facultatif (nombre, page).
struct IconTag: View {
    let icon: String
    let label: String
    let tint: Color
    var text: String? = nil
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(tint)
                .accessibilityLabel(label)
            if let text {
                Text(text)
                    .font(.caption2)
                    .foregroundColor(tint)
            }
        }
    }
}

/// Icône d'état teintée, sans texte.
struct StatusIcon: View {
    let icon: String
    let label: String
    let tint: Color
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size))
            .foregroundColor(tint)
            .accessibilityLabel(label)
    }
}

/// Puce de filtre (style Material, portée sur BullColors).
struct FilterChip<Label: View>: View {
    @Environment(\.bullColors) private var cs
    let selected: Bool
    let onClick: () -> Void
    @ViewBuilder let label: () -> Label
    var enabled: Bool = true

    var body: some View {
        Button(action: onClick) {
            label()
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(selected ? cs.accent.opacity(0.16) : cs.surface)
                )
                .overlay(Capsule().strokeBorder(selected ? cs.accent : cs.outlineVariant, lineWidth: 1))
                .foregroundColor(selected ? cs.accent : cs.text)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Dialogue de confirmation (équivalent ConfirmDialog d'Android).
struct ConfirmDialog: View {
    @Environment(\.bullColors) private var cs
    let title: String
    let text: String
    let confirm: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    Text(text)
                }
            },
            buttons: {
                Button("Annuler", action: onDismiss)
                    .foregroundColor(cs.accent)
                Button(confirm) { onDismiss(); onConfirm() }
                    .foregroundColor(cs.error)
            }
        )
    }
}

/// Lance un bloc asynchrone avec un message de réussite ou l'erreur lisible en toast ;
/// `then` s'exécute dans les deux cas (rechargement des données). L'action est affichée
/// dans le bandeau « actions en cours » tant qu'elle tourne.
@MainActor
func launchAction(_ ok: String, then: (() -> Void)? = nil, running: String = "Action en cours", _ block: @escaping () async throws -> Void) {
    Task {
        let id = RunningActions.shared.start(running)
        do {
            try await block()
            ToastCenter.shared.show(ok)
        } catch {
            ToastCenter.shared.show(readable(error))
        }
        RunningActions.shared.end(id)
        then?()
    }
}
