import SwiftUI

// Édition des tags d'une série (ItemActions.kt) : une tuile retire le tag, le champ en ajoute un.
// Enregistre tout d'un coup. « Proposer avec l'IA » (POST /api/ai/series/<id>/suggest) ajoute des
// tags proposés ; rien n'est enregistré avant « Enregistrer ».

/// Message d'erreur du serveur tel quel, sans le préfixe « POST /api/... : » ni l'aide ajoutée par l'app.
func aiErrorText(_ e: Error) -> String {
    if let ae = e as? ApiException {
        var m = ae.message
        if let range = m.range(of: " : ") { m = String(m[range.upperBound...]) }
        if let nl = m.firstIndex(of: "\n") { m = String(m[..<nl]) }
        return m
    }
    return readable(e)
}

struct SeriesTagsDialog: View {
    @Environment(\.bullColors) private var cs
    let initial: [String]
    let onDismiss: () -> Void
    /// Lance la proposition de l'IA dès l'ouverture (bouton IA de la fiche série).
    var autoSuggest: Bool = false
    var onSuggest: (() async -> [String])? = nil
    var onAiSettings: (() -> Void)? = nil
    let onSave: ([String]) -> Void

    @State private var tags: [String] = []
    @State private var draft = ""
    @State private var suggested: [String]? = nil
    @State private var suggesting = false
    @State private var aiError: String? = nil
    @State private var aiDisabled = false

    var body: some View {
        BullDialog(
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if onSuggest != nil {
                            aiSection
                        }
                        if tags.isEmpty {
                            Text("Aucun tag.").foregroundColor(cs.muted)
                        }
                        FlowRow(spacing: 6) {
                            // Les tags ajoutés pendant l'édition passent en tête, en surbrillance : visibles sans défiler.
                            ForEach(tags.filter { !initial.contains($0) } + tags.filter { initial.contains($0) }, id: \.self) { tag in
                                tagTile(tag)
                            }
                        }
                        HStack(spacing: 8) {
                            FormField(value: $draft, label: "Nouveau tag", onSubmit: { addDraft() })
                                .frame(maxWidth: .infinity)
                            Button(action: addDraft) {
                                Image(systemName: "plus.circle").frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Ajouter ce tag")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 360)
            },
            buttons: {
                Button("Enregistrer") {
                    onSave(withDraft())
                }
                Button("Annuler", role: .cancel) { onDismiss() }
            }
        )
        .task {
            tags = initial
            if autoSuggest { await suggest() }
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        if suggesting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("L'IA cherche des tags… (jusqu'à une minute)")
                    .font(.caption).foregroundColor(cs.muted)
            }
        } else {
            Button {
                Task { await suggest() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Proposer avec l'IA")
                }
            }
            .buttonStyle(.bordered)
        }
        if let aiError {
            Text(aiError).font(.caption).foregroundColor(cs.error)
            if aiDisabled, let onAiSettings {
                Button("Ouvrir les réglages IA") {
                    onDismiss()
                    onAiSettings()
                }
                .font(.caption)
            }
        }
        if let list = suggested {
            let left = list.filter { !tags.contains($0) }
            if list.isEmpty {
                Text("L'IA n'a pas de nouveau tag à proposer.").font(.caption).foregroundColor(cs.muted)
            } else if !left.isEmpty {
                HStack {
                    Text("Proposés").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Tout ajouter") { tags = tags + left }.font(.subheadline)
                }
                FlowRow(spacing: 6) {
                    ForEach(left, id: \.self) { tag in
                        Button {
                            tags = tags + [tag]
                            if let idx = suggested?.firstIndex(of: tag) { suggested?.remove(at: idx) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 11))
                                Text(tag)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(cs.secondaryContainer))
                            .foregroundColor(cs.text)
                        }
                    }
                }
            }
        }
    }

    private func tagTile(_ tag: String) -> some View {
        let added = !initial.contains(tag)
        return Button {
            tags.removeAll { $0 == tag }
        } label: {
            HStack(spacing: 4) {
                Text(tag)
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(added ? cs.accentContainer : cs.alt))
            .overlay(Capsule().strokeBorder(added ? cs.accent : Color.clear, lineWidth: 1))
            .foregroundColor(cs.text)
        }
        .accessibilityLabel("Retirer \(tag)")
    }

    /// Le champ en cours compte aussi à l'enregistrement, même sans avoir touché « + ».
    private func withDraft() -> [String] {
        let tag = normalizeSeriesTag(draft)
        if !tag.isEmpty && !tags.contains(tag) { return tags + [tag] }
        return tags
    }

    private func addDraft() {
        tags = withDraft()
        draft = ""
    }

    private func suggest() async {
        guard let run = onSuggest else { return }
        suggesting = true
        aiError = nil
        aiDisabled = false
        do {
            suggested = try await run()
        } catch {
            aiError = aiErrorText(error)
            aiDisabled = (error as? ApiException)?.httpCode == 400
        }
        suggesting = false
    }
}
