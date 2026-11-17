import SwiftUI

// IA de Bullarr (routes /api/ai, voir blueprints/ai/routes.py côté serveur) : réglages du fournisseur,
// création et normalisation des tags, historique. Les clés API ne sont jamais relues en clair :
// le serveur renvoie « **** » quand une clé est enregistrée, et renvoyer « **** » la garde.

private let AI_MASK = "****"

struct AiModel: Identifiable {
    let id: String
    let name: String
}

struct AiProvider {
    let id: String
    let name: String
    let model: String
    let models: [AiModel]
    let dynamicModels: Bool
    let hasKey: Bool
    let keyHint: String
    let keyPlaceholder: String?
    let keyUrl: String?
    /// « required », « optional » ou « none ».
    let keyMode: String
    let llm: Bool
    let baseUrl: String?
    let defaultBaseUrl: String?
}

private func parseAiProviders(_ o: JSONDict) -> [AiProvider] {
    o.objects("providers").map { p in
        AiProvider(
            id: p.str("id") ?? "",
            name: p.str("name") ?? p.str("id") ?? "",
            model: p.str("model") ?? "",
            models: p.objects("models").map { AiModel(id: $0.str("id") ?? "", name: $0.str("name") ?? $0.str("id") ?? "") },
            dynamicModels: p.bool("dynamic_models") == true,
            hasKey: p.bool("has_api_key") == true,
            keyHint: p.str("api_key_hint") ?? "",
            keyPlaceholder: p.str("key_placeholder"),
            keyUrl: p.str("key_url"),
            keyMode: p.str("key") ?? "required",
            llm: p.bool("llm") != false,
            baseUrl: p.str("base_url"),
            defaultBaseUrl: p.str("default_base_url"),
        )
    }
}

/// Formulaire des réglages : modèle, clé et adresse se règlent par fournisseur, comme sur le site.
@MainActor
final class AiForm: ObservableObject {
    let providers: [AiProvider]
    @Published var enabled: Bool
    @Published var autoTagNew: Bool
    @Published var provider: String
    @Published var models: [String: String]
    @Published var extraModels: [String: [AiModel]]
    /// Clé saisie ; vide = garder la clé enregistrée.
    @Published var keys: [String: String]
    @Published var baseUrl: String

    init(_ o: JSONDict) {
        providers = parseAiProviders(o)
        enabled = o.bool("enabled") == true
        autoTagNew = o.bool("auto_tag_new") == true
        provider = o.str("provider") ?? providers.first?.id ?? ""
        var m: [String: String] = [:]
        providers.forEach { m[$0.id] = $0.model }
        models = m
        extraModels = [:]
        keys = [:]
        baseUrl = providers.first { $0.id == "local" }?.baseUrl ?? ""
    }

    var current: AiProvider? { providers.first { $0.id == provider } }

    /// Corps envoyé à /config, /test ou /models pour le fournisseur choisi.
    func body(withModel: Bool = true) -> JSONDict {
        let p = current
        var b: JSONDict = ["provider": provider]
        if withModel { b["model"] = models[provider] ?? p?.model ?? "" }
        if let p, p.keyMode != "none" {
            let typed = (keys[provider] ?? "").trimmed
            b["api_key"] = typed.isBlank ? (p.hasKey ? AI_MASK : "") : typed
        }
        if provider == "local" { b["base_url"] = baseUrl.trimmed }
        return b
    }
}

struct AiSettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    @State private var form: AiForm? = nil
    @State private var loadError: String? = nil
    @State private var reload = 0
    @State private var stats: JSONDict? = nil
    @State private var job: JSONDict? = nil
    @State private var poll = 0
    @State private var history: [JSONDict]? = nil
    @State private var historyTick = 0

    var body: some View {
        Group {
            if let api = state.api {
                content(api)
            } else {
                EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
            }
        }
        .background(cs.bg)
    }

    @ViewBuilder
    private func content(_ api: BullarrApi) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("L'IA propose des tags pour les séries (genre, thèmes, ambiance) et regroupe les tags en double. Elle ajoute des tags, elle n'en retire jamais.")
                    .font(.caption)
                    .foregroundColor(cs.muted)
                    .padding(.horizontal, 4)
                if let loadError {
                    ErrorCard(message: loadError, onRetry: { reload += 1 })
                }
                if let f = form {
                    AiProviderCard(api: api, f: f, onSaved: { reload += 1 })
                    AiJobsCard(api: api, f: f, stats: stats, job: job, onStarted: { poll += 1 }, onApplied: { job = nil; historyTick += 1; reload += 1 })
                    AiHistoryCard(api: api, entries: history, onCleared: { historyTick += 1 }, onOpenSeries: { id, title in state.openSeriesById(id, title) })
                } else if loadError == nil {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: .infinity)
                }
            }
            .padding(12)
        }
        .refreshable {
            reload += 1
            historyTick += 1
        }
        .task(id: reload) {
            loadError = nil
            do {
                form = AiForm(try await api.getObject("api/ai/config"))
            } catch {
                loadError = readable(error)
            }
        }
        .task(id: "\(reload)-\(historyTick)") {
            stats = try? await api.getObject("api/ai/stats")
            history = (try? await api.getObject("api/ai/history"))?.objects("entries")
        }
        // Suivi du traitement en cours : toutes les 2 s tant qu'il tourne.
        .task(id: poll) {
            while !Task.isCancelled {
                guard let j = try? await api.getObject("api/ai/job") else { break }
                let was = job?.str("status")
                job = j
                if j.str("status") != "running" {
                    if was == "running" { historyTick += 1 }
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

// MARK: - Styles de boutons

private struct AiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.bullColors) private var cs
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(cs.accent))
            .foregroundColor(cs.onAccent)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct AiOutlinedButtonStyle: ButtonStyle {
    @Environment(\.bullColors) private var cs
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(Capsule().strokeBorder(cs.outlineVariant, lineWidth: 1))
            .foregroundColor(cs.text)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Cartes

private struct AiCard<Content: View>: View {
    @Environment(\.bullColors) private var cs
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(cs.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundColor(cs.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }
}

private struct AiSwitchRow: View {
    @Environment(\.bullColors) private var cs
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(cs.muted)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}

// MARK: - Fournisseur

private struct AiProviderCard: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    @ObservedObject var f: AiForm
    let onSaved: () -> Void

    @State private var busy = false
    @State private var testing = false
    @State private var loadingModels = false
    @State private var message: (String, Bool)? = nil

    var body: some View {
        AiCard(title: "IA", icon: "cpu", subtitle: f.enabled ? "Activée · \(f.current?.name ?? f.provider)" : "Désactivée") {
            providerContent
        }
    }

    @ViewBuilder
    private var providerContent: some View {
        AiSwitchRow(title: "Activer l'IA", isOn: $f.enabled)
        AiSwitchRow(
            title: "Taguer les nouvelles séries",
            detail: "Les séries ajoutées reçoivent leurs tags automatiquement.",
            isOn: $f.autoTagNew,
        )
        Text("Fournisseur").font(.subheadline)
        FlowRow(spacing: 8) {
            ForEach(f.providers, id: \.id) { pr in
                FilterChip(selected: f.provider == pr.id) {
                    f.provider = pr.id
                    message = nil
                } label: {
                    Text(pr.name)
                }
            }
        }
        if let p = f.current {
            if !p.llm {
                Text("Ce fournisseur propose des tags mais ne sait pas regrouper les tags en double.")
                    .font(.caption)
                    .foregroundColor(cs.muted)
            }
            modelRow(p)
            if p.keyMode != "none" { keyField(p) }
            if p.id == "local" {
                FormField(
                    value: $f.baseUrl,
                    label: "Adresse du LLM local",
                    placeholder: p.defaultBaseUrl ?? "",
                    leadingIcon: "link",
                    keyboardType: .URL,
                )
            }
        }
        if let (m, err) = message {
            if err {
                ErrorCard(message: m)
            } else {
                Text(m).font(.subheadline).foregroundColor(cs.accent)
            }
        }
        buttonsRow
        Text("Le test utilise les valeurs saisies, sans les enregistrer.")
            .font(.caption)
            .foregroundColor(cs.muted)
    }

    /// Liste des modèles du fournisseur : celle du serveur, complétée par le modèle choisi s'il n'y figure plus.
    private func modelList(_ p: AiProvider) -> [AiModel] {
        let extra = f.extraModels[p.id] ?? p.models
        let sel = f.models[p.id] ?? p.model
        if !sel.isBlank && !extra.contains(where: { $0.id == sel }) {
            return extra + [AiModel(id: sel, name: sel)]
        }
        return extra
    }

    @ViewBuilder
    private func modelRow(_ p: AiProvider) -> some View {
        let list = modelList(p)
        let sel = f.models[p.id] ?? p.model
        if !list.isEmpty {
            HStack(spacing: 0) {
                Menu {
                    ForEach(list) { m in
                        Button(m.name) { f.models[p.id] = m.id }
                    }
                } label: {
                    HStack {
                        Text(list.first { $0.id == sel }?.name ?? sel)
                            .foregroundColor(cs.text)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(cs.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(cs.fieldBackgroundOnCard))
                }
                if p.dynamicModels {
                    if loadingModels {
                        ProgressView().controlSize(.small).frame(width: 36, height: 36)
                    } else {
                        Button {
                            loadingModels = true
                            message = nil
                            Task {
                                do {
                                    let res = try await api.postObject("api/ai/models", f.body(withModel: false))
                                    f.extraModels[p.id] = res.objects("models").map { AiModel(id: $0.str("id") ?? "", name: $0.str("name") ?? $0.str("id") ?? "") }
                                } catch {
                                    message = (aiErrorText(error), true)
                                }
                                loadingModels = false
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Recharger la liste des modèles")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyField(_ p: AiProvider) -> some View {
        let placeholder = p.hasKey ? "Enregistrée \(p.keyHint) — laisser vide pour la garder" : (p.keyPlaceholder ?? "")
        FormField(
            value: Binding(get: { f.keys[p.id] ?? "" }, set: { f.keys[p.id] = $0 }),
            label: p.keyMode == "optional" ? "Clé API (facultative)" : "Clé API",
            placeholder: placeholder,
            password: true,
            leadingIcon: "key",
        )
        if let link = p.keyUrl {
            Button {
                openInBrowser(link)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right").font(.caption)
                    Text("Obtenir une clé").font(.subheadline)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(cs.accent)
        }
    }

    private var buttonsRow: some View {
        FlowRow(spacing: 8) {
            Button {
                busy = true
                message = nil
                Task {
                    do {
                        var b = f.body()
                        b["enabled"] = f.enabled
                        b["auto_tag_new"] = f.autoTagNew
                        _ = try await api.postObject("api/ai/config", b)
                        ToastCenter.shared.show("IA : enregistré.")
                        onSaved()
                    } catch {
                        message = (aiErrorText(error), true)
                    }
                    busy = false
                }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("Enregistrer")
                }
            }
            .buttonStyle(AiPrimaryButtonStyle())
            .disabled(busy)

            Button {
                testing = true
                message = nil
                Task {
                    do {
                        let res = try await api.postObject("api/ai/test", f.body())
                        message = ((res.str("message") ?? "Connexion réussie."), false)
                    } catch {
                        message = (aiErrorText(error), true)
                    }
                    testing = false
                }
            } label: {
                HStack(spacing: 6) {
                    if testing { ProgressView().controlSize(.small) }
                    Text("Tester")
                }
            }
            .buttonStyle(AiOutlinedButtonStyle())
            .disabled(testing || busy)
        }
    }
}

// MARK: - Traitements

/// Création des tags (séries sans tags ou toutes) et normalisation, avec l'avancement du traitement.
private struct AiJobsCard: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    @ObservedObject var f: AiForm
    let stats: JSONDict?
    let job: JSONDict?
    let onStarted: () -> Void
    let onApplied: () -> Void

    @State private var error: String? = nil
    @State private var confirmAll = false

    private var running: Bool { job?.str("status") == "running" }
    private var llm: Bool { f.providers.first { $0.id == f.provider }?.llm != false }

    private var subtitle: String? {
        var parts: [String] = []
        if let t = stats?.int("total") { parts.append("\(t) séries") }
        if let u = stats?.int("untagged") { parts.append("\(u) sans tags") }
        let pending = stats?.int("auto_pending") ?? 0
        if pending > 0 { parts.append("\(pending) nouvelle(s) en attente") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        AiCard(title: "Tags", icon: "tag", subtitle: subtitle) {
            jobsContent
        }
        .overlay {
            if confirmAll {
                ConfirmDialog(
                    title: "Taguer toutes les séries ?",
                    text: "L'IA propose des tags pour les \(stats?.int("total").map(String.init) ?? "") séries, y compris celles qui en ont déjà. Elle ajoute des tags sans en retirer. Cela peut être long.",
                    confirm: "Lancer",
                    onConfirm: {
                        confirmAll = false
                        start("api/ai/tags/generate", ["scope": "all"])
                    },
                    onDismiss: { confirmAll = false },
                )
            }
        }
    }

    private func start(_ path: String, _ body: JSONDict) {
        error = nil
        Task {
            do {
                _ = try await api.postObject(path, body)
                onStarted()
            } catch {
                self.error = aiErrorText(error)
            }
        }
    }

    @ViewBuilder
    private var jobsContent: some View {
        if !f.enabled {
            Text("Activez l'IA et enregistrez pour lancer un traitement.")
                .font(.caption)
                .foregroundColor(cs.muted)
        }
        FlowRow(spacing: 8) {
            Button {
                start("api/ai/tags/generate", ["scope": "untagged"])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption)
                    Text("Séries sans tags" + (stats?.int("untagged").map { " (\($0))" } ?? ""))
                }
            }
            .buttonStyle(AiPrimaryButtonStyle())
            .disabled(!f.enabled || running)

            Button("Toutes les séries") { confirmAll = true }
                .buttonStyle(AiOutlinedButtonStyle())
                .disabled(!f.enabled || running)

            Button {
                start("api/ai/tags/normalize", JSONDict())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.merge").font(.caption)
                    Text("Regrouper les doublons")
                }
            }
            .buttonStyle(AiOutlinedButtonStyle())
            .disabled(!f.enabled || running || !llm)
        }
        if !llm {
            Text("Le regroupement demande un modèle de langage : choisissez un autre fournisseur.")
                .font(.caption)
                .foregroundColor(cs.muted)
        }
        if let error {
            ErrorCard(message: error)
        }
        if let job, job.str("status") != "idle" {
            Divider().overlay(cs.outlineVariant)
            Text(jobKind(job)).font(.subheadline.weight(.semibold))
            let progress = job.int("progress") ?? 0
            let totalJob = job.int("total") ?? 0
            if running {
                if totalJob > 0 {
                    ProgressView(value: Double(progress) / Double(totalJob))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if let m = job.str("message") {
                Text(m).font(.subheadline).foregroundColor(job.str("status") == "error" ? cs.error : cs.text)
            }
            let groups = (job.str("kind") == "normalize" && job.str("status") == "done")
                ? (job.dict("result")?.objects("groups") ?? [])
                : []
            if !groups.isEmpty {
                NormalizeGroupsView(api: api, groups: groups, onApplied: onApplied)
            }
        }
    }

    private func jobKind(_ job: JSONDict) -> String {
        switch job.str("kind") {
        case "generate": return "Création des tags"
        case "normalize": return "Regroupement des tags"
        case "auto": return "Tags des nouvelles séries"
        default: return "Traitement"
        }
    }
}

/// Regroupements proposés par l'IA : chacun se coche, puis « Appliquer » fusionne les variantes.
private struct NormalizeGroupsView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let groups: [JSONDict]
    let onApplied: () -> Void

    @State private var checked: [Int: Bool] = [:]
    @State private var busy = false
    @State private var error: String? = nil

    private var isEnabled: Bool { groups.indices.contains { checked[$0] ?? true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        checked[i] = !(checked[i] ?? true)
                    } label: {
                        Image(systemName: (checked[i] ?? true) ? "checkmark.square.fill" : "square")
                            .foregroundColor(cs.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(groups[i].str("canonical") ?? "").fontWeight(.semibold)
                        Text("← " + groups[i].objects("variants").map { v in
                            (v.str("tag") ?? "") + (v.int("series").map { " (\($0))" } ?? "")
                        }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(cs.muted)
                        if let reason = groups[i].str("reason") {
                            Text(reason).font(.caption).foregroundColor(cs.muted)
                        }
                    }
                }
            }
            if let error {
                ErrorCard(message: error)
            }
            let n = groups.indices.filter { checked[$0] ?? true }.count
            Button {
                busy = true
                error = nil
                Task {
                    do {
                        var arr: [JSONDict] = []
                        for (i, g) in groups.enumerated() where checked[i] ?? true {
                            arr.append([
                                "canonical": g.str("canonical") ?? "",
                                "variants": g.objects("variants").compactMap { $0.str("tag") },
                            ])
                        }
                        _ = try await api.postObject("api/ai/tags/normalize/apply", ["groups": arr])
                        onApplied()
                    } catch {
                        self.error = aiErrorText(error)
                    }
                    busy = false
                }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text("Appliquer (\(n))") }
            }
            .buttonStyle(AiPrimaryButtonStyle())
            .disabled(n == 0 || busy)
        }
    }
}

// MARK: - Historique

private struct AiHistoryCard: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let entries: [JSONDict]?
    let onCleared: () -> Void
    var onOpenSeries: ((Int, String) -> Void)? = nil

    @State private var confirm = false
    @State private var all = false
    @State private var openIds: Set<String> = []

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    var body: some View {
        AiCard(title: "Historique", icon: "clock.arrow.circlepath", subtitle: entries.map { "\($0.count) traitement(s)" }) {
            historyContent
        }
        .overlay {
            if confirm {
                ConfirmDialog(
                    title: "Vider l'historique ?",
                    text: "Les tags déjà ajoutés restent en place.",
                    confirm: "Vider",
                    onConfirm: {
                        confirm = false
                        Task {
                            _ = try? await api.deleteObject("api/ai/history")
                            onCleared()
                        }
                    },
                    onDismiss: { confirm = false },
                )
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if entries == nil {
            ProgressView().progressViewStyle(.linear)
        } else if let entries, entries.isEmpty {
            Text("Aucun traitement.").font(.caption).foregroundColor(cs.muted)
        } else if let entries {
            let shown = all ? entries : Array(entries.prefix(10))
            ForEach(shown.indices, id: \.self) { i in
                let e = shown[i]
                let id = e.str("id") ?? "i\(i)"
                row(e, id)
            }
            HStack {
                if entries.count > 10 {
                    Button(all ? "Voir moins" : "Tout voir (\(entries.count))") { all.toggle() }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundColor(cs.accent)
                }
                Spacer()
                Button {
                    confirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eraser").font(.caption)
                        Text("Vider")
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundColor(cs.accent)
            }
        }
    }

    @ViewBuilder
    private func row(_ e: JSONDict, _ id: String) -> some View {
        let open = openIds.contains(id)
        let hasDetails = !e.objects("details").isEmpty
        let at = e.dbl("finished_at").map { Self.fmt.string(from: Date(timeIntervalSince1970: $0)) }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text([at, aiKindLabel(e)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasDetails {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(cs.muted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if hasDetails {
                    if open { openIds.remove(id) } else { openIds.insert(id) }
                }
            }
            Text([e.str("message").flatMap { $0.isBlank ? nil : $0 }, e.str("model")].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundColor(e.str("status") == "error" ? cs.error : cs.muted)
            if open {
                AiEntryDetails(e: e, onOpenSeries: onOpenSeries)
                    .padding(.leading, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
    }
}

/**
 * Détail d'un traitement IA : tags ajoutés (ou proposés) par série, ou regroupements de tags.
 * [onOpenSeries] rend le titre de chaque série cliquable.
 */
struct AiEntryDetails: View {
    @Environment(\.bullColors) private var cs
    let e: JSONDict
    var onOpenSeries: ((Int, String) -> Void)? = nil
    var limit: Int = .max

    var body: some View {
        let details = e.objects("details")
        let total = e.int("details_total") ?? details.count
        if details.isEmpty {
            Text("Pas de détail enregistré.").font(.caption).foregroundColor(cs.muted)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(details.prefix(limit).indices, id: \.self) { i in
                    detailRow(details[i])
                }
                let hidden = total - min(limit, details.count)
                if hidden > 0 {
                    Text("… et \(hidden) autre(s)").font(.caption).foregroundColor(cs.muted)
                }
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ d: JSONDict) -> some View {
        if let canonical = d.str("canonical") {
            VStack(alignment: .leading, spacing: 4) {
                Text("→ \(canonical)").font(.caption.weight(.semibold)).foregroundColor(cs.accent)
                let variants = d.strings("variants").filter { $0 != canonical }
                if !variants.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(variants, id: \.self) { v in
                            TagView(text: v, container: cs.secondaryContainer, content: cs.text)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                let id = d.int("series_id")
                let title = d.str("title") ?? "(série)"
                if let id, let cb = onOpenSeries {
                    Button { cb(id, title) } label: {
                        Text(title).font(.caption.weight(.semibold)).foregroundColor(cs.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title).font(.caption.weight(.semibold)).foregroundColor(cs.text)
                }
                let added = d.strings("added")
                if added.isEmpty {
                    Text("Aucun tag").font(.caption).foregroundColor(cs.muted)
                } else {
                    FlowRow(spacing: 6) {
                        ForEach(added, id: \.self) { t in
                            TopicTag(text: t)
                        }
                    }
                }
            }
        }
    }
}
