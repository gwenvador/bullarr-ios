import SwiftUI

// Feuille des filtres de la bibliothèque : groupes repliables de puces (type, genre, listes,
// tags, format, décennie, mise à jour, votes, volumes, taille).

struct LibraryFilterSheet: View {
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let all: [SeriesSummary]
    @State var filters: LibraryFilters
    let resultCount: Int
    let onChange: (LibraryFilters) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    groupsTop
                    groupsMid
                    groupsBottom
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(cs.bg)
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Réinitialiser") { filters = LibraryFilters() }
                        .disabled(filters.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var groupsTop: some View {
        // Type = BD / Comics / Manga (origine Bédéthèque) ; Genre = catégorie ; Format = série, one-shot, intégrale.
        if !origins.isEmpty {
            OptionGroup(title: "Type", options: origins.map { ($0, ORIGIN_NAMES[$0] ?? $0) },
                        selected: filters.origins,
                        count: { k in all.count { ($0.origin ?? "Autre") == k } },
                        flags: true,
                        set: { filters.origins = $0 })
        }
        if !genreCounts.isEmpty {
            OptionGroup(title: "Genre", options: genreCounts.map { ($0.0, $0.0) },
                        selected: filters.genres,
                        count: { k in all.count { s in s.genres.contains(k) } },
                        set: { filters.genres = $0 })
        }
        OptionGroup(title: "Listes", options: LIST_LABELS.map { ($0.0, $0.1) },
                    selected: filters.lists,
                    count: { k in all.count { listMatches(k, $0) } },
                    set: { filters.lists = $0 })
        // Beaucoup de tags : seule une partie est affichée, la recherche trouve le reste.
        if !tagCounts.isEmpty { tagsGroup }
    }

    @ViewBuilder
    private var groupsMid: some View {
        OptionGroup(title: "Format", options: TYPE_LABELS.map { ($0.0, $0.1) },
                    selected: filters.types,
                    count: { k in all.count { typeOf($0) == k } },
                    set: { filters.types = $0 })
        OptionGroup(title: "Année de parution", options: decades.map { ("\($0)", "\($0)s") },
                    selected: Set(filters.decades.map(String.init)),
                    count: { k in all.count { s in s.yearInt != nil && s.yearInt! / 10 * 10 == Int(k) } },
                    set: { filters.decades = Set($0.compactMap { Int($0) }) })
        OptionGroup(title: "Dernière mise à jour", options: UPDATED_LABELS.map { ($0.0, $0.1) },
                    selected: filters.updated,
                    count: { k in all.count { updatedMatches(k, $0, Date()) } },
                    set: { filters.updated = $0 })
    }

    @ViewBuilder
    private var groupsBottom: some View {
        OptionGroup(title: "Votes", options: VOTE_LABELS.map { ($0.0, $0.1) },
                    selected: filters.votes,
                    count: { k in all.count { voteBucket(k, $0.votes) } },
                    set: { filters.votes = $0 })
        OptionGroup(title: "Nombre de volumes", options: VOLUME_LABELS.map { ($0.0, $0.1) },
                    selected: filters.volumes,
                    count: { k in all.count { volumeBucket(k, $0.volumeCount) } },
                    set: { filters.volumes = $0 })
        if hasSizes {
            OptionGroup(title: "Taille", options: SIZE_LABELS.map { ($0.0, $0.1) },
                        selected: filters.sizes,
                        count: { k in all.count { s in s.sizeBytes.map { sizeBucket(k, $0) } == true } },
                        set: { filters.sizes = $0 })
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Taille").font(.subheadline.weight(.semibold))
                Text("Indisponible : cette version de Bullarr ne renvoie pas la taille par série. Le filtre apparaîtra dès qu'elle sera fournie.")
                    .font(.caption).foregroundColor(cs.muted)
            }
        }
        Button {
            dismiss()
        } label: {
            Text("Voir \(resultCount) série(s)")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(cs.accent))
                .foregroundColor(cs.onAccent)
        }
        .padding(.bottom, 24)
    }

    private var decades: [Int] {
        Array(Set(all.compactMap { $0.yearInt.map { $0 / 10 * 10 } })).sorted(by: >)
    }
    private var origins: [String] {
        Array(Set(all.map { $0.origin ?? "Autre" })).sorted()
    }
    /// Genres les plus fréquents d'abord.
    private var genreCounts: [(String, Int)] {
        counts(all.flatMap { $0.genres }, lowercased: true)
    }
    /// Tags les plus utilisés d'abord, comme les genres.
    private var tagCounts: [(String, Int)] {
        counts(all.flatMap { $0.tags }, lowercased: false)
    }
    private var hasSizes: Bool { all.contains { $0.sizeBytes != nil } }

    private func counts(_ values: [String], lowercased: Bool) -> [(String, Int)] {
        var map: [String: Int] = [:]
        for v in values { map[v, default: 0] += 1 }
        return map.map { ($0.key, $0.value) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let a = lowercased ? $0.0.lowercased() : $0.0
            let b = lowercased ? $1.0.lowercased() : $1.0
            return a < b
        }
    }

    /// Tags : recherche et limite d'affichage ; les tags déjà cochés restent visibles.
    @State private var tagQuery = ""

    @ViewBuilder
    private var tagsGroup: some View {
        CollapsibleSection(title: "Tags", activeCount: filters.tags.count) {
            VStack(alignment: .leading, spacing: 6) {
                FormField(value: $tagQuery, label: "Chercher un tag")
                FlowRow(spacing: 8) {
                    ForEach(shownTags, id: \.0) { tag, count in
                        FilterChip(selected: filters.tags.contains(tag),
                                   onClick: { filters.tags = toggle(filters.tags, tag) },
                                   label: { Text("\(tag) · \(count)") })
                    }
                }
                if matchingTags.count > shownTags.count {
                    Text("\(matchingTags.count - shownTags.count) autre(s) tag(s) : affinez la recherche.")
                        .font(.caption).foregroundColor(cs.muted)
                }
            }
        }
    }

    private var matchingTags: [(String, Int)] {
        let wanted = normalize(tagQuery).replacingOccurrences(of: "-", with: " ").trimmed
        guard !wanted.isEmpty else { return tagCounts }
        return tagCounts.filter { normalize($0.0).replacingOccurrences(of: "-", with: " ").contains(wanted) }
    }

    private var shownTags: [(String, Int)] {
        let m = matchingTags
        return (m.filter { filters.tags.contains($0.0) } + m.filter { !filters.tags.contains($0.0) }).prefix(TAG_LIMIT).map { $0 }
    }

    private func toggle(_ set: Set<String>, _ v: String) -> Set<String> {
        set.contains(v) ? set.subtracting([v]) : set.union([v])
    }

    /// Groupe de filtres repliable avec des options (clé, libellé) ; plus d'un type de clé.
    private struct OptionGroup: View {
        @Environment(\.bullColors) private var cs
        let title: String
        let options: [(String, String)]
        let selected: Set<String>
        let count: (String) -> Int
        var flags: Bool = false
        let set: (Set<String>) -> Void

        var body: some View {
            CollapsibleSection(title: title, activeCount: selected.count) {
                FlowRow(spacing: 8) {
                    ForEach(options, id: \.0) { k, label in
                        FilterChip(selected: selected.contains(k),
                                   onClick: { set(selected.contains(k) ? selected.subtracting([k]) : selected.union([k])) },
                                   label: {
                                       if flags && hasLogo(label.lowercased()) {
                                           HStack(spacing: 6) {
                                               Logo(key: label.lowercased(), label: label, size: 20, tip: false)
                                               Text("\(label) · \(count(k))")
                                           }
                                       } else {
                                           Text("\(label) · \(count(k))")
                                       }
                                   })
                    }
                }
            }
        }
    }
}

/// Groupe de filtres repliable : le titre se touche pour l'ouvrir ou le fermer. Replié par défaut,
/// sauf si un filtre du groupe est déjà actif (le nombre à droite du titre).
struct CollapsibleSection<Content: View>: View {
    @Environment(\.bullColors) private var cs
    @State private var open: Bool? = nil
    let title: String
    let activeCount: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open = !(open ?? (activeCount > 0))
            } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if activeCount > 0 {
                        Text("\(activeCount)").font(.caption).foregroundColor(cs.accent)
                    }
                    Spacer()
                    Image(systemName: (open ?? (activeCount > 0)) ? "chevron.up" : "chevron.down")
                        .foregroundColor(cs.muted)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            if open ?? (activeCount > 0) { content() }
        }
    }
}

/// Petite rangée qui passe à la ligne (équivalent FlowRow de Compose), via le protocole Layout.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
       FlowLayout(spacing: spacing) { content() }
    }
}

/// Dispose les sous-vues sur des rangées, chacune aussi large que possible.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
