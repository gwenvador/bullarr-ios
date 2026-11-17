import SwiftUI

// MARK: - Validation (Suivi, admin)

/**
 * Choix manuels que la recherche automatique n'a pas pu trancher : /api/auto-acquire/reviews.
 * Une carte par série (repliable), un bouton de téléchargement par candidat.
 */
struct ValidationScreen: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let api = state.api {
            ValidationView(api: api, state: state)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct ValidationView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    @ObservedObject var state: AppState

    @State private var reviews: [JSONDict]? = nil
    @State private var error: String? = nil
    @State private var loading = false
    @State private var expanded: Set<String> = []
    @State private var sending: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Comptes et demandes de BD à valider (il n'y a plus de page Demandes pour les administrateurs).
                AdminRequestsBlock(onOpenSeries: { sid, title in state.openSeriesById(sid, title) })

                Text("Choix de téléchargement")
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 4)
                    .padding(.top, 4)

                if loading && reviews == nil {
                    ProgressView().progressViewStyle(.linear).tint(cs.accent)
                }
                if let e = error {
                    ErrorCard(message: e, onRetry: { Task { await load() } })
                }
                if let rs = reviews, rs.isEmpty {
                    EmptyStateView(title: "Rien à valider", detail: "Aucun choix de téléchargement en attente.")
                        .padding(.vertical, 8)
                }
                ForEach(groups, id: \.0) { key, entries in
                    groupCard(key, entries)
                }
            }
            .padding(12)
        }
        .refreshable { await load() }
        .task { if reviews == nil && error == nil { await load() } }
    }

    private var groups: [(String, [JSONDict])] {
        guard let reviews else { return [] }
        var order: [String] = []
        var byKey: [String: [JSONDict]] = [:]
        for r in reviews where r.int("id") != nil {
            let sid = r.int("series_id") ?? 0
            let key = sid != 0 ? "id:\(sid)" : "t:\(r.str("series_title") ?? "")"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(r)
        }
        return order.map { ($0, byKey[$0]!) }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let arr = try await api.getArray("api/auto-acquire/reviews")
            let objs: [JSONDict] = arr.compactMap { $0 as? JSONDict }
            reviews = objs
            state.reviewCount = objs.count
        } catch {
            self.error = readable(error)
        }
        loading = false
    }

    /// Ignore des validations (par tome ou toute la série), puis recharge.
    private func ignore(_ ids: [Int], _ ok: String) {
        launchAction(ok, then: { Task { await load() } }) {
            for id in ids { _ = try? await api.postObject("api/auto-acquire/reviews/\(id)/resolve", [:]) }
        }
    }

    // --- Carte d'une série ---------------------------------------------------------

    private func groupCard(_ key: String, _ entries: [JSONDict]) -> some View {
        let open = expanded.contains(key)
        let first = entries.first ?? [:]
        let candidateCount = entries.reduce(0) { $0 + $1.objects("candidates").count }
        let authors = [first.str("bedetheque_scenaristes"), first.str("bedetheque_dessinateurs")]
            .compactMap { $0 }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>(); let authorList = authors.filter { seen.insert($0).inserted }.joined(separator: ", ")
        let labels = entries.compactMap { $0.str("volume_label") }
        let sub: [String] = entries.count == 1
            ? [labels.first, "\(candidateCount) candidat(s)"].compactMap { $0 }
            : ["\(entries.count) tomes", "\(candidateCount) candidat(s)"]
        let sid = first.int("series_id") ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 0) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(cs.text)
                    .frame(width: 30, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(first.str("series_title") ?? "(série inconnue)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(cs.text)
                    if !authorList.isEmpty {
                        Text(authorList).font(.caption).foregroundColor(cs.muted).lineLimit(2)
                    }
                    Text(sub.joined(separator: " · ")).font(.footnote.weight(.medium)).foregroundColor(cs.accent)
                    if entries.count > 1 && !open && !labels.isEmpty {
                        Text(labels.joined(separator: ", ")).font(.caption).foregroundColor(cs.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if open { expanded.remove(key) } else { expanded.insert(key) }
                }
                Button {
                    ignore(entries.compactMap { $0.int("id") }, entries.count > 1 ? "Série ignorée (\(entries.count) tomes)" : "Ignoré")
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(cs.muted)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(entries.count > 1 ? "Ignorer tous les tomes de cette série" : "Ignorer cette validation")
            }

            if open {
                if sid == 0 {
                    Text("Série non associée : à rattacher à Bédéthèque depuis l'interface web.")
                        .font(.caption).foregroundColor(cs.tertiary)
                }
                ForEach(entries.indices, id: \.self) { i in
                    let r = entries[i]
                    if let id = r.int("id") {
                        reviewEntry(r, id: id, showHeader: entries.count > 1)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cs.outlineVariant, lineWidth: 1))
    }

    /// Un tome à valider : raison, candidats et leur bouton de téléchargement.
    private func reviewEntry(_ r: JSONDict, id: Int, showHeader: Bool) -> some View {
        let candidates = r.objects("candidates").enumerated().map { $0 }
        return VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                Divider()
                HStack(alignment: .center) {
                    Text(r.str("volume_label") ?? "(tome inconnu)")
                        .font(.subheadline).foregroundColor(cs.accent)
                    Spacer()
                    Button { ignore([id], "Ignoré") } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(cs.muted)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Ignorer ce tome")
                }
            }
            if let reason = r.str("reason") {
                Text(reason).font(.caption).foregroundColor(cs.muted)
            }
            ForEach(Array(candidates), id: \.offset) { i, c in
                let idx = c.int("candidate_index") ?? i
                candidateRow(c, id: id, idx: idx)
            }
        }
    }

    private func candidateRow(_ c: JSONDict, id: Int, idx: Int) -> some View {
        let sk = "\(id):\(idx)"
        let isSending = sending.contains(sk)
        let meta = [c.str("source"), (c.long("size") ?? 0) > 0 ? formatBytes(c.long("size")) : nil, c.str("seeders").map { "\($0) seeds" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.str("filename") ?? c.str("title") ?? "(sans nom)")
                    .font(.subheadline).foregroundColor(cs.text).lineLimit(3)
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundColor(cs.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSending {
                ProgressView().frame(width: 40, height: 40)
            } else {
                Button { downloadCandidate(id, idx) } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 16))
                        .foregroundColor(cs.accent)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Télécharger ce candidat")
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(cs.outlineVariant).frame(height: 1) }
    }

    private func downloadCandidate(_ id: Int, _ idx: Int) {
        let sk = "\(id):\(idx)"
        guard !sending.contains(sk) else { return }
        sending.insert(sk)
        launchAction("Téléchargement lancé", then: {
            sending.remove(sk)
            Task { await load() }
        }) {
            let res = try await api.postObject("api/auto-acquire/reviews/\(id)/download", ["candidate_index": idx])
            if res.bool("success") == false {
                throw ApiException(res.str("message") ?? "Échec du téléchargement")
            }
        }
    }
}
