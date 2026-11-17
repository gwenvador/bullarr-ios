import SwiftUI
import UIKit

// MARK: - Albums hors ligne (OfflineScreen.kt) : lisibles sans réseau, jamais de serveur.

private struct OfflineGroup {
    let key: String
    let title: String
    let items: [OfflineStore.Item]
}

/// Premier nombre d'un libellé (« Tome 12 » → 12) pour trier les albums dans l'ordre de la série.
private func numberOf(_ label: String?) -> Int {
    guard let label, let m = label.range(of: "\\d+", options: .regularExpression) else { return Int.max }
    return Int(label[m]) ?? Int.max
}

private func searchKey(_ meta: ReaderMeta) -> String {
    normalizeTitle([meta.seriesTitle, meta.label, meta.title].compactMap { $0 }.joined(separator: " "))
}

/**
 * Albums copiés sur l'appareil : une section repliable par série, tri alpha/date/taille,
 * recherche locale, téléchargements en cours (pause, reprise, arrêt, tout reprendre).
 */
struct OfflineScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var mgr: OfflineManager
    @Environment(\.bullColors) private var cs

    @State private var all: [OfflineStore.Item] = []
    @State private var query = ""
    @State private var sort = "alpha"
    @State private var closed: [String: Bool] = [:]
    // Marquages lus/non lus : la vue suit progressVersion + un tick local.
    @State private var readTick = 0
    @State private var activeOpen = true
    @State private var groupToDelete: OfflineGroup? = nil
    @State private var toDelete: OfflineStore.Item? = nil

    private var terms: [String] {
        normalizeTitle(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private var items: [OfflineStore.Item] {
        guard !terms.isEmpty else { return all }
        return all.filter { it in
            let k = searchKey(it.meta)
            return terms.allSatisfy { t in k.contains(t) }
        }
    }

    private var groups: [OfflineGroup] {
        let grouped = Dictionary(grouping: items) { $0.meta.seriesId.map(String.init) ?? $0.meta.seriesTitle ?? "?" }
        var list = grouped.map { k, v -> OfflineGroup in
            let inside: [OfflineStore.Item] = {
                switch sort {
                case "date": return v.sorted { $0.savedAt > $1.savedAt }
                case "size": return v.sorted { $0.sizeBytes > $1.sizeBytes }
                default: return v.sorted { (numberOf($0.meta.label), $0.meta.label ?? "") < (numberOf($1.meta.label), $1.meta.label ?? "") }
                }
            }()
            return OfflineGroup(key: k, title: v.first?.meta.seriesTitle ?? "Autres", items: inside)
        }
        switch sort {
        case "date": list.sort { ($0.items.map { $0.savedAt }.max() ?? .distantPast) > ($1.items.map { $0.savedAt }.max() ?? .distantPast) }
        case "size": list.sort { $0.items.reduce(0) { $0 + $1.sizeBytes } > $1.items.reduce(0) { $0 + $1.sizeBytes } }
        default: list.sort { normalizeTitle($0.title) < normalizeTitle($1.title) }
        }
        return list
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !all.isEmpty {
                    CompactSearchField(value: $query, placeholder: "Rechercher dans les albums hors ligne…")
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                if !all.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14))
                            .foregroundColor(cs.muted)
                            .accessibilityLabel("Trier")
                        FilterChip(selected: sort == "alpha", onClick: { sort = "alpha" }, label: {
                            Image(systemName: "textformat.abc").font(.system(size: 13)).accessibilityLabel("Alphabétique")
                        })
                        FilterChip(selected: sort == "date", onClick: { sort = "date" }, label: {
                            Image(systemName: "clock").font(.system(size: 13)).accessibilityLabel("Date")
                        })
                        FilterChip(selected: sort == "size", onClick: { sort = "size" }, label: {
                            Image(systemName: "internaldrive").font(.system(size: 13)).accessibilityLabel("Taille")
                        })
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                let list = items
                Text({
                    if all.isEmpty { return "Aucun album sur l'appareil." }
                    if list.isEmpty { return "Aucun résultat pour « \(query) »." }
                    let total = list.reduce(Int64(0)) { $0 + $1.sizeBytes }
                    if !terms.isEmpty { return "\(list.count) sur \(all.count) album(s) · \(formatBytes(total) ?? "0 o")" }
                    return "\(list.count) album(s) · \(formatBytes(total) ?? "0 o") sur l'appareil"
                }())
                .font(.subheadline).foregroundColor(cs.muted)
                .padding(16)

                if !mgr.active.isEmpty {
                    activeHeader
                    if activeOpen {
                        ForEach(mgr.active.keys.sorted(), id: \.self) { id in
                            if let p = mgr.active[id] {
                                activeRow(id, p)
                                Divider()
                            }
                        }
                    }
                }

                ForEach(groups, id: \.key) { g in
                    let open = !terms.isEmpty || !(closed[g.key] ?? (groups.count > 4))
                    groupHeader(g, open: open)
                    if open {
                        ForEach(g.items, id: \.meta.volumeId) { it in
                            itemRow(it)
                            Divider().padding(.leading, 76)
                        }
                    }
                }

                if all.isEmpty && mgr.active.isEmpty {
                    EmptyStateView(
                        title: "Rien hors ligne",
                        detail: "Dans la fiche d'un tome, touchez « Télécharger hors ligne » pour le lire sans réseau."
                    )
                    .padding(.vertical, 24)
                }
            }
            .padding(.bottom, 16)
        }
        .onAppear { all = mgr.store.list() }
        .onChange(of: mgr.version) { _ in all = mgr.store.list() }
        .onChange(of: mgr.active) { _ in all = mgr.store.list() }
        .overlay {
            if let g = groupToDelete {
                ConfirmDialog(
                    title: "Supprimer la série ?",
                    text: "\(g.title)\n\(g.items.count) album(s) seront supprimés de l'appareil, \(formatBytes(g.items.reduce(Int64(0)) { $0 + $1.sizeBytes }) ?? "") libérés. Ils restent sur Bullarr.",
                    confirm: "Supprimer \(g.items.count) album(s)",
                    onConfirm: {
                        for it in g.items { mgr.delete(it.meta.volumeId) }
                        groupToDelete = nil
                    },
                    onDismiss: { groupToDelete = nil }
                )
            }
        }
        .overlay {
            if let it = toDelete {
                ConfirmDialog(
                    title: "Supprimer la copie ?",
                    text: "\(it.meta.seriesTitle ?? "Album") \(it.meta.label ?? "")\n\(formatBytes(it.sizeBytes) ?? "") seront libérés. L'album reste sur Bullarr.",
                    confirm: "Supprimer",
                    onConfirm: {
                        mgr.delete(it.meta.volumeId)
                        toDelete = nil
                    },
                    onDismiss: { toDelete = nil }
                )
            }
        }
    }

    // --- En-tête des téléchargements en cours ---------------------------------------

    private var activeHeader: some View {
        Button { activeOpen.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: activeOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cs.muted)
                Image(systemName: "arrow.down.circle").font(.system(size: 17)).foregroundColor(cs.accent)
                Text("En cours (\(mgr.active.count))").font(.headline).foregroundColor(cs.text)
                Spacer()
                let failedIds = mgr.active.filter { $0.value.error != nil }.keys.map { $0 }
                let runningIds = mgr.active.filter { $0.value.error == nil && !$0.value.paused }.keys.map { $0 }
                let pausedIds = mgr.active.filter { $0.value.paused }.keys.map { $0 }
                if !failedIds.isEmpty {
                    Button {
                        failedIds.forEach { mgr.start($0, mgr.titles[$0] ?? "Album \($0)") }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15)).foregroundColor(cs.error)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Tout reprendre (\(failedIds.count) en erreur)")
                }
                if !runningIds.isEmpty {
                    Button {
                        runningIds.forEach { mgr.pause($0) }
                    } label: {
                        Image(systemName: "pause").font(.system(size: 15)).foregroundColor(cs.text)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Tout mettre en pause")
                }
                if !pausedIds.isEmpty {
                    Button {
                        pausedIds.forEach { mgr.resume($0) }
                    } label: {
                        Image(systemName: "play").font(.system(size: 15)).foregroundColor(cs.accent)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Tout reprendre les pauses")
                }
                Button {
                    mgr.active.keys.forEach { mgr.cancel($0) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 14)).foregroundColor(cs.muted)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Tout arrêter")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activeRow(_ id: Int, _ p: OfflineProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(mgr.titles[id] ?? "Album \(id)")
                    .font(.subheadline.weight(.medium)).foregroundColor(cs.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if p.error != nil {
                    Button { mgr.start(id, mgr.titles[id] ?? "Album \(id)") } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15)).frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Reprendre")
                } else if p.paused {
                    Button { mgr.resume(id) } label: {
                        Image(systemName: "play").font(.system(size: 15)).foregroundColor(cs.accent).frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Reprendre")
                } else {
                    Button { mgr.pause(id) } label: {
                        Image(systemName: "pause").font(.system(size: 15)).frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Mettre en pause")
                }
                Button { mgr.cancel(id) } label: {
                    Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(cs.muted).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Arrêter")
            }
            if let e = p.error {
                ErrorCard(message: e)
            } else {
                ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                    .tint(cs.accent)
                Text((p.paused ? "En pause · " : "") + (p.total > 0 ? "\(p.done) / \(p.total) pages" : "Préparation…"))
                    .font(.caption).foregroundColor(cs.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // --- Groupes et albums ----------------------------------------------------------

    private func groupHeader(_ g: OfflineGroup, open: Bool) -> some View {
        let unread = g.items.filter { state.reads.status($0.meta.volumeId) == .unread }.count
        return Button {
            closed[g.key] = open
        } label: {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cs.muted)
                Text(g.title).font(.subheadline.weight(.semibold)).foregroundColor(cs.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text([unread > 0 ? "\(unread) non lu(s)" : nil,
                      "\(g.items.count) album(s)",
                      formatBytes(g.items.reduce(Int64(0)) { $0 + $1.sizeBytes })].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundColor(cs.muted)
                Button { groupToDelete = g } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundColor(cs.muted)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Supprimer tous les albums de \(g.title)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider()
    }

    private func itemRow(_ it: OfflineStore.Item) -> some View {
        let meta = it.meta
        let title = [meta.seriesTitle, meta.label.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }
            .joined(separator: " · ")
        let rowTitle = (meta.label.flatMap { $0.isEmpty ? nil : $0 }) ?? meta.title ?? title
        let st = state.reads.status(meta.volumeId)
        return Button {
            state.reading = ReaderTarget(volumeId: meta.volumeId, title: title.isEmpty ? (meta.title ?? "Album \(meta.volumeId)") : title, offline: true)
        } label: {
            HStack(spacing: 0) {
                Thumb(file: mgr.store.pageFile(meta.volumeId, 1)).padding(.trailing, 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle).font(.subheadline.weight(.medium)).foregroundColor(cs.text).lineLimit(2)
                    if let t = meta.title, t != meta.seriesTitle && t != rowTitle {
                        Text(t).font(.caption).foregroundColor(cs.muted).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        // Appui sur l'état : marquer lu / non lu.
                        Button {
                            if st == .read { state.reads.markUnread(meta.volumeId) } else { state.reads.markRead(meta.volumeId) }
                            readTick += 1
                        } label: {
                            statusTag(st, pageCount: meta.pageCount)
                        }
                        Text("\(meta.pageCount) pages · \(formatBytes(it.sizeBytes) ?? "")")
                            .font(.caption2).foregroundColor(cs.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    state.reading = ReaderTarget(volumeId: meta.volumeId, title: title.isEmpty ? (meta.title ?? "Album \(meta.volumeId)") : title, offline: true)
                } label: {
                    Image(systemName: "play").font(.system(size: 16)).foregroundColor(cs.accent)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Lire")
                Button { toDelete = it } label: {
                    Image(systemName: "trash").font(.system(size: 15)).foregroundColor(cs.muted)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Supprimer la copie")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusTag(_ st: ReadStatus, pageCount: Int) -> some View {
        switch st {
        case .unread:
            IconTag(icon: "circle", label: "Non lu", tint: cs.accent, size: 20)
        case .inProgress(let page):
            IconTag(icon: "circle.lefthalf.filled", label: "En cours · page \(page + 1)/\(pageCount)", tint: cs.tertiary, text: "\(page + 1)/\(pageCount)")
        case .read:
            IconTag(icon: "checkmark.circle.fill", label: "Lu", tint: cs.muted)
        }
    }
}

/// Miniature : première page de la copie locale.
private struct Thumb: View {
    @Environment(\.bullColors) private var cs
    let file: URL
    @State private var image: UIImage? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(cs.alt)
            .frame(width: 44, height: 61)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 44, height: 61)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "book").font(.system(size: 16)).foregroundColor(cs.muted)
                }
            }
            .task(id: file) {
                image = UIImage(contentsOfFile: file.path)
            }
    }
}
