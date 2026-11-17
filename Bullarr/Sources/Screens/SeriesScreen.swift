import SwiftUI
import UIKit

// Fiche d'une série : en-tête (couverture, auteurs, « Plus » avec surveillance, hors ligne, liens
// et tags), liste des albums groupés (tomes, épisodes, intégrales…), menus de la série et des tomes,
// fiches (tome, avis, à lire aussi, autres séries d'un auteur, historique) et visionneuse d'images.

func openInBrowser(_ url: String) {
    guard let u = URL(string: url) else { return }
    UIApplication.shared.open(u)
}

struct SeriesScreen: View {
    @EnvironmentObject private var state: AppState
    let series: SeriesSummary
    let onBack: () -> Void
    let onSearch: (SearchContext) -> Void

    var body: some View {
        // OfflineManager observé à part : l'état des téléchargements suit en direct.
        SeriesScreenInner(offline: state.offline, series: series, onBack: onBack, onSearch: onSearch)
    }
}

private struct SeriesScreenInner: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @ObservedObject var offline: OfflineManager
    let series: SeriesSummary
    let onBack: () -> Void
    let onSearch: (SearchContext) -> Void

    // Fiche déjà vue : affichée aussitôt depuis le cache mémoire, puis rafraîchie.
    @State private var detail: SeriesDetail? = nil
    @State private var error: String? = nil
    @State private var attempt = 0
    @State private var shown: VolumeRow? = nil
    @State private var sortKey = "Numéro"
    // Loupe des albums : filtre la liste par nom (libellé, titre, fichier).
    @State private var volFilterOpen = false
    @State private var volFilter = ""
    @State private var searchMenu = false
    @State private var sortDesc = false
    @State private var status = "Tous"
    @State private var format = "Tous"
    @State private var menu: VolumeRow? = nil
    @State private var editing: VolumeRow? = nil
    @State private var deleting: VolumeRow? = nil
    @State private var reviewsFor: VolumeRow? = nil
    @State private var readAlso = false
    @State private var showHistory = false
    @State private var authorSheet: AuthorRef? = nil
    @State private var seriesMenu = false
    @State private var editingSeries = false
    @State private var movingSeries = false
    @State private var confirmDeleteSeries = false
    @State private var editingTags = false
    @State private var aiTags = false
    // Avancement Komga de chaque tome (comme le site), relu à chaque rechargement et en sortant du lecteur.
    @State private var komga: [Int: KomgaVolumeProgress] = [:]
    // Sections repliées, mémorisées par type (comme le web) : valable pour toutes les séries.
    @State private var collapsed: Set<String> = []

    private struct AuthorRef: Identifiable {
        let name: String
        let link: String
        var id: String { link }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if detail == nil && error == nil {
                ProgressView().progressViewStyle(.linear)
            }
            listContent
        }
        .background(cs.bg)
        .task(id: "\(series.id)|\(attempt)") { await loadDetail() }
        .task(id: "\(series.id)|\(attempt)|\(state.progressVersion)") { await loadKomga() }
        .task(id: detail?.id) {
            // Les albums déjà copiés avant sont adoptés (pas de double téléchargement).
            if let d = detail {
                _ = offline.adopt(d.id, d.volumes.filter { $0.owned }.map { ($0.id, $0.label) })
            }
        }
        .onAppear {
            if detail == nil { detail = state.cachedSeriesDetail(series.id) }
            collapsed = Set(VOLUME_GROUP_KEYS.filter { UserDefaults.standard.bool(forKey: "volume_groups.\($0)") })
        }
        .sheet(item: $shown) { v in
            VolumeSheet(
                offline: offline, api: state.api, v: v,
                seriesTitle: detail?.title ?? series.title,
                summary: series,
                read: komga[v.id]?.completed == true,
                onToggleRead: { setVolumeRead(v, read: komga[v.id]?.completed != true) },
                onRead: {
                    shown = nil
                    presentAfterSheet { state.reading = ReaderTarget(volumeId: v.id, title: "\(detail?.title ?? series.title) · \(v.label)") }
                },
                onReviews: {
                    shown = nil
                    presentAfterSheet { reviewsFor = v }
                },
                onAuthor: { name in
                    shown = nil
                    presentAfterSheet {
                        if let link = detail?.authorLinks[name] {
                            authorSheet = AuthorRef(name: name, link: link)
                        } else {
                            // Pas de fiche auteur connue : recherche de son nom dans la bibliothèque.
                            state.query = name
                            state.openSeries = nil
                            state.section = .library
                        }
                    }
                },
                onSearch: {
                    shown = nil
                    if let d = detail {
                        onSearch(SearchContext(seriesId: d.id, seriesTitle: d.title, volumeId: v.id, volumeLabel: v.label, volumeNumber: v.number, isIntegral: v.isIntegral, isHs: v.isHs, isEpisode: v.isEpisode))
                    }
                },
                onRequest: state.isReader && !v.owned ? { shown = nil; requestVolume(v) } : nil
            )
        }
        .sheet(item: $menu) { v in
            VolumeActionsSheet(
                api: state.api, v: v,
                title: "\(detail?.title ?? series.title) · \(v.label)",
                read: komga[v.id]?.completed == true,
                onToggleRead: { setVolumeRead(v, read: komga[v.id]?.completed != true) },
                onEdit: { editing = v },
                onRefresh: { run("Fichier actualisé", running: "Actualisation du fichier") { try await ItemActions.refreshVolume(state.api!, v.id) } },
                onMeta: { run("Fiche Bédéthèque rechargée", running: "Rechargement de la fiche Bédéthèque") { try await ItemActions.updateVolumeMetadata(state.api!, v.id) } },
                onReviews: { presentAfterSheet { reviewsFor = v } },
                onHistory: { showHistory = true },
                onDelete: { deleting = v }
            )
        }
        .sheet(item: $reviewsFor) { v in
            ReviewsSheet(api: state.api, v: v, title: "\(detail?.title ?? series.title) · \(v.label)")
        }
        .sheet(isPresented: $readAlso) {
            ReadAlsoSheet(seriesId: series.id, seriesTitle: detail?.title ?? series.title, seriesLibraryId: detail?.libraryId)
        }
        .sheet(item: $authorSheet) { a in
            AuthorAlbumsSheet(name: a.name, link: a.link)
        }
        .sheet(isPresented: $showHistory) {
            if let api = state.api {
                SeriesHistorySheet(api: api, seriesId: series.id, title: detail?.title ?? series.title)
            }
        }
        .sheet(isPresented: $seriesMenu) {
            SeriesActionsSheet(
                title: detail?.title ?? series.title,
                onReadAlso: { readAlso = true },
                onHistory: { showHistory = true },
                onUpdate: { run("Mise à jour de la série lancée en arrière-plan", running: "Lancement de la mise à jour") { try await ItemActions.updateSeriesMetadata(state.api!, series.id) } },
                onScan: { run("Scan lancé", running: "Scan de la série") { try await ItemActions.scanSeries(state.api!, series.id) } },
                onEdit: { editingSeries = true },
                onMove: state.libraries.count < 2 ? nil : { movingSeries = true },
                onDelete: { confirmDeleteSeries = true },
                allRead: allRead,
                canMarkRead: canMarkRead,
                onToggleRead: { setSeriesRead(read: $0) }
            )
        }
        .overlay {
            if editingTags, let d = detail {
                SeriesTagsDialog(
                    initial: d.tags,
                    onDismiss: { editingTags = false; aiTags = false },
                    autoSuggest: aiTags,
                onSuggest: {
                    let raw = try? await state.api?.postObject("api/ai/series/\(d.id)/suggest", JSONDict())
                    return raw?.strings("tags") ?? []
                },
                    onAiSettings: {
                        state.openSeries = nil
                        state.section = .config
                        state.subTab[Section.config] = aiConfigTab
                    },
                    onSave: { saveTags($0) }
                )
            }
        }
        .sheet(item: $editing) { v in
            VolumeEditSheet(
                v: v, seriesId: series.id,
                seriesTitle: detail?.title ?? series.title,
                libraryId: detail?.libraryId,
                others: detail?.volumes ?? [],
                onChanged: { attempt += 1 }
            )
        }
        .sheet(isPresented: $movingSeries) {
            MoveSeriesSheet(
                currentLibraryId: detail?.libraryId,
                title: detail?.title ?? series.title,
                onMove: { moveSeries(to: $0) }
            )
        }
        .overlay {
            if let v = deleting {
                ConfirmDialog(
                    title: "Supprimer \(v.label) ?",
                    text: v.owned
                        ? "Le fichier du tome sera supprimé du disque ; la fiche reste en « manquant » pour pouvoir le retélécharger."
                        : "La fiche de ce tome manquant sera retirée de la série.",
                    confirm: "Supprimer",
                    onConfirm: { deleting = nil; run("Tome supprimé", running: "Suppression de \(v.label)") { try await ItemActions.deleteVolume(state.api!, v.id) } },
                    onDismiss: { deleting = nil }
                )
            }
        }
        .overlay {
            if confirmDeleteSeries {
                ConfirmDialog(
                    title: "Supprimer la série ?",
                    text: "Les fichiers de « \(detail?.title ?? series.title) » seront supprimés du disque. C'est irréversible.",
                    confirm: "Supprimer",
                    onConfirm: {
                        confirmDeleteSeries = false
                        // La suppression doit aller au bout même après la sortie de la fiche.
                        run("Série supprimée", then: { state.loadLibrary(force: true) }, running: "Suppression de « \(detail?.title ?? series.title) »") {
                            try await ItemActions.deleteSeries(state.api!, series.id)
                        }
                        onBack()
                    },
                    onDismiss: { confirmDeleteSeries = false }
                )
            }
        }
    }

    private var aiConfigTab: Int { Section.config.subs.firstIndex(of: "IA") ?? 0 }

    private var allRead: Bool {
        guard let vols = detail?.volumes.filter({ $0.owned }) else { return false }
        return !vols.isEmpty && vols.allSatisfy { komga[$0.id]?.completed == true }
    }

    private var canMarkRead: Bool { detail?.volumes.contains { $0.owned } == true }

    // --- Barre du haut -----------------------------------------------------------

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Retour")
            // Appui sur le nom : le menu de la série (mise à jour, scan, édition…).
            Button { seriesMenu = true } label: {
                Text(series.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // --- Contenu -----------------------------------------------------------------

    @ViewBuilder
    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error {
                    ErrorCard(message: error, onRetry: { attempt += 1 }).padding(16)
                }
                SeriesHeader(
                    offline: offline, s: series, d: detail,
                    onToggleMonitor: { setMonitored(on: $0) },
                    onAuthor: { name in
                        if let link = detail?.authorLinks[name] {
                            authorSheet = AuthorRef(name: name, link: link)
                        }
                    },
                    onFavorite: { setList(isFavorite: $0) },
                    onToRead: { setList(toReadLater: $0) },
                    onEditTags: { editingTags = true; aiTags = false },
                    onAiTags: { editingTags = true; aiTags = true },
                    onTag: { tag in
                        // Tag cliqué : la bibliothèque s'ouvre filtrée sur ce tag.
                        state.filters.tags = [tag]
                        state.openSeries = nil
                        state.section = .library
                    },
                    onTitleClick: { seriesMenu = true }
                )
                if let d = detail {
                    albumsSection(d)
                }
            }
            .padding(.bottom, 16)
        }
        // Tirer la liste vers le bas recharge la fiche.
        .refreshable {
            attempt += 1
            await loadDetail()
            await loadKomga()
        }
    }

    @ViewBuilder
    private func albumsSection(_ d: SeriesDetail) -> some View {
        let owned = d.volumes.filter { $0.owned }.count
        HStack(spacing: 0) {
            // « Albums » : tomes, intégrales, hors-séries, épisodes… réunis.
            Text("Albums · \(owned)/\(d.volumes.count)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                volFilterOpen.toggle()
                if !volFilterOpen { volFilter = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(volFilterOpen ? cs.accent : cs.muted)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Filtrer les albums par nom")
            Menu {
                Button {
                    onSearch(SearchContext(seriesId: d.id, seriesTitle: d.title, volumeId: nil, volumeLabel: nil, volumeNumber: nil))
                } label: {
                    Label("Chercher", systemImage: "globe")
                }
                Button {
                    // Même route que le site : POST /api/bedetheque/auto-acquire/run.
                    run("Recherche automatique lancée") {
                        let res = try await state.api!.postObject("api/bedetheque/auto-acquire/run", ["series_id": d.id])
                        if res.bool("success") == false {
                            throw ApiException(res.str("error") ?? "Recherche automatique impossible")
                        }
                    }
                } label: {
                    Label("Recherche automatique", systemImage: "dot.radiowaves.left.and.right")
                }
            } label: {
                Image(systemName: "globe").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Chercher la série")
            VolumeOrdering(
                volumes: d.volumes, sortKey: sortKey, desc: sortDesc, status: status, format: format,
                onSort: { k in
                    if sortKey == k { sortDesc.toggle() } else { sortKey = k; sortDesc = (k == "Taille") }
                },
                onStatus: { status = $0 },
                onFormat: { format = $0 }
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.top, 12)

        if volFilterOpen {
            CompactSearchField(value: $volFilter, placeholder: "Nom de l'album…")
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
        if d.volumes.isEmpty {
            EmptyStateView(title: "Aucun album connu pour cette série")
                .padding(.top, 8)
        }
        let terms = normalize(volFilter).split(separator: " ").map(String.init).filter { !$0.isBlank }
        let shownVolumes = ordered(d.volumes, sortKey: sortKey, desc: sortDesc, status: status, format: format, offline: offline).filter { v in
            terms.isEmpty || terms.allSatisfy { key in
                normalize([v.label, v.title, v.filename].compactMap { $0 }.joined(separator: " ")).contains(key)
            }
        }
        if !terms.isEmpty && shownVolumes.isEmpty {
            EmptyStateView(title: "Aucun album ne correspond")
                .padding(.top, 8)
        }
        let grouped = volumeGroups(shownVolumes, d.isOneshot)
        ForEach(grouped, id: \.0) { key, list in
            if grouped.count > 1 {
                VolumeGroupHeader(
                    label: VOLUME_GROUP_LABELS[key] ?? key,
                    owned: list.filter { $0.owned }.count, total: list.count,
                    collapsed: collapsed.contains(key),
                    onToggle: { toggleGroup(key) }
                )
            }
            if grouped.count == 1 || !collapsed.contains(key) {
                ForEach(list) { v in
                    VolumeItem(
                        offline: offline, v: v, cover: state.coverUrl(v.coverPath),
                        reading: komga[v.id],
                        seriesTitle: "\(d.title) · \(v.label)",
                        onOpen: { shown = v },
                        onLongClick: { menu = v },
                        canRead: v.owned,
                        onRead: { state.reading = ReaderTarget(volumeId: v.id, title: "\(d.title) · \(v.label)") },
                        onSearch: {
                            onSearch(SearchContext(seriesId: d.id, seriesTitle: d.title, volumeId: v.id, volumeLabel: v.label, volumeNumber: v.number, isIntegral: v.isIntegral, isHs: v.isHs, isEpisode: v.isEpisode))
                        },
                        onRequest: state.isReader && !v.owned ? { requestVolume(v) } : nil
                    )
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    private func toggleGroup(_ key: String) {
        let folded = !collapsed.contains(key)
        collapsed = folded ? collapsed.union([key]) : collapsed.subtracting([key])
        UserDefaults.standard.set(folded, forKey: "volume_groups.\(key)")
    }

    // --- Actions -----------------------------------------------------------------

    private func run(_ ok: String, then: (() -> Void)? = nil, running: String = "Action en cours", _ block: @escaping () async throws -> Void) {
        guard state.api != nil else { return }
        launchAction(ok, then: { attempt += 1; then?() }, running: running) {
            try await block()
        }
    }

    /// Demande d'un tome manquant (comptes lecteurs) : POST /api/requests, validée par un administrateur.
    private func requestVolume(_ v: VolumeRow) {
        guard let api = state.api else { return }
        Task { @MainActor in
            do {
                let r = try await api.postObject("api/requests", ["series_id": series.id, "volume_id": v.id])
                if (r.bool("success") ?? true) == false { throw ApiException(r.str("error") ?? "Demande impossible") }
                let label = r.str("volume_label") ?? v.label
                let msg: String
                if r.bool("duplicate") == true { msg = "\(label) : déjà demandé" }
                else if r.str("status") == "searching" { msg = "\(label) : recherche lancée" }
                else if r.str("status") == "already" { msg = "\(label) est déjà dans la bibliothèque" }
                else { msg = "\(label) demandé : en attente de validation" }
                ToastCenter.shared.show(msg)
                attempt += 1
            } catch {
                ToastCenter.shared.show(readable(error))
            }
        }
    }

    /// Déplacement de la série vers une autre bibliothèque : annoncé aussitôt (le dossier est
    /// copié sur le disque, ça peut durer), suivi dans le bandeau, puis rechargement complet.
    private func moveSeries(to target: Library) {
        guard let api = state.api else { return }
        let name = detail?.title ?? series.title
        ToastCenter.shared.show("Déplacement de « \(name) » vers \(target.name)…")
        Task { @MainActor in
            let msg: String
            do {
                msg = try await RunningActions.shared.track("Déplacement de « \(name) » vers \(target.name)") {
                    try await ItemActions.moveSeries(api, series.id, target)
                }
            } catch {
                msg = readable(error)
            }
            ToastCenter.shared.show(msg)
            attempt += 1
            state.loadLibrary(force: true)
        }
    }

    private func setMonitored(on: Bool) {
        run(on ? "Série surveillée" : "Surveillance arrêtée", running: "Mise à jour de la surveillance") {
            _ = try await state.api!.postObject("api/missing-monitor/series/\(series.id)/monitor", ["enabled": on])
        }
    }

    /// Liste perso (favori ou à lire) : la fiche et la ligne de la bibliothèque suivent sans rechargement complet.
    private func setList(toReadLater: Bool? = nil, isFavorite: Bool? = nil) {
        run("Liste mise à jour", running: "Mise à jour de la liste") {
            try await ItemActions.setSeriesReadingLists(state.api!, series.id, toReadLater: toReadLater, isFavorite: isFavorite)
            state.updateSeriesRow(series.id) { row in
                row.with(toReadLater: toReadLater ?? row.toReadLater, isFavorite: isFavorite ?? row.isFavorite)
            }
        }
    }

    /// Lu / non lu : même logique que le lecteur (avancement local, compte Komga relié ou Komga du serveur).
    private func setVolumeRead(_ v: VolumeRow, read: Bool) {
        run(read ? "\(v.label) marqué comme lu" : "\(v.label) marqué comme non lu", then: { state.progressVersion += 1 }, running: "Mise à jour de la lecture") {
            let res = try await state.api!.postObject("api/volumes/\(v.id)/read-status", ["read": read])
            if res.bool("success") == false {
                throw ApiException(res.str("error") ?? "Impossible de changer l'état de lecture")
            }
        }
    }

    private func setSeriesRead(read: Bool) {
        run(read ? "Série marquée comme lue" : "Série marquée comme non lue", then: { state.progressVersion += 1 }, running: "Mise à jour de la lecture de la série") {
            let res = try await state.api!.postObject("api/series/\(series.id)/read-status", ["read": read])
            if res.bool("success") == false {
                throw ApiException(res.str("error") ?? "Impossible de changer l'état de lecture")
            }
        }
    }

    private func saveTags(_ tags: [String]) {
        editingTags = false
        aiTags = false
        run("Tags enregistrés", running: "Enregistrement des tags") {
            try await ItemActions.setSeriesTags(state.api!, series.id, tags)
            state.updateSeriesRow(series.id) { row in
                var copy = row
                copy.tags = tags
                return copy
            }
        }
    }

    private func loadDetail() async {
        guard let api = state.api else {
            error = "Non connecté."
            return
        }
        error = nil
        do {
            let d = parseSeriesDetail(try await api.getObject("api/series/\(series.id)"))
            detail = d
            state.rememberSeriesDetail(d)
        } catch {
            self.error = readable(error)
        }
    }

    private func loadKomga() async {
        guard let api = state.api else { return }
        if let map = try? await loadSeriesKomgaProgress(api, series.id) {
            komga = map
        }
    }

    /// Présenter autre chose qu'une feuille (lecteur, autre feuille) une fois la fermeture finie.
    private func presentAfterSheet(_ set: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: set)
    }
}

// MARK: - En-tête

private struct SeriesHeader: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @ObservedObject var offline: OfflineManager
    let s: SeriesSummary
    let d: SeriesDetail?
    let onToggleMonitor: (Bool) -> Void
    let onAuthor: (String) -> Void
    let onFavorite: (Bool) -> Void
    let onToRead: (Bool) -> Void
    let onEditTags: () -> Void
    let onAiTags: () -> Void
    let onTag: (String) -> Void
    let onTitleClick: () -> Void

    @State private var expanded = false
    @State private var actionsOpen = false
    @State private var big = false
    @State private var previewPages: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                let coverUrl = state.coverUrl(d?.coverPath ?? s.coverPath)
                Button { big = true } label: {
                    Cover(url: coverUrl, width: 104)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agrandir la couverture")
                Spacer().frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Button(action: onTitleClick) {
                            Text(d?.title ?? s.title)
                                .font(.title3.weight(.semibold))
                                .underline()
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        // Listes personnelles, à côté du titre : toucher pour ajouter ou retirer.
                        if let d {
                            Button { onFavorite(!d.isFavorite) } label: {
                                Image(systemName: d.isFavorite ? "star.fill" : "star")
                                    .foregroundColor(d.isFavorite ? cs.tertiary : cs.muted)
                            }
                            .accessibilityLabel(d.isFavorite ? "Favori : toucher pour retirer" : "Pas en favori : toucher pour ajouter")
                            Button { onToRead(!d.toReadLater) } label: {
                                Image(systemName: d.toReadLater ? "bookmark.fill" : "bookmark")
                                    .foregroundColor(d.toReadLater ? cs.accent : cs.muted)
                            }
                            .accessibilityLabel(d.toReadLater ? "À lire plus tard : toucher pour retirer" : "Pas à lire plus tard : toucher pour ajouter")
                        }
                    }
                    // Chaque auteur qui a une fiche Bédéthèque est cliquable : ouvre ses autres séries.
                    if let names = d?.authors ?? s.author {
                        FlowRow(spacing: 8) {
                            ForEach(authorNames(names), id: \.self) { name in
                                let linked = d?.authorLinks[name] != nil
                                Button {
                                    if linked { onAuthor(name) }
                                } label: {
                                    Text(name)
                                        .font(.subheadline)
                                        .foregroundColor(linked ? cs.accent : cs.text)
                                        .underline(linked)
                                }
                                .buttonStyle(.plain)
                                .disabled(!linked)
                            }
                        }
                    }
                    let meta = [d?.years ?? s.year, d?.genre, d?.publishers].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.caption).foregroundColor(cs.muted)
                    }
                    // Surveillance, téléchargements et liens : repliés par défaut pour laisser la place à la fiche.
                    if d != nil {
                        Button {
                            withAnimation { actionsOpen.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: actionsOpen ? "chevron.up" : "chevron.down")
                                Text("Plus").font(.footnote.weight(.medium))
                            }
                            .foregroundColor(cs.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(actionsOpen ? "Replier" : "Déplier")
                    }
                }
                .padding(.leading, 16)
            }
            // Panneau « Plus » en pleine largeur sous l'en-tête : une ligne par sujet.
            if actionsOpen {
                plusPanel
            }
            if let d {
                let missing = d.volumes
                    .filter { !$0.owned && $0.label != "Tome" && volumeGroup($0, d.isOneshot) == "volume" }
                    .map { $0.label.replacingOccurrences(of: "Tome ", with: "") }
                if !missing.isEmpty {
                    Text("Tome \(missing.joined(separator: ", ")) manquant")
                        .font(.caption)
                        .foregroundColor(cs.tertiary)
                }
            }
            if let summary = d?.summary {
                Text(summary)
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 4)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }
        }
        .padding(16)
        .fullScreenCover(isPresented: $big) {
            galleryView
        }
        .task(id: s.id) {
            guard let api = state.api else { return }
            // Pages d'aperçu du premier tome possédé (GET /api/series/<id>/preview-pages), comme le site.
            if let raw = try? await api.getObject("api/series/\(s.id)/preview-pages") {
                previewPages = raw.strings("pages").filter { !$0.isEmpty }
            }
        }
    }

    private func authorNames(_ names: String) -> [String] {
        names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Couverture en grand puis pages d'aperçu.
    private var galleryView: some View {
        let coverUrl = state.coverUrl(d?.coverPath ?? s.coverPath)
        var images: [GalleryImage] = []
        if let coverUrl {
            images.append(GalleryImage(key: coverUrl) { await CoverLoader.shared.load(coverUrl, targetWidthPx: 1600) })
        } else {
            images.append(GalleryImage(key: "cover") { nil })
        }
        for p in previewPages {
            if let u = state.coverUrl(p) {
                images.append(GalleryImage(key: u) { await CoverLoader.shared.load(u, targetWidthPx: 1600) })
            }
        }
        return ImageGalleryView(images: images)
    }

    @ViewBuilder
    /// Icône et couleur du statut d'une série (en cours, terminée, arrêtée).
    private func statusInfo(_ st: String) -> (icon: String, tint: Color) {
        let l = st.lowercased()
        if l.contains("cours") { return ("hourglass", cs.tertiary) }
        if l.contains("termin") || l.contains("fini") { return ("checkmark.circle", cs.accentHover) }
        if l.contains("arrêt") || l.contains("stopp") || l.contains("abandon") { return ("slash.circle", cs.error) }
        return ("info.circle", cs.muted)
    }

    private var plusPanel: some View {        VStack(alignment: .leading, spacing: 2) {
            if let d {
                if let st = d.status {
                    let info = statusInfo(st)
                    PlusRow(icon: info.icon, label: "Statut") {
                        Text(st).font(.footnote.weight(.medium)).foregroundColor(info.tint)
                    }
                }
                PlusRow(icon: d.monitored ? "eye" : "eye.slash", label: "Surveillance") {
                    Toggle("", isOn: Binding(get: { d.monitored }, set: { onToggleMonitor($0) }))
                        .labelsHidden()
                        .scaleEffect(0.8)
                }
                let owned = d.volumes.filter { $0.owned }
                if !owned.isEmpty {
                    let got = owned.filter { offline.isDownloaded($0.id) }.count
                    PlusRow(icon: "pin", label: "Hors ligne") {
                        HStack(spacing: 4) {
                            Text("\(got)/\(owned.count)")
                                .font(.footnote.weight(.medium))
                                .foregroundColor(got > 0 ? cs.accent : cs.muted)
                            SeriesOfflineIcon(offline: offline, volumes: owned.map {
                                OfflineVolume(id: $0.id, title: "\(d.title) · \($0.label)", pages: $0.pageCount)
                            })
                        }
                    }
                }
                if !links.isEmpty {
                    PlusRow(icon: "link", label: "Liens") {
                        HStack(spacing: 16) {
                            ForEach(links, id: \.0) { key, name, url in
                                Button { openInBrowser(url) } label: {
                                    Logo(key: key, label: name, size: 24, tip: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                PlusRow(icon: "tag", label: "Tags") {
                    HStack(spacing: 4) {
                        Button(action: onAiTags) {
                            Image(systemName: "sparkles").foregroundColor(cs.accent)
                        }
                        .accessibilityLabel("Proposer des tags avec l'IA")
                        Button(action: onEditTags) {
                            Image(systemName: "pencil").foregroundColor(cs.accent)
                        }
                        .accessibilityLabel("Modifier les tags")
                    }
                }
                if d.tags.isEmpty {
                    Text("Aucun tag").font(.caption).foregroundColor(cs.muted).padding(.leading, 32)
                } else {
                    FlowRow(spacing: 6) {
                        ForEach(d.tags, id: \.self) { tag in
                            Button { onTag(tag) } label: {
                                TopicTag(text: tag)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 32)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    private var links: [(String, String, String)] {
        var out: [(String, String, String)] = []
        if let u = d?.komgaUrl { out.append(("komga", "Komga", u)) }
        if let u = d?.bedethequeUrl { out.append(("bedetheque", "Bédéthèque", u)) }
        if let u = d?.ebdzUrl { out.append(("ebdz", "EBDZ", u)) }
        return out
    }
}

/// Une ligne du panneau « Plus » : libellé à gauche, contrôle à droite.
private struct PlusRow<Content: View>: View {
    @Environment(\.bullColors) private var cs
    let icon: String
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(cs.muted)
                .frame(width: 20)
            Text(label).font(.subheadline)
            Spacer()
            content()
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Ligne d'album

/// Étiquette d'upscaling d'un tome, comme l'étiquette « Upscalé » du site : affichage seul, le
/// traitement est fait par le serveur (portage de UpscaleStateTag, Android 1.10).
private struct UpscaleTag: View {
    @Environment(\.bullColors) private var cs
    let v: VolumeRow

    private var tip: String {
        var t = "Upscalé"
        if let m = v.upscaledModel, !m.isBlank { t += " avec \(m)" }
        if let at = v.upscaledAt, at.count >= 10 {
            let p = at.prefix(10).split(separator: "-")
            if p.count == 3 { t += " le \(p[2])/\(p[1])/\(p[0])" }
        }
        return t
    }

    var body: some View {
        if v.upscaleBusy {
            IconTag(icon: "wand.and.stars", label: "Upscaling en cours", tint: cs.muted, text: "En cours")
        } else if v.upscaled {
            IconTag(icon: "sparkles", label: tip, tint: cs.tertiary, text: "Upscalé")
        } else if v.reducedBackup {
            IconTag(icon: "arrow.down.right.and.arrow.up.left", label: "Réduit (original gardé)", tint: cs.muted, text: "Réduit")
        }
    }
}

private struct VolumeItem: View {
    @Environment(\.bullColors) private var cs
    @ObservedObject var offline: OfflineManager
    let v: VolumeRow
    let cover: String?
    let reading: KomgaVolumeProgress?
    let seriesTitle: String
    let onOpen: () -> Void
    let onLongClick: () -> Void
    let canRead: Bool
    let onRead: () -> Void
    let onSearch: () -> Void
    /// Lecteur + tome manquant : demander ce tome (ou état de sa demande).
    let onRequest: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Cover(url: cover, width: 44)
            Spacer().frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(v.label).font(.footnote.weight(.semibold)).foregroundColor(cs.accent)
                    UpscaleTag(v: v)
                }
                if let title = v.title {
                    Text(title).font(.subheadline).lineLimit(2)
                }
                let meta = v.owned
                    ? [v.format?.uppercased(), formatBytes(v.fileSize), v.pageCount.map { "\($0) p." }, v.year].compactMap { $0 }
                    : [v.year].compactMap { $0 }
                // Une seule ligne : format, taille, pages, année tiennent à côté des boutons sans passer à la ligne.
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(cs.muted)
                        .lineLimit(1)
                }
                if offline.isDownloaded(v.id) {
                    IconTag(icon: "pin", label: "Disponible hors ligne", tint: cs.accent, text: "Téléchargé sur le téléphone")
                }
                // État de lecture Komga : « Lu » ou la page atteinte, avec une barre d'avancement.
                if let r = reading {
                    if r.completed {
                        IconTag(icon: "checkmark.seal", label: "Lu (Komga)", tint: cs.muted, text: "Lu")
                    } else {
                        let pages = r.pages ?? v.pageCount
                        IconTag(icon: "book", label: "En cours de lecture (Komga)", tint: cs.tertiary, text: "p. \(r.page)" + (pages.map { "/\($0)" } ?? ""))
                        if let pages, pages > 0 {
                            ProgressView(value: Double(r.page), total: Double(pages))
                                .tint(cs.tertiary)
                                .frame(width: 120, height: 3)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 4)
            if !v.owned {
                IconTag(icon: "exclamationmark.triangle", label: "Manquant", tint: cs.tertiary)
            }
            if let onRequest {
                // Lecteur, tome manquant : « Demander ce tome », ou l'état de sa demande.
                switch v.requested {
                case "pending":
                    IconTag(icon: "hourglass", label: "Demandé : en attente de validation", tint: cs.tertiary, text: "Demandé")
                case "searching":
                    IconTag(icon: "magnifyingglass", label: "Recherche du tome lancée", tint: cs.accent, text: "Recherche lancée")
                default:
                    Button(action: onRequest) {
                        Image(systemName: "tray.full")
                            .foregroundColor(v.requested == "rejected" ? cs.error : cs.accent)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(v.requested == "rejected" ? "Demande refusée : redemander ce tome" : "Demander ce tome")
                }
            }
            if v.owned {
                OfflineIcon(offline: offline, volumeId: v.id, title: seriesTitle)
            }
            if canRead {
                Button(action: onRead) {
                    Image(systemName: "play").foregroundColor(cs.accent).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Lire ce tome")
            }
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Chercher ce tome")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onLongPressGesture(minimumDuration: 0.45) { onLongClick() }
    }
}

// MARK: - Sections d'albums

/// Sections des tomes, dans l'ordre du web : tomes d'abord, les à-côtés ensuite.
private let VOLUME_GROUP_KEYS = ["volume", "episode", "integral", "hs", "special"]
private let VOLUME_GROUP_LABELS = [
    "volume": "Tomes", "episode": "Épisodes", "integral": "Intégrales", "hs": "Hors-série", "special": "Spéciaux",
]

/// Un one-shot reste un tome, même si une vieille ligne porte encore la marque « spécial ».
private func volumeGroup(_ v: VolumeRow, _ oneshot: Bool) -> String {
    if oneshot && !v.isIntegral && !v.isHs && !v.isEpisode { return "volume" }
    if v.isIntegral { return "integral" }
    if v.isHs { return "hs" }
    if v.isEpisode { return "episode" }
    if v.isSpecial { return "special" }
    return "volume"
}

private func volumeGroups(_ list: [VolumeRow], _ oneshot: Bool) -> [(String, [VolumeRow])] {
    var byKey: [String: [VolumeRow]] = [:]
    for v in list { byKey[volumeGroup(v, oneshot), default: []].append(v) }
    return VOLUME_GROUP_KEYS.filter { byKey[$0] != nil }.map { ($0, byKey[$0]!) }
}

/// En-tête d'une section de tomes : appui pour replier, compte possédés / total.
private struct VolumeGroupHeader: View {
    @Environment(\.bullColors) private var cs
    let label: String
    let owned: Int
    let total: Int
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .foregroundColor(cs.muted)
                Text(label).font(.subheadline.weight(.semibold))
                Spacer().frame(width: 8)
                Text("\(owned)/\(total)").font(.subheadline).foregroundColor(cs.accent)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

private let SORT_KEYS = ["Numéro", "Titre", "Taille", "Année"]
private let STATUS_KEYS = ["Tous", "Possédés", "Manquants", "Hors ligne", "Non téléchargés"]

@MainActor
private func ordered(_ all: [VolumeRow], sortKey: String, desc: Bool, status: String, format: String, offline: OfflineManager) -> [VolumeRow] {
    let filtered = all.filter { v in
        let statusOk: Bool
        switch status {
        case "Possédés": statusOk = v.owned
        case "Manquants": statusOk = !v.owned
        case "Hors ligne": statusOk = offline.isDownloaded(v.id)
        case "Non téléchargés": statusOk = v.owned && !offline.isDownloaded(v.id)
        default: statusOk = true
        }
        return statusOk && (format == "Tous" || v.format?.uppercased() == format)
    }
    let sorted: [VolumeRow]
    switch sortKey {
    case "Titre": sorted = filtered.sorted { ($0.title ?? $0.label).lowercased() < ($1.title ?? $1.label).lowercased() }
    case "Taille": sorted = filtered.sorted { ($0.fileSize ?? -1) < ($1.fileSize ?? -1) }
    case "Année": sorted = filtered.sorted { ($0.year ?? "") < ($1.year ?? "") }
    default: sorted = filtered
    }
    return desc ? sorted.reversed() : sorted
}

/// Tri et filtre des tomes d'une série, comme dans la bibliothèque : deux icônes, un menu chacune.
private struct VolumeOrdering: View {
    @Environment(\.bullColors) private var cs
    let volumes: [VolumeRow]
    let sortKey: String
    let desc: Bool
    let status: String
    let format: String
    let onSort: (String) -> Void
    let onStatus: (String) -> Void
    let onFormat: (String) -> Void

    var body: some View {
        let formats = ["Tous"] + Array(Set(volumes.compactMap { $0.format?.uppercased() })).sorted()
        let active = (status != "Tous" ? 1 : 0) + (format != "Tous" ? 1 : 0)
        HStack(spacing: 0) {
            Menu {
                ForEach(SORT_KEYS, id: \.self) { k in
                    Button {
                        onSort(k)
                    } label: {
                        if sortKey == k {
                            Label(k, systemImage: desc ? "arrow.down" : "arrow.up")
                        } else {
                            Text(k)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Trier les tomes")
            Menu {
                ForEach(STATUS_KEYS, id: \.self) { k in
                    Button {
                        onStatus(k)
                    } label: {
                        if status == k {
                            Label(k, systemImage: "checkmark")
                        } else {
                            Text(k)
                        }
                    }
                }
                if formats.count > 2 {
                    Divider()
                    ForEach(formats, id: \.self) { k in
                        Button {
                            onFormat(k)
                        } label: {
                            if format == k {
                                Label(k == "Tous" ? "Tous formats" : k, systemImage: "checkmark")
                            } else {
                                Text(k == "Tous" ? "Tous formats" : k)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 32, height: 32)
                    .overlay(alignment: .topTrailing) {
                        if active > 0 {
                            Text("\(active)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(cs.error))
                                .foregroundColor(Color.white)
                                .offset(x: 6, y: -2)
                        }
                    }
            }
            .accessibilityLabel("Filtrer les tomes")
        }
    }
}

// MARK: - Fiche d'un tome

/// Fiche d'un tome : couverture, résumé et métadonnées ComicInfo, fichier ; la recherche est un bouton à part.
private struct VolumeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var offline: OfflineManager
    let api: BullarrApi?
    let v: VolumeRow
    let seriesTitle: String
    let summary: SeriesSummary
    let read: Bool
    let onToggleRead: () -> Void
    let onRead: () -> Void
    let onReviews: () -> Void
    let onAuthor: (String) -> Void
    let onSearch: () -> Void
    /// Lecteur + tome manquant : « Demander ce tome » (validée par un administrateur).
    var onRequest: (() -> Void)? = nil

    @State private var big = false

    /// Valeur ComicInfo lisible (les valeurs non remplies sont des balises « <… »).
    private func c(_ key: String) -> String? {
        guard let ci = v.comicInfo, let s = ci.str(key), !s.hasPrefix("<") else { return nil }
        return s
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 0) {
                        let coverUrl = state.coverUrl(v.coverPath)
                        Button { big = true } label: {
                            Cover(url: coverUrl, width: 110)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Agrandir la couverture")
                        Spacer().frame(width: 16)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.label).font(.footnote.weight(.semibold)).foregroundColor(cs.accent)
                            Text(v.title ?? c("series") ?? v.label)
                                .font(.title3.weight(.semibold))
                            let date = [c("day"), c("month"), c("year") ?? v.year].compactMap { $0 }.joined(separator: "/")
                            let meta = [c("publisher"), date.isEmpty ? nil : date, c("genre")].compactMap { $0 }.joined(separator: " · ")
                            if !meta.isEmpty {
                                Text(meta).font(.caption).foregroundColor(cs.muted)
                            }
                            if let r = c("communityrating") {
                                Button(action: onReviews) {
                                    Text("★ \(r) / 5" + (c("communityratingcount").map { " (\($0) avis)" } ?? ""))
                                        .font(.subheadline)
                                        .foregroundColor(cs.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            if offline.isDownloaded(v.id) {
                                IconTag(icon: "pin", label: "Disponible hors ligne", tint: cs.accent, text: "Téléchargé sur le téléphone")
                            }
                            UpscaleTag(v: v)
                            if v.owned {
                                IconTag(icon: "checkmark.circle", label: "Possédé", tint: cs.accentHover)
                            } else {
                                IconTag(icon: "exclamationmark.triangle", label: "Manquant", tint: cs.tertiary)
                            }
                        }
                    }
                    // Boutons d'action, sur une rangée qui passe à la ligne.
                    FlowRow(spacing: 8) {
                        if v.owned {
                            Button(action: onRead) {
                                Image(systemName: "play")
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(cs.accent))
                                    .foregroundColor(cs.onAccent)
                            }
                            .accessibilityLabel("Lire")
                            Button(action: onToggleRead) {
                                Image(systemName: read ? "minus.circle" : "checkmark.seal")
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(cs.secondaryContainer))
                            }
                            .accessibilityLabel(read ? "Marquer comme non lu" : "Marquer comme lu")
                            OfflineButton(offline: offline, volumeId: v.id, title: "\(seriesTitle) · \(v.label)", iconOnly: true)
                        }
                        // Lecteur : pas de recherche de téléchargement (réservée aux administrateurs).
                        if !state.isReader {
                            Button(action: onSearch) {
                                Image(systemName: "magnifyingglass")
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(cs.secondaryContainer))
                            }
                            .accessibilityLabel(v.owned ? "Chercher (remplacer)" : "Chercher ce tome")
                        }
                        if onRequest != nil {
                            // Lecteur, tome manquant : « Demander ce tome », ou l'état de sa demande.
                            switch v.requested {
                            case "pending":
                                IconTag(icon: "hourglass", label: "Demandé : en attente de validation", tint: cs.tertiary, text: "Demandé")
                            case "searching":
                                IconTag(icon: "magnifyingglass", label: "Recherche du tome lancée", tint: cs.accent, text: "Recherche lancée")
                            default:
                                Button(action: onRequest!) {
                                    Image(systemName: "tray.full")
                                        .frame(width: 40, height: 40)
                                        .background(Circle().fill(cs.secondaryContainer))
                                        .foregroundColor(v.requested == "rejected" ? cs.error : cs.accent)
                                }
                                .accessibilityLabel(v.requested == "rejected" ? "Demande refusée : redemander ce tome" : "Demander ce tome")
                            }
                        }
                        if let web = c("web") {
                            Button { openInBrowser(web) } label: {
                                Logo(key: "bedetheque", label: "Bédéthèque", size: 28, tip: false)
                            }
                            .buttonStyle(.plain)
                        }
                        if let k = v.komgaUrl {
                            Button { openInBrowser(k) } label: {
                                Logo(key: "komga", label: "Lire dans Komga", size: 28, tip: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 16)
                    if let text = c("summary") {
                        Text(text).font(.subheadline).padding(.top, 16)
                    }
                    let people: [(String, String?)] = [
                        ("Scénario", c("writer")), ("Dessin", c("penciller")), ("Couleurs", c("colorist")),
                        ("Auteurs", c("writer") == nil ? v.author : nil),
                    ]
                    let file: [(String, String?)] = [
                        ("Fichier", v.filename), ("Format", v.format?.uppercased()), ("Taille", formatBytes(v.fileSize)),
                        ("Pages", v.pageCount.map { "\($0)" }), ("ISBN", v.isbn),
                    ]
                    ForEach((people + file).filter { $0.1 != nil }, id: \.0) { key, value in
                        HStack(alignment: .top, spacing: 0) {
                            Text(key).font(.caption).foregroundColor(cs.muted).frame(width: 88, alignment: .leading)
                            if ["Scénario", "Dessin", "Couleurs", "Auteurs"].contains(key) {
                                FlowRow(spacing: 10) {
                                    ForEach((value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, id: \.self) { name in
                                        Button { onAuthor(name) } label: {
                                            Text(name).font(.subheadline).foregroundColor(cs.accent).underline()
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else {
                                Text(value ?? "").font(.subheadline)
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(cs.bg)
        .presentationDetents([.large])
        .fullScreenCover(isPresented: $big) {
            galleryView
        }
    }

    /// Couverture puis quelques pages de l'album (pages du lecteur), comme l'aperçu de la fiche série.
    private var galleryView: some View {
        let coverUrl = state.coverUrl(v.coverPath)
        var images: [GalleryImage] = []
        if let coverUrl {
            images.append(GalleryImage(key: coverUrl) { await CoverLoader.shared.load(coverUrl, targetWidthPx: 1600) })
        } else {
            images.append(GalleryImage(key: "cover") { nil })
        }
        if v.owned, let api {
            for n in previewPageNumbers(v.pageCount) {
                images.append(GalleryImage(key: "\(v.id):\(n)") {
                    try? await PageCache.shared.get(api, v.id, n, offline: state.offline.store)
                })
            }
        }
        return ImageGalleryView(images: images)
    }
}

// MARK: - Menus

/// Menu d'actions d'un tome (appui long sur la ligne).
private struct VolumeActionsSheet: View {
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let api: BullarrApi?
    let v: VolumeRow
    let title: String
    let read: Bool
    let onToggleRead: () -> Void
    let onEdit: () -> Void
    let onRefresh: () -> Void
    let onMeta: () -> Void
    let onReviews: () -> Void
    let onHistory: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section {
                    Text(title).font(.headline).lineLimit(2)
                        .listRowBackground(Color.clear)
                }
                if v.owned {
                    entry(read ? "minus.circle" : "checkmark.seal", read ? "Marquer comme non lu" : "Marquer comme lu") {
                        dismiss(); onToggleRead()
                    }
                }
                entry("star", "Lire les avis") { dismiss(); onReviews() }
                entry("clock.arrow.circlepath", "Historique") { dismiss(); onHistory() }
                entry("pencil", "Éditer le tome") { dismiss(); onEdit() }
                if v.owned {
                    entry("arrow.clockwise", "Actualiser taille et pages") { dismiss(); onRefresh() }
                }
                entry("arrow.triangle.2.circlepath", "Recharger la fiche Bédéthèque") { dismiss(); onMeta() }
                entry("trash", "Supprimer", tint: cs.error) { dismiss(); onDelete() }
                // Une seule ligne « Acheter » : un logo par boutique, chacun ouvre sa recherche.
                SwiftUI.Section {
                    HStack {
                        Image(systemName: "cart").foregroundColor(cs.muted)
                        Text("Acheter")
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(ItemActions.shopLinks(v.isbn ?? title.replacingOccurrences(of: " · ", with: " ")), id: \.0) { shop, url in
                                Button {
                                    dismiss()
                                    openInBrowser(url)
                                } label: {
                                    Logo(key: shop.lowercased(), label: "Acheter sur \(shop)", size: 28, tip: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func entry(_ icon: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(tint ?? cs.muted).frame(width: 24)
                Text(label).foregroundColor(tint ?? cs.text)
                Spacer()
            }
        }
    }
}

/// Menu d'une série (appui long sur son nom) : mise à jour, scan, édition, suppression.
private struct SeriesActionsSheet: View {
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onReadAlso: () -> Void
    let onHistory: () -> Void
    let onUpdate: () -> Void
    let onScan: () -> Void
    let onEdit: () -> Void
    let onMove: (() -> Void)?
    let onDelete: () -> Void
    let allRead: Bool
    let canMarkRead: Bool
    let onToggleRead: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section {
                    Text(title).font(.headline).lineLimit(2)
                }
                if canMarkRead {
                    if allRead {
                        entry("minus.circle", "Marquer la série comme non lue") { dismiss(); onToggleRead(false) }
                    } else {
                        entry("checkmark.seal", "Marquer la série comme lue") { dismiss(); onToggleRead(true) }
                    }
                }
                entry("arrow.triangle.2.circlepath", "Mettre à jour (Bédéthèque)") { dismiss(); onUpdate() }
                entry("arrow.clockwise", "Scanner les fichiers") { dismiss(); onScan() }
                entry("pencil", "Éditer la série") { dismiss(); onEdit() }
                entry("book", "À lire aussi") { dismiss(); onReadAlso() }
                entry("clock.arrow.circlepath", "Historique") { dismiss(); onHistory() }
                if let onMove {
                    entry("externaldrive.badge.timemachine", "Déplacer dans une autre bibliothèque") { dismiss(); onMove() }
                }
                entry("trash", "Supprimer la série", tint: cs.error) { dismiss(); onDelete() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func entry(_ icon: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(tint ?? cs.muted).frame(width: 24)
                Text(label).foregroundColor(tint ?? cs.text)
                Spacer()
            }
        }
    }
}

// MARK: - Déplacement de série

/// « Déplacer dans une autre bibliothèque » (comme le site) : le dossier de la série est
/// déplacé sur le disque vers la bibliothèque choisie. Portage de MoveSeriesDialog (Android 1.10).
private struct MoveSeriesSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let currentLibraryId: Int?
    let title: String
    let onMove: (Library) -> Void

    private var targets: [Library] {
        state.libraries.filter { $0.id != currentLibraryId }
    }

    @State private var picked: Library? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Déplacer la série").font(.title3.weight(.semibold))
                    Text("Le dossier de « \(title) » est déplacé sur le disque vers la bibliothèque choisie.")
                        .font(.subheadline).foregroundColor(cs.muted)
                    if targets.isEmpty {
                        Text("Aucune autre bibliothèque.").font(.caption).foregroundColor(cs.muted)
                    }
                    ForEach(targets, id: \.id) { l in
                        HStack(spacing: 10) {
                            Image(systemName: picked?.id == l.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(cs.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.name).font(.body)
                                if let c = l.seriesCount {
                                    Text("\(c) séries").font(.caption).foregroundColor(cs.muted)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { picked = l }
                    }
                    HStack(spacing: 8) {
                        Button("Annuler") { dismiss() }.buttonStyle(OutlinedPillButtonStyle())
                        Button {
                            dismiss()
                            if let picked { onMove(picked) }
                        } label: {
                            Text("Déplacer")
                        }
                        .buttonStyle(AccentPillButtonStyle())
                        .disabled(picked == nil)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(cs.bg)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .onAppear { picked = targets.first }
    }
}

// MARK: - Feuilles Bédéthèque

/// Avis des lecteurs d'un tome (Bédéthèque), comme la fenêtre du site.
private struct ReviewsSheet: View {
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let api: BullarrApi?
    let v: VolumeRow
    let title: String

    @State private var data: JSONDict? = nil
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avis des lecteurs").font(.headline)
                        Text(title).font(.caption).foregroundColor(cs.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    if let error {
                        ErrorCard(message: error).padding(.horizontal, 20).padding(.top, 12)
                    }
                    if error == nil && data == nil {
                        ProgressView().padding(.top, 12)
                    }
                    if let d = data {
                        if d.bool("success") == false {
                            EmptyStateView(title: d.str("error") ?? "Avis introuvables")
                                .padding(.top, 12)
                        } else {
                            let reviews = d.objects("reviews")
                            if reviews.isEmpty {
                                EmptyStateView(title: "Aucun avis publié pour ce tome.")
                                    .padding(.top, 12)
                            }
                            ForEach(Array(reviews.enumerated()), id: \.offset) { _, r in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(r.str("author") ?? "Anonyme").font(.subheadline.weight(.semibold))
                                        Spacer()
                                        let rating = r.int("rating")
                                        Text([rating.map { String(repeating: "★", count: $0) + String(repeating: "☆", count: max(0, 5 - $0)) }, r.str("date")].compactMap { $0 }.joined(separator: " • "))
                                            .font(.caption)
                                            .foregroundColor(cs.muted)
                                    }
                                    if let text = r.str("text") {
                                        Text(text).font(.subheadline)
                                    }
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 20)
                                Divider()
                            }
                            if let url = d.str("album_url") {
                                Button("Voir la page sur Bédéthèque") { openInBrowser(url) }
                                    .padding(.horizontal, 20)
                                    .padding(.top, 12)
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .background(cs.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: v.id) {
            guard let api else { error = "Non connecté."; return }
            do {
                data = try await api.getObject("api/bedetheque/reviews/volume/\(v.id)")
            } catch {
                self.error = readable(error)
            }
        }
    }
}

/// « À lire aussi » de la série (Bédéthèque) : un appui ouvre la fiche, l'éclair ajoute la série et lance son téléchargement.
private struct ReadAlsoSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let seriesId: Int
    let seriesTitle: String
    /// Bibliothèque de la série affichée : c'est là que « Ajouter » crée la série (comme le site).
    var seriesLibraryId: Int? = nil

    @State private var items: [JSONDict]? = nil
    @State private var error: String? = nil
    // Lignes en cours d'ajout, et lignes ajoutées pendant que la feuille est ouverte (bouton « Ajoutée »).
    @State private var adding: Set<Int> = []
    @State private var added: Set<Int> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("À lire aussi").font(.headline)
                        Text("Sélection de Bédéthèque pour les lecteurs de « \(seriesTitle) ».").font(.caption).foregroundColor(cs.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    if let error {
                        ErrorCard(message: error).padding(.horizontal, 20).padding(.top, 12)
                    }
                    if error == nil && items == nil {
                        ProgressView().padding(.top, 12)
                    }
                    if let list = items, list.isEmpty {
                        EmptyStateView(title: "Aucune recommandation trouvée sur cette fiche Bédéthèque.")
                            .padding(.top, 12)
                    }
                    if let list = items {
                        ForEach(Array(list.enumerated()), id: \.offset) { index, r in
                            let ownId = r.int("series_id")
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.str("title") ?? "(sans titre)")
                                        .font(.subheadline)
                                        .foregroundColor(cs.text)
                                        .lineLimit(2)
                                    if ownId != nil {
                                        IconTag(icon: "checkmark.circle", label: "En bibliothèque", tint: cs.muted, text: "En bibliothèque")
                                    } else {
                                        Text("Pas dans la bibliothèque").font(.caption2).foregroundColor(cs.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let url = r.str("url") {
                                    Button { openInBrowser(url) } label: {
                                        Logo(key: "bedetheque", label: "Ouvrir sur Bédéthèque", size: 20, tip: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if adding.contains(index) {
                                    ProgressView().controlSize(.small).tint(cs.accent).padding(.horizontal, 12)
                                } else if added.contains(index) {
                                    Text("Ajoutée").font(.footnote).foregroundColor(cs.muted)
                                } else if ownId != nil {
                                    Image(systemName: "chevron.right").foregroundColor(cs.muted).padding(.horizontal, 12)
                                } else if !state.isReader {
                                    // Comme le site : ajoute la série (dans la bibliothèque de la série affichée) ;
                                    // le serveur lance la recherche de ses tomes.
                                    Button { add(index, r) } label: {
                                        Label("Ajouter", systemImage: "plus")
                                            .font(.footnote.weight(.medium))
                                            .foregroundColor(cs.accent)
                                    }
                                    .buttonStyle(OutlinedPillButtonStyle())
                                }
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let ownId {
                                    dismiss()
                                    presentAfter { state.openSeriesById(ownId, r.str("title") ?? "") }
                                } else if let url = r.str("url") {
                                    openInBrowser(url)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .background(cs.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: seriesId) {
            guard let api = state.api else { error = "Non connecté."; return }
            do {
                items = try await api.getObject("api/bedetheque/read-also/\(seriesId)").objects("items")
            } catch {
                self.error = readable(error)
            }
        }
    }

    /// Comme le site : ajoute la série dans la bibliothèque de la série affichée ; le serveur lance
    /// la recherche de ses tomes, et la fiche de la série ajoutée s'ouvre.
    private func add(_ index: Int, _ item: JSONDict) {
        let title = item.str("title") ?? "(sans titre)"
        let libraryId = seriesLibraryId ?? state.selectedLibrary?.id ?? state.libraries.first?.id
        adding.insert(index)
        Task { @MainActor in
            defer { adding.remove(index) }
            do {
                guard let api = state.api else { throw ApiException("Non connecté.") }
                guard let libraryId else { throw ApiException("Aucune bibliothèque disponible") }
                var body: JSONDict = ["library_id": libraryId]
                if let url = item.str("url") { body["url"] = url }
                let res = try await api.postObject("api/bedetheque/add-series", body)
                if (res.bool("success") ?? true) == false { throw ApiException(res.str("error") ?? "Ajout impossible") }
                let id = res.int("series_id")
                if var list = items, list.indices.contains(index) {
                    var d = list[index]
                    d["series_id"] = id
                    list[index] = d
                    items = list
                }
                added.insert(index)
                if let url = item.str("url") { state.markAdded(url) }
                ToastCenter.shared.show("« \(title) » ajoutée" + (res.bool("auto_acquire_started") == true ? ", recherche des tomes lancée" : ""))
                // Comme sur le site : la fiche de la série ajoutée s'ouvre.
                if let id {
                    dismiss()
                    presentAfter { state.openSeriesById(id, title) }
                }
            } catch {
                ToastCenter.shared.show("« \(title) » : \(readable(error))")
            }
        }
    }

    private func presentAfter(_ set: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: set)
    }
}

/// Autres séries d'un auteur (sa fiche Bédéthèque), comme la fenêtre du site. L'ajout suit le réglage du serveur.
private struct AuthorAlbumsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let name: String
    let link: String

    @State private var albums: [JSONDict]? = nil
    @State private var error: String? = nil
    /// Lignes en cours d'ajout (plusieurs possibles) : leur bouton devient un indicateur.
    @State private var pending: Set<Int> = []
    /// Sélection multiple : appui long sur un album, puis appuis pour ajouter ou retirer d'autres.
    @State private var selected: Set<Int> = []

    /// Déjà en bibliothèque, ou ajoutée pendant la session (mémorisé dans l'état global).
    private func isAdded(_ a: JSONDict) -> Bool {
        a.bool("already_in_library") == true || (a.str("bedetheque_url").map { state.addedBedethequeUrls.contains($0) } ?? false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autres séries").font(.headline)
                        Text(name).font(.caption).foregroundColor(cs.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    if !selected.isEmpty {
                        HStack {
                            Text("\(selected.count) sélectionné(s)").font(.subheadline)
                            Spacer()
                            Button {
                                addSelected()
                            } label: {
                                Image(systemName: "rectangle.stack.badge.plus").foregroundColor(cs.accent)
                            }
                            .accessibilityLabel("Ajouter la sélection")
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    }
                    if let error {
                        ErrorCard(message: error).padding(.horizontal, 20).padding(.top, 12)
                    }
                    if error == nil && albums == nil {
                        ProgressView().padding(.top, 12)
                    }
                    if let list = albums, list.isEmpty {
                        EmptyStateView(title: "Aucune autre série trouvée pour cet auteur.")
                            .padding(.top, 12)
                    }
                    if let list = albums {
                        ForEach(Array(list.enumerated()), id: \.offset) { index, a in
                            let years = [a.str("year_start"), a.str("year_end")].compactMap { $0 }.joined(separator: " – ")
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.str("title") ?? "(sans titre)").font(.subheadline).foregroundColor(cs.text)
                                    if !years.isEmpty {
                                        Text(years).font(.caption).foregroundColor(cs.muted)
                                    }
                                }
                                Spacer()
                                // Lien vers la fiche de l'album sur Bédéthèque.
                                if let u = a.str("bedetheque_url") {
                                    Button { openInBrowser(u) } label: {
                                        Logo(key: "bedetheque", label: "Ouvrir sur Bédéthèque", size: 20, tip: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if isAdded(a) {
                                    Image(systemName: "checkmark.circle").foregroundColor(cs.accentHover).padding(.leading, 8)
                                } else if pending.contains(index) {
                                    ProgressView().controlSize(.mini).padding(.leading, 8)
                                } else {
                                    Button {
                                        addAlbum(index, a)
                                    } label: {
                                        Image(systemName: "rectangle.stack.badge.plus").foregroundColor(cs.accent).padding(.leading, 8)
                                    }
                                    .accessibilityLabel("Ajouter cette série")
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                            .background(selected.contains(index) ? cs.accentContainer : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !selected.isEmpty { toggle(index) }
                            }
                            .contextMenu {
                                Button("Sélectionner") { toggle(index) }
                            }
                            Divider().padding(.leading, 20)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .background(cs.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: link) {
            guard let api = state.api else { error = "Non connecté."; return }
            do {
                albums = try await api.getObject("api/bedetheque/authors/albums", query: ["url": link]).objects("albums")
            } catch {
                self.error = readable(error)
            }
        }
    }

    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
    }

    @discardableResult
    private func add(_ index: Int, _ a: JSONDict) async throws -> Int? {
        guard let api = state.api else { throw ApiException("Non connecté.") }
        var libraryId = state.selectedLibrary?.id ?? state.libraries.first?.id
        if libraryId == nil { libraryId = parseLibraries(try await api.getArray("api/libraries")).first?.id }
        guard let libraryId else { throw ApiException("Aucune bibliothèque disponible") }
        var body: JSONDict = ["library_id": libraryId]
        if let url = a.str("bedetheque_url") { body["url"] = url }
        pending.insert(index)
        defer { pending.remove(index) }
        let res = try await api.postObject("api/bedetheque/add-series", body)
        if let url = a.str("bedetheque_url") { state.markAdded(url) }
        return res.int("series_id")
    }

    private func addSelected() {
        let chosen = selected.sorted().compactMap { i -> (Int, JSONDict)? in
            guard let list = albums, list.indices.contains(i), !isAdded(list[i]), !pending.contains(i) else { return nil }
            return (i, list[i])
        }
        selected = []
        guard !chosen.isEmpty else { return }
        launchAction("\(chosen.count) série(s) ajoutée(s)") {
            var failed = 0
            for (index, a) in chosen {
                do { try await add(index, a) } catch { failed += 1 }
            }
            if failed > 0 { throw ApiException("\(failed) série(s) n'ont pas pu être ajoutée(s)") }
        }
    }

    private func addAlbum(_ index: Int, _ a: JSONDict) {
        let title = a.str("title") ?? "(sans titre)"
        launchAction("« \(title) » ajoutée") {
            // Comme Android : la fiche de la série ajoutée s'ouvre.
            if let id = try await add(index, a) {
                await MainActor.run {
                    dismiss()
                    state.openSeriesById(id, title)
                }
            }
        }
    }
}

// MARK: - Visionneuse

/// Une image de la visionneuse : clé stable et chargement à la demande.
struct GalleryImage {
    let key: String
    let load: () async -> UIImage?
}

/// Pages d'aperçu d'un album (comme le site) : réparties dans l'album, jamais la couverture ni la dernière page.
func previewPageNumbers(_ total: Int?) -> [Int] {
    guard let total, total >= 3 else { return [] }
    return [0.20, 0.40, 0.60, 0.75]
        .map { min(max(Int($0 * Double(total)), 1), total - 2) + 1 }
        .reduce([]) { $0.contains($1) ? $0 : $0 + [$1] }
}

/// Visionneuse plein écran : couverture puis pages d'aperçu, glisser pour passer de l'une à l'autre, toucher pour fermer.
struct ImageGalleryView: View {
    let images: [GalleryImage]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                    GalleryPage(image: img)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .simultaneousGesture(TapGesture().onEnded { dismiss() })
            if images.count > 1 {
                Text("\(index + 1) / \(images.count)")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 32)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .statusBarHidden()
    }
}

private struct GalleryPage: View {
    let image: GalleryImage

    @State private var bitmap: UIImage? = nil
    @State private var failed = false

    var body: some View {
        ZStack {
            if let b = bitmap {
                Image(uiImage: b)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Text("Image indisponible").foregroundColor(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: image.key) {
            bitmap = await image.load()
            failed = bitmap == nil
        }
    }
}
