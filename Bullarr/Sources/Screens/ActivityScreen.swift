import SwiftUI

// Onglet Activité (ActivityScreen.kt) : téléchargements en cours chez les clients (qBittorrent,
// aMule, Telegram…), file d'attente de Bullarr, fichiers en attente d'import ; contrôle
// (pause / reprise / en premier), suppression, sélection multiple, assignation de série, import manuel.

private let CONTROLLABLE: Set<String> = ["qbittorrent", "amule", "telegram"]

/// Ligne suivie par Bullarr : /pending/remove (annule aussi chez le client) ; sinon suppression directe chez le client.
private let REMOVE_URLS = [
    "qbittorrent": "api/qbittorrent/remove",
    "rtorrent": "api/rtorrent/remove",
    "deluge": "api/deluge/remove",
    "amule": "api/emule/remove",
]

struct ActivityScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    @State private var status: ActivityStatus? = nil
    @State private var error: String? = nil
    @State private var busy: Int? = nil
    @State private var info: ImportInfo? = nil

    // Sélection multiple (appui long) : suppression groupée des téléchargements choisis.
    @State private var selected: Set<String> = []
    @State private var confirmBatch = false
    @State private var toDelete: (String, () async -> Void)? = nil
    @State private var assigning = false
    @State private var confirmImport = false
    @State private var importing = false
    @State private var adding = false
    @State private var addingFor: [Int] = []
    // Appui sur un album dont l'import échoue : ouvre directement la résolution (série / tome / import).
    @State private var resolving: (Int, String)? = nil

    private var importInfo: ImportInfo {
        if let info { return info }
        let i = ImportInfo(apiProvider: { [weak state] in state?.api })
        DispatchQueue.main.async { info = i }
        return i
    }

    var body: some View {
        Group {
            if state.api == nil {
                EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
            } else {
                content
            }
        }
        .background(cs.bg)
        .task { await pollLoop(4) { await refresh() } }
        .task { await pollLoop(5) { await importInfo.pollFast() } }
        .task { await pollLoop(15) { await importInfo.pollState() } }
    }

    @MainActor
    private func refresh() async {
        guard let api = state.api else { return }
        do {
            status = parseActivity(try await api.getObject("api/activity/status"))
            error = nil
        } catch {
            self.error = readable(error)
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !selected.isEmpty {
                    selectionBar
                }
                if importing {
                    // Import manuel en arrière-plan : une petite carte le signale en haut de la liste.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import manuel en cours…").font(.subheadline.weight(.semibold))
                        ProgressView().progressViewStyle(.linear).tint(cs.accent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
                }
                ImportStatusCard(info: importInfo)
                let waiting = importInfo.counts?.waiting ?? []
                if !waiting.isEmpty {
                    SectionTitleView(text: "Fichiers en attente d'import", count: waiting.count)
                    ForEach(waiting, id: \.self) { w in
                        WaitingCard(
                            w: w,
                            detail: importInfo.waitingDetail[waitingKey(w.trackingId, w.filename)],
                            selected: selected.contains("w-\(w.key)"),
                            onLongClick: { if w.trackingId != nil { toggle("w-\(w.key)") } },
                            onTap: {
                                if !selected.isEmpty {
                                    if w.trackingId != nil { toggle("w-\(w.key)") }
                                } else if let tid = w.trackingId,
                                          importInfo.waitingDetail[waitingKey(tid, w.filename)]?.reason != nil {
                                    resolving = (tid, importInfo.waitingDetail[waitingKey(tid, w.filename)]?.seriesTitle ?? w.filename)
                                }
                            },
                            onRetry: { path in await retryImportFile(state.api!, path) { Task { await importInfo.pollState() } } }
                        )
                    }
                }
                if let error {
                    ErrorCard(message: error, onRetry: { Task { await refresh() } })
                }
                if let st = status {
                    let active = st.clients.flatMap { c in c.items.map { (c, $0) } }
                    ForEach(st.clients.filter { $0.error != nil }, id: \.client) { c in
                        ErrorCard(message: "\(c.label) : \(c.error ?? "")")
                    }
                    SectionTitleView(text: "En cours", count: active.count)
                    if active.isEmpty {
                        Text("Aucun téléchargement actif chez les clients.")
                            .font(.subheadline)
                            .foregroundColor(cs.muted)
                    }
                    ForEach(Array(active.enumerated()), id: \.offset) { _, pair in
                        let (c, item) = pair
                        let key = "a-\(c.client)-\(item.clientId ?? item.name)"
                        DownloadCard(
                            item: item, clientLabel: c.label,
                            selected: selected.contains(key),
                            onLongClick: { if hasDeleter(key, st) { toggle(key) } },
                            onTap: { if !selected.isEmpty && hasDeleter(key, st) { toggle(key) } },
                            controllable: item.trackingId != nil && CONTROLLABLE.contains(c.client),
                            busy: busy == item.trackingId,
                            onAction: { a in if let tid = item.trackingId { control(tid, a) } },
                            onDelete: hasDeleter(key, st) ? { confirmDelete(item.name) {
                                if let tid = item.trackingId {
                                    _ = try? await state.api!.postObject("api/activity/pending/remove", ["id": tid])
                                } else if let cid = item.clientId, let url = REMOVE_URLS[c.client] {
                                    _ = try? await state.api!.postObject(url, ["id": cid])
                                }
                            } } : nil
                        )
                    }
                    // Les téléchargements dont le fichier est déjà sur le disque sont dans « Fichiers en
                    // attente d'import » en haut : ici seulement ceux qu'on n'y voit pas (fichiers pas encore là…).
                    let onDisk = Set((importInfo.counts?.waiting ?? []).compactMap { $0.trackingId })
                    let pendingOnly = st.pending.filter { !onDisk.contains($0.id) }
                    if !pendingOnly.isEmpty {
                        SectionTitleView(text: "En attente d'import", count: pendingOnly.count)
                    }
                    if st.pending.isEmpty {
                        Text("Rien en attente.").font(.subheadline).foregroundColor(cs.muted)
                    }
                    ForEach(pendingOnly, id: \.id) { p in
                        let key = "p-\(p.id)"
                        PendingCard(
                            p: p, problem: importInfo.blocked[p.id],
                            selected: selected.contains(key),
                            onLongClick: { toggle(key) },
                            onTap: {
                                if !selected.isEmpty {
                                    toggle(key)
                                } else if importInfo.blocked[p.id] != nil || p.exhausted || p.status == "failed" {
                                    resolving = (p.id, p.seriesTitle ?? p.title)
                                }
                            },
                            controllable: p.status == "pending" && CONTROLLABLE.contains(p.client) && (p.client == "telegram" || p.clientItemId != nil),
                            busy: busy == p.id,
                            onAction: { a in control(p.id, a) },
                            onDelete: { confirmDelete(p.title) {
                                _ = try? await state.api!.postObject("api/activity/pending/remove", ["id": p.id])
                            } }
                        )
                    }
                } else if error == nil {
                    EmptyStateView(title: "Chargement…")
                }
            }
            .padding(16)
        }
        .refreshable {
            await refresh()
            await importInfo.pollFast()
        }
        .overlay {
            if let (label, run) = toDelete {
                ConfirmDialog(
                    title: "Supprimer ce téléchargement ?",
                    text: "\(label)\n\nIl est annulé chez le client et retiré de la file de Bullarr.",
                    confirm: "Supprimer",
                    onConfirm: {
                        toDelete = nil
                        Task {
                            do { try await run(); ToastCenter.shared.show("Téléchargement supprimé") }
                            catch { ToastCenter.shared.show(readable(error)) }
                            await refresh()
                        }
                    },
                    onDismiss: { toDelete = nil }
                )
            }
            if confirmImport {
                ConfirmDialog(
                    title: selected.filter { trackers[$0] != nil }.count > 1 ? "Importer ces albums ?" : "Importer cet album ?",
                    text: selected.contains { k in trackers[k].map { importInfo.blocked[$0] != nil } == true }
                        ? "Les fichiers JPG seront convertis en CBZ."
                        : "Les fichiers prêts seront importés dans leur série.",
                    confirm: "Importer",
                    onConfirm: {
                        confirmImport = false
                        let ids = Set(selected.compactMap { trackers[$0] })
                        selected = []
                        runImport { try await manualImport(state.api!, ids) }
                    },
                    onDismiss: { confirmImport = false }
                )
            }
            if assigning {
                AssignSeriesDialog(
                    count: selected.filter { trackers[$0] != nil }.count,
                    initialQuery: guessSeriesName(selected.first.flatMap { names[$0] }),
                    onDismiss: { assigning = false },
                    onAddNew: { addingFor = selected.compactMap { trackers[$0] }; adding = true },
                    onPick: { sid, target, now in assign(sid, target, nil, importNow: now) }
                )
            }
            if let (tid, name) = resolving {
                // Album bloqué touché : résolution directe pour sa série.
                AssignSeriesDialog(
                    count: 1,
                    initialQuery: guessSeriesName(name),
                    onDismiss: { resolving = nil },
                    onAddNew: {
                        addingFor = [tid]
                        resolving = nil
                        adding = true
                    },
                    onPick: { sid, target, now in
                        resolving = nil
                        assign(sid, target, [tid], importNow: now)
                    }
                )
            }
            if adding {
                SeriesAddDialog(
                    initialQuery: guessSeriesName(
                        selected.first.flatMap { names[$0] }
                            ?? addingFor.first.flatMap { t in names.first { k, _ in trackers[k] == t }?.value }
                    ),
                    onDismiss: { adding = false },
                    onAdded: { sid, _ in
                        adding = false
                        assign(sid, nil, addingFor)
                    }
                )
            }
            if confirmBatch {
                ConfirmDialog(
                    title: "Supprimer \(selected.count) téléchargement(s) ?",
                    text: "Ils sont annulés chez le client et retirés de la file de Bullarr.",
                    confirm: "Supprimer",
                    onConfirm: {
                        confirmBatch = false
                        let keys = selected
                        selected = []
                        Task {
                            var failed: String? = nil
                            for k in keys {
                                do { try await deleters[k]?() }
                                catch { failed = readable(error) }
                            }
                            ToastCenter.shared.show(failed ?? "\(keys.count) téléchargement(s) supprimé(s)")
                            await refresh()
                        }
                    },
                    onDismiss: { confirmBatch = false }
                )
            }
        }
    }

    // --- Barre de sélection ------------------------------------------------------

    private var selectionBar: some View {
        HStack(spacing: 0) {
            Button {
                selected = []
            } label: {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Annuler la sélection")
            Text("\(selected.count)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Button {
                selected = Set(deleters.keys)
            } label: {
                Image(systemName: "checkmark.circle.badge.plus").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Tout sélectionner")
            Button {
                confirmImport = true
            } label: {
                Image(systemName: "tray.and.arrow.down").frame(width: 32, height: 32)
            }
            .disabled(!selected.contains { trackers[$0] != nil })
            .accessibilityLabel("Importer maintenant (import manuel)")
            Button {
                assigning = true
            } label: {
                Image(systemName: "link").frame(width: 32, height: 32)
            }
            .disabled(!selected.contains { trackers[$0] != nil })
            .accessibilityLabel("Assigner ou corriger la série")
            // Une seule ligne sélectionnée, avec une série : icône pour ouvrir sa fiche.
            if let key = selected.first, selected.count == 1,
               let w = (importInfo.counts?.waiting ?? []).first(where: { "w-\($0.key)" == key }),
               let d = importInfo.waitingDetail[waitingKey(w.trackingId, w.filename)],
               let sid = d.seriesId {
                Button {
                    state.openSeriesById(sid, d.seriesTitle ?? "")
                } label: {
                    Image(systemName: "books.vertical").frame(width: 32, height: 32)
                }
                .accessibilityLabel("Ouvrir la série")
            }
            Button {
                confirmBatch = true
            } label: {
                Image(systemName: "trash").foregroundColor(cs.error).frame(width: 32, height: 32)
            }
            .accessibilityLabel("Supprimer la sélection")
        }
    }

    // --- Cartes de références (clé → actions) ------------------------------------

    /// clé → suppression (annule chez le client si besoin).
    private var deleters: [String: () async -> Void] {
        var out: [String: () async -> Void] = [:]
        guard let api = state.api else { return out }
        if let st = status {
            for c in st.clients {
                for item in c.items {
                    let key = "a-\(c.client)-\(item.clientId ?? item.name)"
                    if let tid = item.trackingId {
                        out[key] = { _ = try? await api.postObject("api/activity/pending/remove", ["id": tid]) }
                    } else if let cid = item.clientId, let url = REMOVE_URLS[c.client] {
                        out[key] = { _ = try? await api.postObject(url, ["id": cid]) }
                    }
                }
            }
            for p in st.pending {
                out["p-\(p.id)"] = { _ = try? await api.postObject("api/activity/pending/remove", ["id": p.id]) }
            }
        }
        for w in importInfo.counts?.waiting ?? [] {
            guard let tid = w.trackingId else { continue }
            out["w-\(w.key)"] = { try? await deleteWaitingFile(api, tid) }
        }
        return out
    }

    private var trackers: [String: Int] {
        var out: [String: Int] = [:]
        if let st = status {
            for c in st.clients {
                for item in c.items where item.trackingId != nil {
                    out["a-\(c.client)-\(item.clientId ?? item.name)"] = item.trackingId!
                }
            }
            for p in st.pending { out["p-\(p.id)"] = p.id }
        }
        for w in importInfo.counts?.waiting ?? [] where w.trackingId != nil {
            out["w-\(w.key)"] = w.trackingId!
        }
        return out
    }

    private var names: [String: String] {
        var out: [String: String] = [:]
        if let st = status {
            for c in st.clients {
                for item in c.items {
                    out["a-\(c.client)-\(item.clientId ?? item.name)"] = item.seriesTitle ?? item.name
                }
            }
            for p in st.pending { out["p-\(p.id)"] = p.seriesTitle ?? p.title }
        }
        for w in importInfo.counts?.waiting ?? [] where w.trackingId != nil {
            out["w-\(w.key)"] = w.filename
        }
        return out
    }

    private func hasDeleter(_ key: String, _ st: ActivityStatus) -> Bool {
        for c in st.clients {
            for item in c.items where "a-\(c.client)-\(item.clientId ?? item.name)" == key {
                return item.trackingId != nil || (item.clientId != nil && REMOVE_URLS[c.client] != nil)
            }
        }
        if key.hasPrefix("p-") { return true }
        return false
    }

    // --- Actions -----------------------------------------------------------------

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    private func confirmDelete(_ label: String, _ run: @escaping () async -> Void) {
        toDelete = (label, run)
    }

    @MainActor
    private func control(_ trackingId: Int, _ action: String) {
        guard let api = state.api else { return }
        busy = trackingId
        Task {
            defer { busy = nil }
            do {
                _ = try await api.postObject("api/activity/download-control", ["tracking_id": trackingId, "action": action])
                switch action {
                case "pause": ToastCenter.shared.show("Mis en pause")
                case "resume": ToastCenter.shared.show("Reprise demandée")
                default: ToastCenter.shared.show("Passé en premier")
                }
                await refresh()
            } catch {
                ToastCenter.shared.show(readable(error))
            }
        }
    }

    // Import manuel en arrière-plan : il survit à un changement d'écran (la carte le signale en
    // haut de la liste) et le résultat s'affiche en toast à la fin.
    private func runImport(_ work: @escaping () async throws -> String) {
        guard let api = state.api else { return }
        importing = true
        Task { @MainActor in
            let message: String
            do {
                message = try await RunningActions.shared.track("Import manuel") { try await work() }
            } catch {
                message = readable(error)
            }
            importing = false
            ToastCenter.shared.show(message)
            await refresh()
            await importInfo.pollState()
        }
    }

    private func assign(_ seriesId: Int, _ target: VolumeTarget?, _ only: [Int]?, importNow: Bool = false) {
        let ids = only ?? selected.compactMap { trackers[$0] }
        selected = []
        Task {
            guard let api = state.api else { return }
            var failed: String? = nil
            for tid in ids {
                do {
                    var body: JSONDict = ["tracking_id": tid, "series_id": seriesId]
                    target?.putInto(&body)
                    _ = try await api.postObject("api/activity/update-tracking", body)
                } catch {
                    failed = readable(error)
                }
            }
            if importNow && failed == nil {
                // Assigné puis importé tout de suite (comme « Importer » sur la sélection).
                runImport { try await manualImport(api, Set(ids), target) }
            } else {
                ToastCenter.shared.show(failed ?? "\(ids.count) téléchargement(s) assigné(s)")
            }
            await refresh()
        }
    }
}

// MARK: - Cartes

private struct SectionTitleView: View {
    @Environment(\.bullColors) private var cs
    let text: String
    let count: Int

    var body: some View {
        Text("\(text) (\(count))")
            .font(.headline)
            .padding(.top, 8)
    }
}

private func isPausedState(_ state: String?) -> Bool {
    guard let s = state?.lowercased() else { return false }
    return s.contains("paus") || s.contains("stop")
}

private struct DownloadCard: View {
    @Environment(\.bullColors) private var cs
    let item: DownloadItem
    let clientLabel: String
    let selected: Bool
    let onLongClick: () -> Void
    let onTap: () -> Void
    let controllable: Bool
    let busy: Bool
    let onAction: (String) -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([item.seriesTitle, item.volume.isBlank ? nil : item.volume].compactMap { $0 }.joined(separator: " · ").ifBlank(item.name))
                .font(.subheadline.weight(.semibold))
            Text(item.name).font(.caption).foregroundColor(cs.muted).lineLimit(2)
            ProgressView(value: min(1, max(0, item.progress / 100.0)))
                .progressViewStyle(.linear)
            let parts: [String] = {
                var p: [String] = [String(format: "%.1f %%", item.progress).replacingOccurrences(of: ".", with: ",")]
                if item.sizeBytes != nil {
                    p.append("\(formatBytes(item.downloadedBytes) ?? "0") / \(formatBytes(item.sizeBytes) ?? "?")")
                }
                if let speed = item.speed, speed > 0 { p.append("\(formatBytes(speed) ?? "?")/s") }
                if let eta = formatDuration(item.eta) { p.append("reste \(eta)") }
                if let state = item.state { p.append(state) }
                return p
            }()
            HStack(spacing: 6) {
                if let key = logoKey(clientLabel) {
                    Logo(key: key, label: clientLabel, size: 20, tip: false)
                    if !hasLogo(key) {
                        Text(clientLabel).font(.caption)
                    }
                } else {
                    Text(clientLabel).font(.caption)
                }
                Text(parts.joined(separator: " · ")).font(.caption).lineLimit(1)
            }
            if controllable || onDelete != nil {
                Controls(paused: isPausedState(item.state), busy: busy, onAction: onAction, controllable: controllable, onDelete: onDelete)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? cs.accentContainer : cs.surface))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.4) { onLongClick() }
    }
}

private struct PendingCard: View {
    @Environment(\.bullColors) private var cs
    let p: PendingDownloadItem
    let problem: String?
    let selected: Bool
    let onLongClick: () -> Void
    let onTap: () -> Void
    let controllable: Bool
    let busy: Bool
    let onAction: (String) -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text([p.seriesTitle, p.volume.isBlank ? nil : p.volume].compactMap { $0 }.joined(separator: " · ").ifBlank(p.title))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                if let problem {
                    IconTag(icon: "exclamationmark.circle", label: "Import impossible", tint: cs.error, text: problem)
                } else {
                    let s = statusInfo(p)
                    IconTag(icon: s.0, label: s.1, tint: s.2)
                }
            }
            Text(p.title).font(.caption).foregroundColor(cs.muted).lineLimit(2)
            if let problem {
                Text(problem).font(.caption).foregroundColor(cs.error)
            }
            let total = p.bytesTotal
            if p.status == "pending", let total, total > 0 {
                ProgressView(value: min(1, max(0, Double(p.bytesDownloaded ?? 0) / Double(total))))
                    .progressViewStyle(.linear)
            }
            let parts: [String] = {
                var out: [String] = []
                if let total, total > 0 {
                    out.append("\(formatBytes(p.bytesDownloaded) ?? "0") / \(formatBytes(total))")
                }
                if p.isPack { out.append("pack") }
                switch p.localCopy {
                case "present": out.append("fichiers arrivés")
                case "settling": out.append("copie en cours")
                case "absent": out.append("fichiers pas encore là")
                default: break
                }
                if p.exhausted { out.append("tentatives épuisées") }
                if let created = p.createdAt { out.append(String(created.prefix(16))) }
                return out
            }()
            HStack(spacing: 6) {
                let c = p.client
                if let key = logoKey(c) {
                    Logo(key: key, label: c, size: 20, tip: false)
                    if !hasLogo(key) {
                        Text(c).font(.caption)
                    }
                } else {
                    Text(c).font(.caption)
                }
                Text(parts.joined(separator: " · ")).font(.caption).lineLimit(2)
            }
            Controls(paused: p.paused, busy: busy, onAction: onAction, controllable: controllable, onDelete: onDelete)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? cs.accentContainer : cs.surface))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.4) { onLongClick() }
    }

    /// Icône + libellé + couleur de l'état du téléchargement en attente.
    private func statusInfo(_ p: PendingDownloadItem) -> (String, String, Color) {
        if p.paused { return ("pause.circle", "En pause", cs.tertiary) }
        if p.status == "completed" { return ("checkmark.circle", "Prêt à importer", cs.accent) }
        if p.status == "importing" { return ("arrow.triangle.2.circlepath", "Import en cours", cs.accent) }
        return ("clock", "En attente", cs.muted)
    }
}

/// Boutons de contrôle d'un téléchargement : pause / reprise, priorité, suppression.
private struct Controls: View {
    @Environment(\.bullColors) private var cs
    let paused: Bool
    let busy: Bool
    let onAction: (String) -> Void
    let controllable: Bool
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if controllable {
                actionButton(paused ? "play" : "pause", paused ? "Reprendre" : "Pause") { onAction(paused ? "resume" : "pause") }
                actionButton("line.3.horizontal", "En premier") { onAction("top") }
                if !paused {
                    // L'état exact n'est pas toujours connu (aMule, Telegram) : la reprise reste accessible.
                    actionButton("play", "Reprendre") { onAction("resume") }
                }
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(cs.error).frame(width: 32, height: 32)
                }
                .disabled(busy)
                .accessibilityLabel("Supprimer")
            }
        }
    }

    private func actionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 32, height: 32)
        }
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

/// Fichier en attente d'import : nom, taille, série assignée, raison de l'arrêt, réessai.
private struct WaitingCard: View {
    @Environment(\.bullColors) private var cs
    let w: WaitingFile
    let detail: WaitingDetail?
    let selected: Bool
    let onLongClick: () -> Void
    let onTap: () -> Void
    let onRetry: (String) async -> String

    @State private var retrying = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(w.filename).font(.subheadline).lineLimit(2)
                // Taille et série assignée ; sans détail (pas encore chargé), seule la ligne d'action reste.
                if let d = detail {
                    Text([d.sizeBytes.flatMap { formatBytes($0) },
                          d.seriesTitle.map { "Série : \($0)" } ?? "Aucune série assignée"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(cs.muted)
                }
                // Raison pour laquelle le fichier n'est pas importé tout seul ; « prêt » s'il n'y en a pas.
                let reason = detail?.reason
                Text(w.trackingId == nil
                     ? "Pas de téléchargement suivi : à traiter depuis la page Import du site"
                     : (reason != nil ? "Pas importé : \(reason!)" : "Prêt à importer"))
                    .font(.caption)
                    .foregroundColor(reason != nil ? cs.tertiary : cs.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fichier refusé (incomplet, copie pas finie, échec de lecture) : le serveur le retente
            // seul (5 s, 10 s, 30 s puis toutes les 30 min) ; « Réessayer » le revérifie tout de suite.
            if let path = detail?.filepath, let why = detail?.reason,
               why.hasPrefix("Échec") || why.hasPrefix("Fichier") {
                if retrying {
                    ProgressView().controlSize(.small).padding(12)
                } else {
                    Button {
                        retrying = true
                        Task {
                            let msg = await onRetry(path)
                            ToastCenter.shared.show(msg)
                            retrying = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Réessayer l'import")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? cs.accentContainer : cs.surface))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.4) { onLongClick() }
    }
}

// MARK: - Helpers

/// Supprime le fichier en attente [trackingId] du disque, comme le bouton Supprimer de la page Import.
func deleteWaitingFile(_ api: BullarrApi, _ trackingId: Int) async throws {
    guard let file = try await api.getObject("api/import/state").objects("files").first(where: {
        $0.dict("destination")?.int("tracking_id") == trackingId
    }) else {
        throw ApiException("Fichier introuvable sur le disque : rien à supprimer.")
    }
    _ = try await api.deleteObject("api/import/file", [
        "import_root": file.str("import_root") ?? "",
        "relative_path": file.str("relative_path") ?? "",
        "filename": file.str("filename") ?? "",
        "client": file.str("client") ?? "",
    ])
}

/// Nom de série probable à partir d'un nom de fichier de release (« Tomka.le.gitan.FR.[JPG]-NOTAG » → « Tomka le gitan »).
func guessSeriesName(_ raw: String?) -> String {
    guard let raw, !raw.isBlank else { return "" }
    var t = raw.replacingOccurrences(of: "\\[[^]]*]|\\([^)]*\\)", with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: "-[A-Za-z0-9]+$", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    // « Série - Titre de l'album - Intégral » : la série est la première partie.
    t = String(t.split(separator: " - ", maxSplits: 1).first ?? "")
    let noise: Set<String> = ["fr", "french", "notag", "cbz", "cbr", "pdf", "scan", "comics", "bd", "ebook", "hd", "jpg"]
    return t.split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
        .filter { !$0.isBlank && !noise.contains($0.lowercased()) }
        .joined(separator: " ")
        .trimmed
}

/**
 * Import manuel des téléchargements suivis [trackingIds] (comme la page /import du web) : les dossiers de pages
 * en vrac sont convertis en CBZ, puis les fichiers prêts sont importés (POST /api/import/execute).
 * Renvoie un résumé lisible, avec le détail de chaque échec.
 */
func manualImport(_ api: BullarrApi, _ trackingIds: Set<Int>, _ target: VolumeTarget? = nil) async throws -> String {
    var state = try await api.getObject("api/import/state")
    var notes: [String] = []
    let folders = state.objects("incompatible_folders").filter { trackingIds.contains($0.int("pack_download_id") ?? -1) }
    for f in folders {
        do {
            _ = try await api.postObject("api/import/incompatible-folder/convert-to-cbz", [
                "import_root": f.str("import_root") ?? "",
                "relative_path": f.str("relative_path") ?? "",
            ])
            notes.append("\(f.str("folder_name") ?? "?") converti en CBZ")
        } catch {
            notes.append("\(f.str("folder_name") ?? "?") : conversion impossible (\(readable(error)))")
        }
    }
    if !folders.isEmpty { state = try await api.getObject("api/import/state") }
    let files = state.objects("files").filter { trackingIds.contains($0.dict("destination")?.int("tracking_id") ?? -1) }
    var ready = files.filter { $0.dict("destination")?.int("series_id") != nil }
    // Tome choisi à la main (ex. intégrale sans numéro dans le nom) : écrit dans « parsed », comme la page /import du web.
    if let target {
        var overridden: [JSONDict] = []
        for var f in ready {
            var parsed = f.dict("parsed") ?? JSONDict()
            let n: Any = target.number ?? NSNull()
            switch target.kind {
            case .tome:
                parsed["volume"] = n
                parsed["is_integral"] = false
                parsed["integral_number"] = NSNull()
                parsed["is_hs"] = false
                parsed["hs_number"] = NSNull()
                parsed["is_episode"] = false
                parsed["episode_number"] = NSNull()
            case .integral:
                parsed["volume"] = NSNull()
                parsed["is_integral"] = true
                parsed["integral_number"] = n
                parsed["is_hs"] = false
                parsed["hs_number"] = NSNull()
                parsed["is_episode"] = false
                parsed["episode_number"] = NSNull()
            case .hs:
                parsed["volume"] = NSNull()
                parsed["is_integral"] = false
                parsed["integral_number"] = NSNull()
                parsed["is_hs"] = true
                parsed["hs_number"] = n
                parsed["is_episode"] = false
                parsed["episode_number"] = NSNull()
            case .episode:
                parsed["volume"] = NSNull()
                parsed["is_integral"] = false
                parsed["integral_number"] = NSNull()
                parsed["is_hs"] = false
                parsed["hs_number"] = NSNull()
                parsed["is_episode"] = true
                parsed["episode_number"] = n
            }
            parsed["is_special"] = false
            parsed["special_label"] = NSNull()
            parsed["tracked_volume_conflict"] = NSNull()
            f["parsed"] = parsed
            f["manual_override"] = true
            overridden.append(f)
        }
        ready = overridden
    }
    let unassigned = files.count - ready.count
    if unassigned > 0 { notes.append("\(unassigned) fichier(s) sans série assignée (utilisez « Assigner la série » d'abord)") }
    if ready.isEmpty {
        return (["Rien à importer pour cette sélection."] + notes).joined(separator: "\n")
    }
    let res = try await api.postObject("api/import/execute", ["files": ready])
    let parts: [String?] = [
        (res.int("imported_count") ?? 0) > 0 ? "\(res.int("imported_count")!) importé(s)" : nil,
        (res.int("replaced_count") ?? 0) > 0 ? "\(res.int("replaced_count")!) remplacé(s)" : nil,
        (res.int("skipped_count") ?? 0) > 0 ? "\(res.int("skipped_count")!) ignoré(s)" : nil,
        (res.int("failed_count") ?? 0) > 0 ? "\(res.int("failed_count")!) en échec" : nil,
    ]
    let failures = (res.array("failures") ?? []).prefix(3).map { JSON.stringify($0) }
    return ([parts.compactMap { $0 }.joined(separator: " · ").ifBlank("Import terminé.")] + failures + notes).joined(separator: "\n")
}

/// POST /api/import/rescan-file : revérifie un fichier refusé et efface son état d'échec, puis relance le scan.
func retryImportFile(_ api: BullarrApi, _ filepath: String, _ rescan: () -> Void) async -> String {
    do {
        let r = try await api.postObject("api/import/rescan-file", ["filepath": filepath])
        rescan()
        if r.bool("success") == true && r.bool("valid") == true {
            return "Fichier lisible : il sera importé."
        }
        if r.bool("success") == true {
            return "Toujours illisible : \(r.str("error") ?? "fichier incomplet"). Le fichier n'est peut-être pas encore complet."
        }
        return r.str("error") ?? "Nouvelle vérification impossible."
    } catch {
        return readable(error)
    }
}
