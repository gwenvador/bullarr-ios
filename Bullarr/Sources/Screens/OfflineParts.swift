import SwiftUI

// Éléments hors ligne partagés : bouton et icône d'état d'un tome, icône d'en-tête d'une série.
// (Ports de OfflineScreen.kt, utilisés par la fiche série et le tome avant l'écran Hors ligne.)

/// Un tome possédé d'une série : identifiant, titre affiché, nombre de pages connu.
struct OfflineVolume: Identifiable {
    let id: Int
    let title: String
    let pages: Int?
}

/// Bouton d'état hors ligne d'un tome : télécharger, suivre (arrêter), supprimer la copie.
struct OfflineButton: View {
    @ObservedObject var offline: OfflineManager
    @Environment(\.bullColors) private var cs
    let volumeId: Int
    let title: String
    var iconOnly: Bool = false

    @State private var confirm = false

    var body: some View {
        let progress = offline.active[volumeId]
        let done = offline.isDownloaded(volumeId)
        Group {
            if let progress {
                if iconOnly {
                    Button {
                        if progress.error != nil { offline.start(volumeId, title) } else { offline.cancel(volumeId) }
                    } label: {
                        Image(systemName: progress.error != nil ? "arrow.clockwise" : "stop.circle")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(progress.error != nil ? "Réessayer le téléchargement" : "Arrêter le téléchargement")
                } else {
                    Button {
                        if progress.error != nil { offline.start(volumeId, title) } else { offline.cancel(volumeId) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: progress.error != nil ? "arrow.clockwise" : "stop.circle")
                            Text(progress.error != nil
                                 ? "Réessayer le téléchargement"
                                 : (progress.total > 0 ? "Téléchargement \(progress.done)/\(progress.total) · Arrêter" : "Préparation… · Arrêter"))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.bordered)
                    if let err = progress.error {
                        ErrorCard(message: err)
                    }
                }
            } else if iconOnly && done {
                Button { confirm = true } label: {
                    Image(systemName: "trash").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Supprimer la copie hors ligne")
            } else if iconOnly {
                Button { offline.start(volumeId, title) } label: {
                    Image(systemName: "arrow.down.circle").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Télécharger hors ligne")
            } else if done {
                Button { confirm = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Supprimer la copie hors ligne").lineLimit(1)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button { offline.start(volumeId, title) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text("Télécharger hors ligne").lineLimit(1)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .overlay {
            if confirm {
                ConfirmDialog(
                    title: "Supprimer la copie ?",
                    text: "\(title)\nL'album reste sur Bullarr ; seule la copie de l'appareil est supprimée.",
                    confirm: "Supprimer",
                    onConfirm: { offline.delete(volumeId); confirm = false },
                    onDismiss: { confirm = false }
                )
            }
        }
    }
}

/// Icône d'état hors ligne d'une ligne d'album : télécharger, progression (appui = arrêter),
/// copie présente (appui = supprimer), erreur (appui = détails).
struct OfflineIcon: View {
    @ObservedObject var offline: OfflineManager
    @Environment(\.bullColors) private var cs
    let volumeId: Int
    let title: String

    @State private var confirm = false
    @State private var showError = false

    var body: some View {
        let progress = offline.active[volumeId]
        let done = offline.isDownloaded(volumeId)
        Group {
            if let progress {
                if progress.paused {
                    Button { offline.resume(volumeId) } label: {
                        Image(systemName: "play.circle").foregroundColor(cs.accent).frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("En pause — reprendre")
                } else if progress.error == nil {
                    // Anneau de progression ; un appui arrête le téléchargement.
                    Button { offline.cancel(volumeId) } label: {
                        ZStack {
                            Circle().stroke(cs.outlineVariant, lineWidth: 2)
                            if progress.total > 0 {
                                Circle()
                                    .trim(from: 0, to: min(1, CGFloat(progress.done) / CGFloat(progress.total)))
                                    .stroke(cs.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Arrêter le téléchargement")
                } else {
                    Button { showError = true } label: {
                        Image(systemName: "exclamationmark.circle").foregroundColor(cs.error).frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Téléchargement en erreur — détails")
                }
            } else if done {
                Button { confirm = true } label: {
                    Image(systemName: "pin.circle.fill").foregroundColor(cs.accent).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Disponible hors ligne — supprimer la copie")
            } else {
                Button { offline.start(volumeId, title) } label: {
                    Image(systemName: "arrow.down.circle").frame(width: 32, height: 32)
                }
                .accessibilityLabel("Télécharger hors ligne")
            }
        }
        .overlay {
            if confirm {
                ConfirmDialog(
                    title: "Supprimer la copie ?",
                    text: "\(title)\nL'album reste sur Bullarr ; seule la copie de l'appareil est supprimée.",
                    confirm: "Supprimer",
                    onConfirm: { offline.delete(volumeId); confirm = false },
                    onDismiss: { confirm = false }
                )
            }
            if showError, let progress, let err = progress.error {
                OfflineErrorDialog(
                    errors: [(title, err)],
                    onRetry: { showError = false; offline.start(volumeId, title) },
                    onDismiss: { showError = false },
                    onGiveUp: { showError = false; offline.cancel(volumeId) }
                )
            }
        }
    }
}

/// Icône unique de l'en-tête d'une série : télécharger tous les albums, suivre l'avancement
/// (appui = tout arrêter) ou, une fois tout copié, supprimer les copies.
struct SeriesOfflineIcon: View {
    @ObservedObject var offline: OfflineManager
    @Environment(\.bullColors) private var cs
    let volumes: [OfflineVolume]

    @State private var confirm = false
    @State private var showError = false

    var body: some View {
        if volumes.isEmpty {
            EmptyView()
        } else {
            let downloaded = volumes.filter { offline.isDownloaded($0.id) }.count
            let running = volumes.filter { offline.active[$0.id] != nil && offline.active[$0.id]?.error == nil }
            let failed = volumes.filter { offline.active[$0.id]?.error != nil }
            let todo = volumes.filter { !offline.isDownloaded($0.id) && offline.active[$0.id] == nil }
            // Estimation : ~1 Mo par page quand le nombre de pages est connu, 40 pages sinon.
            let estimate = todo.reduce(0) { $0 + Int64($1.pages ?? 40) * 1_000_000 }
            HStack(spacing: 4) {
                Button {
                    if !running.isEmpty {
                        running.forEach { offline.cancel($0.id) }
                    } else if !failed.isEmpty {
                        showError = true
                    } else {
                        confirm = true
                    }
                } label: {
                    Group {
                        if !running.isEmpty {
                            ZStack {
                                Circle().stroke(cs.outlineVariant, lineWidth: 2)
                                let total = max(1, volumes.reduce(0) { $0 + (offline.active[$1.id]?.total ?? 0) })
                                let done = volumes.reduce(0) { $0 + (offline.active[$1.id]?.done ?? 0) }
                                Circle()
                                    .trim(from: 0, to: min(1, CGFloat(done) / CGFloat(total)))
                                    .stroke(cs.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .frame(width: 22, height: 22)
                        } else if !failed.isEmpty {
                            Image(systemName: "exclamationmark.circle").foregroundColor(cs.error)
                        } else if todo.isEmpty {
                            Image(systemName: "pin.circle.fill").foregroundColor(cs.accent)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .accessibilityLabel(running.isEmpty ? (failed.isEmpty ? (todo.isEmpty ? "Tous les albums sont hors ligne — supprimer les copies" : "Télécharger tous les albums hors ligne") : "Téléchargements en erreur — détails") : "Arrêter les téléchargements")
                // Compteur discret : « 3/12 » albums copiés.
                if downloaded > 0 || !running.isEmpty {
                    Text("\(downloaded)/\(volumes.count)").font(.caption2).foregroundColor(cs.muted)
                }
            }
            .overlay {
                if confirm && !todo.isEmpty {
                    ConfirmDialog(
                        title: "Tout télécharger hors ligne ?",
                        text: "\(todo.count) album(s), environ \(formatBytes(estimate) ?? "") (estimation). Les téléchargements continuent tant que l'app est ouverte.",
                        confirm: "Télécharger",
                        onConfirm: { todo.forEach { offline.start($0.id, $0.title) }; confirm = false },
                        onDismiss: { confirm = false }
                    )
                }
                if confirm && todo.isEmpty {
                    ConfirmDialog(
                        title: "Supprimer les copies ?",
                        text: "\(downloaded) album(s) seront supprimés de l'appareil. Ils restent sur Bullarr.",
                        confirm: "Supprimer",
                        onConfirm: { volumes.forEach { offline.delete($0.id) }; confirm = false },
                        onDismiss: { confirm = false }
                    )
                }
                if showError, !failed.isEmpty {
                    OfflineErrorDialog(
                        errors: failed.map { ($0.title, offline.active[$0.id]?.error ?? "") },
                        onRetry: { showError = false; failed.forEach { offline.start($0.id, $0.title) } },
                        onDismiss: { showError = false },
                        onGiveUp: { showError = false; failed.forEach { offline.cancel($0.id) } }
                    )
                }
            }
        }
    }
}

/// Détail des erreurs de téléchargement (le message du serveur ou du réseau), avec réessai.
struct OfflineErrorDialog: View {
    @Environment(\.bullColors) private var cs
    let errors: [(String, String)]
    let onRetry: () -> Void
    let onDismiss: () -> Void
    let onGiveUp: () -> Void

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(cs.error)
                    Text(errors.count > 1 ? "\(errors.count) téléchargements en erreur" : "Téléchargement en erreur").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        let distinct = dedup(errors.map { $0.1 }).prefix(4)
                        ForEach(Array(distinct.enumerated()), id: \.offset) { _, e in
                            Text(e).font(.subheadline)
                        }
                        if dedup(errors.map { $0.1 }).count > 4 {
                            Text("…").font(.subheadline)
                        }
                    }
                }
            },
            buttons: {
                Button {
                    onRetry()
                } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.clockwise"); Text("Réessayer") }
                }
                Button("Abandonner") { onGiveUp() }
                Button("Fermer", role: .cancel) { onDismiss() }
            }
        )
    }

    private func dedup(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
