import SwiftUI

// MARK: - Actions → Enrichir (bedetheque-enrich.html)

// Indispensables BD, Panthéon, Thèmes, Top 100 BDGest, Par auteur.
// Ajout d'une série : POST /api/bedetheque/add-series.

private let ENRICH_TABS = ["Indispensables BD", "Panthéon", "Thèmes", "Top 100 BDGest", "Par auteur"]
private let CATEGORIES: [(String, String)] = [("all", "Tous"), ("franco-belge", "Franco-belge"), ("comics", "Comics"), ("manga", "Manga")]
private let PANTHEON_CATEGORIES: [(String, String)] = CATEGORIES + [("fondateurs", "Fondateurs")]
private let BDGEST_ORIGINS: [(String, String)] = [("general", "Général"), ("franco-belge", "Franco-belge"), ("manga", "Manga"), ("comics", "Comics")]

/// Drapeau pour Franco-belge (France), Comics (États-Unis) et Manga (Japon) ; icônes pour Tous/Général et Fondateurs.
private func originLabel(_ key: String, _ label: String) -> some View {
    let flag: String? = { key == "franco-belge" ? "bd" : (key == "manga" ? "manga" : (key == "comics" ? "comics" : nil)) }()
    return Group {
        if let flag {
            Logo(key: flag, label: label, size: 24, tip: false)
        } else {
            Image(systemName: key == "fondateurs" ? "rosette" : "globe")
                .font(.system(size: 18))
                .accessibilityLabel(label)
        }
    }
}

/// Série affichée dans une liste d'Enrichir, quel que soit l'onglet d'origine.
private struct Discovery: Identifiable {
    let title: String
    let meta: String?
    let summary: String?
    let cover: String?
    let rank: Int?
    let url: String?
    let seriesId: Int?
    let inLibrary: Bool
    var id: String { "\(title)|\(url ?? "")|\(rank ?? 0)" }
}

private func discovery(_ o: JSONDict, _ meta: [String?]) -> Discovery {
    Discovery(
        title: o.str("title") ?? "(sans titre)",
        meta: meta.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").isEmpty
            ? nil
            : meta.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
        summary: o.str("summary"),
        cover: o.str("cover"),
        rank: o.int("rank"),
        url: o.str("url") ?? o.str("bedetheque_url"),
        seriesId: o.int("series_id"),
        inLibrary: o.bool("already_in_library") == true || o.bool("already_owned") == true || o.int("series_id") != nil,
    )
}

private struct Author: Identifiable {
    let name: String
    let url: String?
    let meta: String?
    let rank: Int?
    let owned: Bool
    var id: String { "\(name)|\(url ?? "")" }
}

/// Onglet Actions → Enrichir : découvertes Bédéthèque et BDGest, ajout à la bibliothèque.
struct EnrichScreen: View {
    @EnvironmentObject private var state: AppState
    var openSeries: (Int, String) -> Void

    var body: some View {
        if let api = state.api {
            EnrichView(api: api, openSeries: openSeries)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct EnrichView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let openSeries: (Int, String) -> Void

    @State private var tab = 0
    @State private var category = "all"
    @State private var pantheonCategory = "all"
    @State private var bdgestOrigin = "general"
    @State private var bdgestYear = Calendar.current.component(.year, from: Date())
    @State private var authorQuery = ""
    @State private var draft = ""
    // Pile de navigation interne : thème ouvert, auteur ouvert.
    @State private var theme: (String, String)? = nil
    @State private var author: Author? = nil
    @State private var cache: [String: Any] = [:]
    @State private var error: String? = nil
    @State private var loading = false
    // Ajouts mémorisés dans le ViewModel : l'icône reste « ajoutée » en changeant d'onglet ou de vue.
    @State private var adding: Set<String> = []
    @State private var attempt = 0
    @FocusState private var searchFocused: Bool

    /// Clé de la vue courante ; chaque vue n'est chargée qu'une fois (tirer pour rafraîchir côté web).
    private var key: String {
        if author != nil { return "author:\(author!.url ?? "")" }
        if theme != nil { return "theme:\(theme!.0)" }
        switch tab {
        case 0: return "ind:\(category)"
        case 1: return "pan:\(pantheonCategory)"
        case 2: return "themes"
        case 3: return "bdgest:\(bdgestYear):\(bdgestOrigin)"
        default: return "authors:\(authorQuery.trimmed)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ENRICH_TABS.indices, id: \.self) { i in
                        FilterChip(selected: tab == i, onClick: { tab = i; theme = nil; author = nil }, label: {
                            Text(ENRICH_TABS[i])
                        })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // En-tête de vue : retour quand un thème ou un auteur est ouvert, sinon filtres de l'onglet.
            if author != nil || theme != nil {
                HStack(spacing: 4) {
                    Button {
                        if author != nil { author = nil } else { theme = nil }
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 36)
                    }
                    .accessibilityLabel("Retour")
                    Text(author?.name ?? theme!.1).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 4)
            } else if tab == 0 {
                FlowRow(spacing: 8) {
                    ForEach(CATEGORIES, id: \.0) { k, l in
                        FilterChip(selected: category == k, onClick: { category = k }, label: { originLabel(k, l) })
                    }
                }
                .padding(.horizontal, 16)
            } else if tab == 1 {
                FlowRow(spacing: 8) {
                    ForEach(PANTHEON_CATEGORIES, id: \.0) { k, l in
                        FilterChip(selected: pantheonCategory == k, onClick: { pantheonCategory = k }, label: { originLabel(k, l) })
                    }
                }
                .padding(.horizontal, 16)
            } else if tab == 3 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Button { bdgestYear -= 1 } label: {
                            Image(systemName: "chevron.left").frame(width: 32, height: 36)
                        }
                        .disabled(bdgestYear <= 2000)
                        .accessibilityLabel("Année précédente")
                        Text("\(bdgestYear)").font(.headline)
                        Button { bdgestYear += 1 } label: {
                            Image(systemName: "chevron.right").frame(width: 32, height: 36)
                        }
                        .disabled(bdgestYear >= Calendar.current.component(.year, from: Date()))
                        .accessibilityLabel("Année suivante")
                    }
                    FlowRow(spacing: 8) {
                        ForEach(BDGEST_ORIGINS, id: \.0) { k, l in
                            FilterChip(selected: bdgestOrigin == k, onClick: { bdgestOrigin = k }, label: { originLabel(k, l) })
                        }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                CompactSearchField(value: $draft, placeholder: "Nom d'un auteur…")
                    .padding(.horizontal, 16)
                    .focused($searchFocused)
                    .onSubmit {
                        searchFocused = false
                        authorQuery = draft
                    }
            }

            if loading {
                ProgressView().progressViewStyle(.linear).tint(cs.accent).padding(.top, 6)
            }
            if let e = error {
                ErrorCard(message: e, onRetry: { cache.removeValue(forKey: key); attempt += 1 }).padding(16)
            }

            contentView
                .padding(.top, 6)
        }
        .task(id: "\(key)#\(attempt)") {
            if cache[key] != nil { return }
            if key == "authors:" { return }
            await load()
        }
    }

    /// Chargement de la vue courante dans le cache.
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            if key.hasPrefix("author:") {
                let o = try await api.getObject("api/bedetheque/authors/albums", query: ["url": author!.url ?? ""])
                cache[key] = o.objects("albums").map { a in
                    let years = [a.str("year_start"), a.str("year_end")].compactMap { $0 }
                    let y = Array(Set(years)).sorted().joined(separator: " – ")
                    return discovery(a, [y.isEmpty ? nil : y, a.str("flag_country")])
                }
            } else if key.hasPrefix("theme:") {
                let o = try await api.getObject("api/bedetheque/theme", query: ["slug": theme!.0])
                cache[key] = o.objects("items").map { discovery($0, [$0.str("authors"), $0.str("origin"), $0.str("note")]) }
            } else if key.hasPrefix("ind:") {
                let o = try await api.getObject("api/bedetheque/indispensables", query: ["category": category])
                cache[key] = o.objects("items").map { discovery($0, [$0.str("genre"), $0.str("category")]) }
            } else if key.hasPrefix("pan:") {
                let o = try await api.getObject("api/bedetheque/pantheon", query: ["category": pantheonCategory])
                cache[key] = o.objects("items").map { a in
                    Author(
                        name: a.str("name") ?? "?",
                        url: a.str("url"),
                        meta: [a.str("professions"), a.str("country"), a.str("dates"), a.str("notable_works")]
                            .compactMap { $0 }.joined(separator: " · ").isEmpty
                            ? nil
                            : [a.str("professions"), a.str("country"), a.str("dates"), a.str("notable_works")].compactMap { $0 }.joined(separator: " · "),
                        rank: a.int("rank"),
                        owned: a.bool("already_owned") == true,
                    )
                }
            } else if key == "themes" {
                let o = try await api.getObject("api/bedetheque/themes")
                cache[key] = o.objects("groups").map { g in
                    (g.str("name") ?? "", g.objects("themes").map { ($0.str("slug") ?? "", $0.str("name") ?? "") })
                }
            } else if key.hasPrefix("bdgest:") {
                let o = try await api.getObject("api/bdgest/top-annuel", query: ["annee": String(bdgestYear), "origine": bdgestOrigin])
                cache[key] = o.objects("items").map { discovery($0, [$0.str("volume_label"), $0.str("publisher"), $0.str("release_date"), $0.str("votes")]) }
            } else {
                let o = try await api.getObject("api/bedetheque/authors/search", query: ["q": authorQuery.trimmed])
                cache[key] = o.objects("results").map { a in
                    Author(name: a.str("name") ?? "?", url: a.str("url"), meta: nil, rank: nil, owned: false)
                }
            }
        } catch {
            self.error = readable(error)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        let data = cache[key]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if key == "themes", let groups = data as? [(String, [(String, String)])] {
                    ForEach(groups, id: \.0) { group, themes in
                        Text(group).font(.headline).padding(.leading, 16).padding(.top, 12).padding(.bottom, 6)
                        FlowRow(spacing: 8) {
                            ForEach(themes, id: \.0) { slug, name in
                                FilterChip(selected: false, onClick: { theme = (slug, name) }, label: { Text(name) })
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                } else if key.hasPrefix("pan:") || key.hasPrefix("authors:") {
                    if key == "authors:" {
                        EmptyStateView(title: "Cherchez un auteur", detail: "Sa bibliographie s'affiche, avec les séries en français à ajouter.")
                            .padding(.vertical, 16)
                    }
                    if let list = data as? [Author] {
                        if list.isEmpty {
                            EmptyStateView(title: "Aucun auteur trouvé").padding(.vertical, 16)
                        }
                        ForEach(list) { a in
                            authorRow(a)
                            Divider()
                        }
                    }
                } else if let list = data as? [Discovery] {
                    if list.isEmpty {
                        EmptyStateView(title: "Aucune série").padding(.vertical, 16)
                    }
                    ForEach(list) { d in
                        discoveryRow(d)
                        Divider()
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func authorRow(_ a: Author) -> some View {
        Button {
            if a.url != nil { author = a }
        } label: {
            HStack(spacing: 8) {
                if let r = a.rank {
                    Text("\(r)").font(.headline).foregroundColor(cs.accent).frame(width: 36, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.subheadline.weight(.medium)).foregroundColor(cs.text)
                    if let m = a.meta {
                        Text(m).font(.caption).foregroundColor(cs.muted).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if a.owned {
                    IconTag(icon: "books.vertical.fill", label: "En bibliothèque", tint: cs.tertiary)
                }
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(cs.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(a.url == nil)
    }

    private func discoveryRow(_ d: Discovery) -> some View {
        let inLibrary = d.inLibrary || (d.url.map { state.addedBedethequeUrls.contains($0) } ?? false)
        let busy = d.url.map { adding.contains($0) } ?? false
        return Button {
            if let sid = d.seriesId {
                openSeries(sid, d.title)
            } else if let url = d.url {
                openInBrowser(url)
            }
        } label: {
            HStack(spacing: 0) {
                if let r = d.rank {
                    Text("\(r)").font(.headline).foregroundColor(cs.accent).frame(width: 36, alignment: .leading)
                }
                if d.cover != nil {
                    Cover(url: d.cover, width: 44).padding(.trailing, 12)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title).font(.subheadline.weight(.medium)).foregroundColor(cs.text)
                    if let m = d.meta {
                        Text(m).font(.caption).foregroundColor(cs.muted).lineLimit(2)
                    }
                    if let s = d.summary {
                        Text(s).font(.caption).foregroundColor(cs.text.opacity(0.8)).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if inLibrary {
                    IconTag(icon: "books.vertical.fill", label: "En bibliothèque", tint: cs.tertiary).padding(.trailing, 4)
                } else if d.url != nil {
                    Button { add(d) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17))
                            .foregroundColor(busy ? cs.muted : cs.accent)
                            .frame(width: 36, height: 36)
                    }
                    .disabled(busy)
                    .accessibilityLabel("Ajouter à la bibliothèque")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(_ d: Discovery) {
        guard let url = d.url, !adding.contains(url) else { return }
        adding.insert(url)
        Task {
            defer { adding.remove(url) }
            do {
                let lib = state.selectedLibrary ?? state.libraries.first
                guard let lib else { throw ApiException("Aucune bibliothèque") }
                let o = try await api.postObject("api/bedetheque/add-series", ["url": url, "library_id": lib.id])
                state.markAdded(url)
                ToastCenter.shared.show(o.bool("already_exists") == true
                    ? "« \(d.title) » est déjà dans \(lib.name)."
                    : "« \(d.title) » ajoutée à \(lib.name).")
            } catch {
                ToastCenter.shared.show(readable(error))
            }
        }
    }
}
