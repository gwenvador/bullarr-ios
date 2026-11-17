import SwiftUI

private enum VolType: String, CaseIterable, Identifiable {
    case volume, integral, hs, episode
    var id: String { rawValue }

    var label: String {
        switch self {
        case .volume: "Tome"
        case .integral: "Intégrale"
        case .hs: "HS"
        case .episode: "Épisode"
        }
    }
}

private func volType(of v: VolumeRow) -> VolType {
    if v.isIntegral { return .integral }
    if v.isHs { return .hs }
    if v.isEpisode { return .episode }
    return .volume
}

/**
 * « Éditer le tome », comme la fenêtre d'édition du site : numéro / type, métadonnées (ComicInfo,
 * CBZ seulement), renommage du fichier au format standard et déplacement vers une autre série de
 * la même bibliothèque. Portage de VolumeEditSheet.kt (Android 1.10). `onChanged` recharge la fiche.
 */
struct VolumeEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let v: VolumeRow
    let seriesId: Int
    let seriesTitle: String
    let libraryId: Int?
    let others: [VolumeRow]
    let onChanged: () -> Void

    @State private var moving = false

    var body: some View {
        NavigationStack {
            Group {
                if moving {
                    MoveVolumePane(
                        v: v, seriesId: seriesId, libraryId: libraryId,
                        onBack: { moving = false },
                        onDone: { msg in
                            ToastCenter.shared.show(msg)
                            dismiss()
                            onChanged()
                        }
                    )
                } else {
                    mainPane
                }
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
    }

    private var mainPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Éditer \(v.label)").font(.title2.weight(.semibold))
                    Text(seriesTitle).font(.subheadline).foregroundColor(cs.muted)
                    if let f = v.filename {
                        Text(f).font(.caption).foregroundColor(cs.muted).lineLimit(2).truncationMode(.middle)
                    }
                }
                if v.owned {
                    VStack(alignment: .leading, spacing: 12) {
                        RenumberSection(api: state.api, v: v, others: others, onDone: done)
                        Divider()
                        if v.format?.lowercased() == "cbz" {
                            MetadataSection(v: v, onSave: saveMetadata)
                        } else {
                            sectionHeader("pencil", "Métadonnées")
                            Text("Convertissez ce tome en CBZ pour pouvoir éditer ses métadonnées.")
                                .font(.caption).foregroundColor(cs.muted)
                        }
                        Divider()
                        RenameSection(api: state.api, v: v, seriesId: seriesId, onDone: doneToastOnly)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
                } else {
                    Text("Tome non possédé : rien à éditer tant qu'aucun fichier n'a été importé pour ce numéro.")
                        .font(.caption).foregroundColor(cs.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("folder", "Déplacer vers une autre série")
                    Text("Le fichier va dans le dossier de la série choisie (même bibliothèque).")
                        .font(.caption).foregroundColor(cs.muted)
                    Button {
                        moving = true
                    } label: {
                        Text("Choisir la série…")
                    }
                    .buttonStyle(OutlinedPillButtonStyle())
                    .disabled(libraryId == nil)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
            }
            .padding(16)
        }
    }

    private func done(_ msg: String) {
        ToastCenter.shared.show(msg)
        dismiss()
        onChanged()
    }

    private func doneToastOnly(_ msg: String) {
        ToastCenter.shared.show(msg)
        onChanged()
    }

    private func saveMetadata(_ fields: [String: String]) {
        guard let api = state.api else { return }
        launchAction("Tome modifié", then: { onChanged() }, running: "Enregistrement des métadonnées de \(v.label)") {
            try await ItemActions.editVolume(api, v.id, fields)
        }
    }
}

// --- Sections -----------------------------------------------------------------

private func sectionHeader(_ icon: String, _ text: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 15)).foregroundColor(Color.accentColor)
        Text(text).font(.subheadline.weight(.semibold))
    }
}

/** Numéro / type (PUT /api/volumes/<id>/renumber) ; un tome de la série peut servir de modèle. */
private struct RenumberSection: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi?
    let v: VolumeRow
    let others: [VolumeRow]
    let onDone: (String) -> Void

    @State private var type = VolType.volume
    @State private var number = ""
    @State private var suffix = ""
    @State private var pickOpen = false
    @State private var busy = false
    @State private var error: String? = nil

    private var changed: Bool {
        type != volType(of: v) || number.trimmed != (v.number.map { String($0) } ?? "") || !suffix.trimmed.isBlank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("tag", "Numéro / type")
            HStack(spacing: 6) {
                ForEach(VolType.allCases) { t in
                    FilterChip(selected: type == t, onClick: { type = t }) { Text(t.label) }
                }
            }
            HStack(spacing: 8) {
                FormField(value: $number, label: "Numéro", keyboardType: .numberPad)
                if type == .volume {
                    FormField(value: $suffix, label: "Suffixe (Bis…)")
                }
            }
            let choices = others.filter { $0.id != v.id && !$0.isSpecial }
            if !choices.isEmpty {
                Menu {
                    ForEach(choices, id: \.id) { o in
                        Button {
                            type = volType(of: o)
                            number = o.number.map { String($0) } ?? ""
                            suffix = ""
                        } label: {
                            Text("\(o.label)\(o.title.map { " · \($0)" } ?? "")\(o.owned ? " (en bibliothèque)" : "")")
                                .lineLimit(2)
                        }
                    }
                } label: {
                    Label("Reprendre le numéro d'un tome de la série", systemImage: "chevron.down")
                        .font(.footnote)
                        .foregroundColor(cs.accent)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundColor(cs.error)
            }
            Button {
                save()
            } label: {
                if busy { ProgressView().controlSize(.small).tint(cs.accent) } else { Text("Changer le numéro") }
            }
            .buttonStyle(OutlinedPillButtonStyle())
            .disabled(!changed || busy)
        }
        .onAppear {
            type = volType(of: v)
            number = v.number.map { String($0) } ?? ""
        }
    }

    private func save() {
        guard let api else { return }
        let n = Int(number.trimmed)
        let sfx = suffix.trimmed
        let body: JSONDict = [
            "type": type.rawValue,
            "number": n.map { $0 } ?? NSNull(),
            "bis_suffix": sfx.isBlank ? NSNull() : sfx,
        ]
        Task { @MainActor in
            busy = true
            error = nil
            defer { busy = false }
            do {
                let r = try await RunningActions.shared.track("Changement du numéro de \(v.label)") {
                    try await api.putObject("api/volumes/\(v.id)/renumber", body)
                }
                if (r.bool("success") ?? true) == false { throw ApiException(r.str("error") ?? "Numéro non changé") }
                if let dup = r.str("duplicate_filename"), !dup.isBlank {
                    onDone("Numéro changé. « \(dup) » a aussi ce numéro : supprimez celui qui est en trop.")
                } else {
                    onDone("Numéro changé")
                }
            } catch {
                self.error = readable(error)
            }
        }
    }
}

/** Métadonnées ComicInfo du tome (PUT /api/volumes/<id>/manual-metadata). */
private struct MetadataSection: View {
    let v: VolumeRow
    let onSave: ([String: String]) -> Void

    private let fields: [(String, String)] = [
        ("title", "Titre"), ("year", "Année"), ("writer", "Scénario"), ("penciller", "Dessin"),
        ("colorist", "Couleurs"), ("publisher", "Éditeur"), ("genre", "Genre"), ("summary", "Résumé"),
    ]
    @State private var values: [String: String] = [:]

    private func initial(_ k: String) -> String {
        if let ci = v.comicInfo, let s = ci.str(k), !s.hasPrefix("<") { return s }
        if k == "title" { return v.title ?? "" }
        if k == "year" { return v.year ?? "" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("pencil", "Métadonnées")
            ForEach(fields, id: \.0) { k, label in
                FormField(
                    value: Binding(get: { values[k] ?? initial(k) }, set: { values[k] = $0 }),
                    label: label,
                    singleLine: k != "summary"
                )
            }
            Button { onSave(values) } label: { Text("Enregistrer les métadonnées") }
                .buttonStyle(OutlinedPillButtonStyle())
        }
    }
}

/** Renommage du fichier au format standard, ou avec un nom choisi (aperçu puis exécution). */
private struct RenameSection: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi?
    let v: VolumeRow
    let seriesId: Int
    let onDone: (String) -> Void

    @State private var custom = ""
    @State private var preview: (String, String)? = nil
    @State private var unchanged = false
    @State private var busy = false
    @State private var error: String? = nil

    private func payload() -> JSONDict {
        var b: JSONDict = ["volume_id": v.id]
        let c = custom.trimmed
        if !c.isBlank { b["custom_name"] = c }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("character.cursor.ibeam", "Renommer le fichier")
            FormField(value: $custom, label: "Nom personnalisé (facultatif)", supportingText: "Vide : format standard des réglages")
                .onChange(of: custom) { _ in preview = nil; unchanged = false }
            if let preview {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Avant : \(preview.0)").font(.caption).foregroundColor(cs.muted)
                    Text("Après : \(preview.1)").font(.caption).foregroundColor(cs.accent)
                }
            }
            if unchanged {
                Text("Déjà au format standard, rien à renommer.").font(.caption).foregroundColor(cs.muted)
            }
            if let error {
                Text(error).font(.caption).foregroundColor(cs.error)
            }
            HStack(spacing: 8) {
                Button { doPreview() } label: { Text("Aperçu") }
                    .buttonStyle(OutlinedPillButtonStyle())
                    .disabled(busy)
                Button { execute() } label: {
                    if busy { ProgressView().controlSize(.small).tint(cs.accent) } else { Text("Renommer") }
                }
                .buttonStyle(OutlinedPillButtonStyle())
                .disabled(preview == nil || busy)
            }
        }
    }

    private func doPreview() {
        guard let api else { return }
        Task { @MainActor in
            busy = true
            error = nil
            defer { busy = false }
            do {
                let r = try await api.postObject("api/series/\(seriesId)/rename/preview", payload())
                if let e = r.str("error"), !e.isBlank { throw ApiException(e) }
                let f = r.objects("files").first
                if f == nil || (f!.bool("changed") ?? false) == false {
                    preview = nil
                    unchanged = true
                } else {
                    preview = (f!.str("old_name") ?? "", f!.str("new_name") ?? "")
                    unchanged = false
                }
            } catch {
                self.error = readable(error)
            }
        }
    }

    private func execute() {
        guard let api else { return }
        Task { @MainActor in
            busy = true
            error = nil
            defer { busy = false }
            do {
                let r = try await RunningActions.shared.track("Renommage du fichier de \(v.label)") {
                    try await api.postObject("api/series/\(seriesId)/rename/execute", payload())
                }
                if let e = r.str("error"), !e.isBlank { throw ApiException(e) }
                let f = r.objects("files").first
                if let f, (f.bool("success") ?? true) == false { throw ApiException(f.str("error") ?? "Renommage impossible") }
                preview = nil
                onDone("Fichier renommé")
            } catch {
                self.error = readable(error)
            }
        }
    }
}

/**
 * Déplacement : choix de la série (même bibliothèque), puis du tome qu'il y prend
 * (PUT api/volumes/<id>/move-to-series).
 */
private struct MoveVolumePane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let v: VolumeRow
    let seriesId: Int
    let libraryId: Int?
    let onBack: () -> Void
    let onDone: (String) -> Void

    @State private var all: [SeriesSummary]? = nil
    @State private var filter = ""
    @State private var target: SeriesSummary? = nil
    @State private var slots: [JSONDict]? = nil
    @State private var slot: JSONDict? = nil
    @State private var busy = false
    @State private var confirm = false
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Déplacer \(v.label)").font(.title2.weight(.semibold))
            if let error {
                Text(error).font(.caption).foregroundColor(cs.error)
            }
            if target == nil {
                pickSeries
            } else {
                pickSlot
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cs.bg)
        .task(id: libraryId) { await loadSeries() }
        .task(id: target?.id) { await loadSlots() }
        .overlay {
            if confirm, let t = target {
                ConfirmDialog(
                    title: "Déplacer \(v.label) ?",
                    text: "Le fichier ira dans le dossier de « \(t.title) ».",
                    confirm: "Déplacer",
                    onConfirm: { move() },
                    onDismiss: { confirm = false }
                )
            }
        }
    }

    private var pickSeries: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormField(value: $filter, label: "Filtrer les séries")
            if let list = all {
                let needle = normalizeTitle(filter.trimmed)
                let matches = list.filter { normalizeTitle($0.title).contains(needle) }.prefix(60)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches), id: \.id) { s in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.body)
                                Text("\(s.ownedTomes) album(s)").font(.caption).foregroundColor(cs.muted)
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { target = s }
                            Divider()
                        }
                    }
                }
            } else {
                ProgressView().tint(cs.accent).padding(.vertical, 16)
            }
            Button("Retour", action: onBack).buttonStyle(OutlinedPillButtonStyle())
        }
    }

    @ViewBuilder
    private var pickSlot: some View {
        let t = target!
        VStack(alignment: .leading, spacing: 10) {
            Text("Vers « \(t.title) ». Quel tome devient-il dans cette série ?").font(.subheadline)
            if let list = slots {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: slot == nil ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(cs.accent)
                            Text("Même numéro que dans la série actuelle")
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { slot = nil }
                        ForEach(Array(list.enumerated()), id: \.offset) { _, o in
                            slotRow(o)
                            Divider()
                        }
                    }
                }
            } else {
                ProgressView().tint(cs.accent).padding(.vertical, 16)
            }
            HStack(spacing: 8) {
                Button("Retour") { target = nil }.buttonStyle(OutlinedPillButtonStyle())
                Button {
                    confirm = true
                } label: {
                    if busy { ProgressView().controlSize(.small).tint(cs.accent) } else { Text("Déplacer") }
                }
                .buttonStyle(OutlinedPillButtonStyle())
                .disabled(busy || slots == nil)
            }
        }
    }

    private func slotRow(_ o: JSONDict) -> some View {
        let owned = (o.bool("is_owned") ?? false)
        let title = o.str("bedetheque_title") ?? o.dict("comicinfo")?.str("title")
        var parts: [String] = []
        let lbl = volumeLabel(o)
        if !lbl.isBlank { parts.append(lbl) }
        if let t = title, !t.isBlank { parts.append(t) }
        let text = parts.joined(separator: " · ") + (owned ? " (déjà possédé)" : "")
        return HStack(spacing: 10) {
            Image(systemName: slot != nil && slot!["id"] as? Int == o.int("id") ? "largecircle.fill.circle" : "circle")
                .foregroundColor(cs.accent)
            Text(text)
                .font(.body)
                .foregroundColor(owned ? cs.muted.opacity(0.5) : cs.text)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if !owned { slot = o } }
    }

    private func loadSeries() async {
        guard let api = state.api, let libraryId else { return }
        error = nil
        do {
            let raw = try await api.getArray("api/library/\(libraryId)/series")
            all = parseSeriesList(raw).filter { $0.id != seriesId }
        } catch {
            self.error = readable(error)
        }
    }

    private func loadSlots() async {
        guard let api = state.api, let t = target else { return }
        slots = nil
        slot = nil
        error = nil
        do {
            slots = try await api.getArray("api/series/\(t.id)/volumes").objects()
        } catch {
            self.error = readable(error)
        }
    }

    private func move() {
        guard let api = state.api, let t = target else { return }
        Task { @MainActor in
            busy = true
            error = nil
            var body: JSONDict = ["target_series_id": t.id]
            if let s = slot {
                let tv: JSONDict = [
                    "volume_number": s.int("volume_number") ?? NSNull(),
                    "is_integral": s.bool("is_integral") ?? false,
                    "integral_number": s.int("integral_number") ?? NSNull(),
                    "is_hs": s.bool("is_hs") ?? false,
                    "hs_number": s.int("hs_number") ?? NSNull(),
                    "is_episode": s.bool("is_episode") ?? false,
                    "episode_number": s.int("episode_number") ?? NSNull(),
                ]
                body["target_volume"] = tv
            }
            do {
                let r = try await RunningActions.shared.track("Déplacement de \(v.label) vers « \(t.title) »") {
                    try await api.putObject("api/volumes/\(v.id)/move-to-series", body)
                }
                if (r.bool("success") ?? true) == false { throw ApiException(r.str("error") ?? "Déplacement impossible") }
                state.loadLibrary(force: true)
                busy = false
                onDone("\(v.label) déplacé vers « \(t.title) »")
            } catch {
                busy = false
                self.error = readable(error)
            }
        }
    }
}
