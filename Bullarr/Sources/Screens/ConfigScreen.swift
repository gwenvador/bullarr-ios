import SwiftUI
import UIKit

// MARK: - Réglages génériques (ConfigScreen, Notifications, Web)

/**
 * État d'édition d'un réglage : valeurs de départ, valeurs modifiées, enregistrement, test.
 * Portage direct de ConfigEditor (Android) au-dessus de ConfigSpec.swift.
 */
@MainActor
final class ConfigEditor: ObservableObject {
    let spec: Integration
    @Published var loaded: JSONDict? = nil
    @Published var loadError: String? = nil
    @Published var busy = false
    @Published var testing = false
    @Published var message: String? = nil
    @Published var messageIsError = false
    @Published var values: [String: Any] = [:]
    private var initial: [String: Any] = [:]

    init(_ spec: Integration) { self.spec = spec }

    var dirty: Bool {
        spec.fields.contains { f in
            let key = f.field.key
            if case .secret = f { return (values[key] as? String ?? "").isEmpty == false }
            return !anyEqual(values[key], initial[key])
        }
    }

    private func adopt(_ o: JSONDict) {
        loaded = o
        initial = Dictionary(uniqueKeysWithValues: spec.fields.map { ($0.field.key, initialValue($0, o)) })
        values = initial
    }

    func load(_ api: BullarrApi) async {
        loadError = nil
        do { adopt(try await api.getObject(spec.path)) }
        catch { loadError = readable(error) }
    }

    func reset() { values = initial; message = nil }

    /// Relit le serveur juste avant d'écrire : deux cartes sur le même réglage ne s'écrasent pas.
    func save(_ api: BullarrApi) async -> Bool {
        busy = true; message = nil
        defer { busy = false }
        do {
            let fresh = try await api.getObject(spec.path)
            try await api.postObject(spec.path, buildPayload(spec, fresh, initial, values))
            adopt(try await api.getObject(spec.path))
            message = "Enregistré."; messageIsError = false
            return true
        } catch {
            message = readable(error); messageIsError = true
            return false
        }
    }

    func test(_ api: BullarrApi) async {
        guard let t = spec.test else { return }
        testing = true; message = nil
        defer { testing = false }
        do {
            let o: JSONDict
            if t.post {
                o = try await api.postObject(t.path, t.sendConfig ? (try await api.getObject(spec.path)) : [:])
            } else {
                o = try await api.getObject(t.path)
            }
            message = o.str("message")?.replacingOccurrences(of: "^[^\\p{L}\\p{N}]+", with: "", options: [.regularExpression])
                ?? o.str("topics").map { "Forum joignable : \($0) sujets." }
                ?? "Connexion réussie."
            messageIsError = false
        } catch {
            message = readable(error); messageIsError = true
        }
    }
}

/// Onglet de Réglages : une carte par réglage, dépliée à la demande (seule si unique).
struct ConfigScreen: View {
    @EnvironmentObject private var state: AppState
    let integrations: [Integration]
    var header: (() -> AnyView)? = nil
    var footer: (() -> AnyView)? = nil

    var body: some View {
        if let api = state.api {
            ConfigView(api: api, integrations: integrations, header: header, footer: footer)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct ConfigView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let integrations: [Integration]
    var header: (() -> AnyView)? = nil
    var footer: (() -> AnyView)? = nil
    @State private var editors: [ConfigEditor] = []
    @State private var open: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                header?()
                ForEach(editors, id: \.spec.id) { e in
                    ConfigCard(api: api, editor: e, expanded: open == e.spec.id,
                               onToggle: { open = open == e.spec.id ? nil : e.spec.id })
                }
                footer?()
            }
            .padding(12)
        }
        .task(id: integrations.map { $0.id }) {
            editors = integrations.map { ConfigEditor($0) }
            open = integrations.count == 1 ? integrations.first?.id : nil
            for e in editors where e.loaded == nil {
                await e.load(api)
            }
        }
    }
}

// --- Carte d'un réglage ---------------------------------------------------------

/// Icône d'un réglage sans logo de marque.
private func configIcon(_ id: String) -> String {
    switch id {
    case "rename": return "pencil"
    case "import": return "tray.and.arrow.down"
    case "order": return "list.number"
    case "blocked": return "nosign"
    case "series": return "folder.badge.plus"
    case "auto": return "arrow.triangle.2.circlepath"
    case "monitor": return "scope"
    case "login": return "lock"
    default: return "tag"
    }
}

/// Icône en tête d'un champ texte, d'après sa clé (nil quand aucune ne s'impose).
private func fieldIcon(_ box: FieldBox) -> String? {
    let f = box.field
    let k = f.key.split(separator: ".").last.map(String.init) ?? f.key
    if case .secret = box { return k.contains("key") || k.contains("token") || k.contains("secret") ? "key" : "lock" }
    switch k {
    case "url", "base_url", "issuer": return "link"
    case "host": return "network"
    case "port": return "number"
    case "username": return "person"
    case "scopes": return "list.bullet"
    default: break
    }
    if k.hasSuffix("category") { return "tag" }
    if k.hasSuffix("template") { return "doc.plaintext" }
    if k == "chat_id" { return "tag" }
    if k.contains("interval") { return "clock" }
    if k.contains("percent") { return "percent" }
    if k.contains("extensions") { return "doc.plaintext" }
    return nil
}

/// Pastille en tête de carte : logo de la marque, sinon une icône.
private struct ConfigBadge: View {
    @Environment(\.bullColors) private var cs
    let spec: Integration

    var body: some View {
        let logo = logoKey(spec.title) ?? logoKey(spec.id)
        RoundedRectangle(cornerRadius: 10).fill(cs.alt)
            .frame(width: 40, height: 40)
            .overlay {
                if hasLogo(logo) {
                    Logo(key: logo, label: spec.title, size: 26, tip: false)
                } else {
                    Image(systemName: configIcon(spec.id))
                        .font(.system(size: 18))
                        .foregroundColor(cs.accent)
                }
            }
    }
}

struct ConfigCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    @ObservedObject var editor: ConfigEditor
    let expanded: Bool
    let onToggle: () -> Void
    var onSaved: (() -> Void)? = nil

    var body: some View {
        let o = editor.loaded
        let hasEnabled = editor.spec.fields.contains { $0.field.key == "enabled" }
        let enabled = (o?.getPath("enabled") as? Bool)
        let status: String = {
            if editor.loadError != nil { return "Erreur de chargement" }
            guard let o else { return "Chargement…" }
            var parts: [String] = []
            if hasEnabled { parts.append(enabled == true ? "Activé" : "Désactivé") }
            if let info = editor.spec.info?(o) { parts.append(info) }
            return parts.joined(separator: " · ")
        }()
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    ConfigBadge(spec: editor.spec)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editor.spec.title).font(.headline).foregroundColor(cs.text)
                        if !status.isEmpty {
                            Text(status).font(.caption)
                                .foregroundColor(editor.loadError != nil ? cs.error : cs.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if o != nil && hasEnabled {
                        IconTag(icon: "power", label: enabled == true ? "Activé" : "Désactivé",
                                tint: enabled == true ? cs.tertiary : cs.muted, size: 20)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(cs.muted)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Replier" : "Déplier")

            if expanded {
                if let e = editor.loadError {
                    ErrorCard(message: e, onRetry: { Task { await editor.load(api) } })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                if let o {
                    VStack(alignment: .leading, spacing: 12) {
                        if let help = editor.spec.help {
                            Text(help).font(.caption).foregroundColor(cs.muted)
                        }
                        ForEach(editor.spec.fields.indices, id: \.self) { i in
                            let box = editor.spec.fields[i]
                            if shouldShow(box) {
                                FieldEditor(box: box, editor: editor, o: o)
                            }
                        }
                        if let m = editor.message {
                            if editor.messageIsError {
                                ErrorCard(message: m)
                            } else {
                                Text(m).font(.subheadline).foregroundColor(cs.accent)
                            }
                        }
                        FlowRow(spacing: 8) {
                            Button {
                                Task {
                                    if await editor.save(api) { onSaved?() }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if editor.busy {
                                        ProgressView().controlSize(.small).tint(cs.onAccent)
                                    }
                                    Text("Enregistrer")
                                }
                            }
                            .buttonStyle(AccentPillButtonStyle())
                            .disabled(!editor.dirty || editor.busy)
                            if editor.dirty {
                                Button("Annuler") { editor.reset() }
                                    .buttonStyle(OutlinedPillButtonStyle())
                                    .disabled(editor.busy)
                            }
                            if let t = editor.spec.test {
                                Button {
                                    Task { await editor.test(api) }
                                } label: {
                                    HStack(spacing: 6) {
                                        if editor.testing {
                                            ProgressView().controlSize(.small).tint(cs.accent)
                                        }
                                        Text(t.label)
                                    }
                                }
                                .buttonStyle(OutlinedPillButtonStyle())
                                .disabled(editor.testing || editor.busy)
                            }
                        }
                        if let t = editor.spec.test {
                            Text(t.note ?? "Le test utilise les réglages enregistrés." + (editor.dirty ? " Enregistrez d'abord vos modifications." : ""))
                                .font(.caption).foregroundColor(cs.muted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(cs.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(cs.outlineVariant, lineWidth: 1))
    }

    /// Champ conditionnel : visible seulement si la valeur de son précurseur est dans la liste.
    private func shouldShow(_ box: FieldBox) -> Bool {
        guard let (dep, options) = box.field.showWhen else { return true }
        guard let v = editor.values[dep] as? String else { return false }
        return options.contains(v)
    }
}

// --- Éditeurs de champs ---------------------------------------------------------

private struct FieldEditor: View {
    @Environment(\.bullColors) private var cs
    let box: FieldBox
    @ObservedObject var editor: ConfigEditor
    let o: JSONDict

    var body: some View {
        switch box {
        case .switchField(let f):
            Toggle(isOn: boolBinding(f.key)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label).font(.subheadline)
                    if let help = f.help {
                        Text(help).font(.caption).foregroundColor(cs.muted)
                    }
                }
            }
            .tint(cs.accent)
        case .text(let f):
            FormField(value: textBinding(f.key), label: f.label, placeholder: f.hint,
                      leadingIcon: fieldIcon(box),
                      keyboardType: f.url ? .URL : nil)
        case .number(let f):
            FormField(value: textBinding(f.key).digitsOnly(), label: f.label,
                      leadingIcon: fieldIcon(box), keyboardType: .numberPad)
        case .list(let f):
            FormField(value: textBinding(f.key), label: f.label, placeholder: f.hint,
                      leadingIcon: fieldIcon(box), supportingText: "Séparées par des virgules.")
        case .secret(let f):
            FormField(value: textBinding(f.key), label: f.label,
                      placeholder: secretIsSet(f, o) ? "Enregistré — laisser vide pour le garder" : nil,
                      password: true, leadingIcon: fieldIcon(box))
        case .choice(let f):
            VStack(alignment: .leading, spacing: 6) {
                Text(f.label).font(.subheadline)
                FlowRow(spacing: 8) {
                    ForEach(f.options, id: \.0) { k, l in
                        FilterChip(selected: (editor.values[f.key] as? String) == k,
                                   onClick: { editor.values[f.key] = k },
                                   label: { Text(l) })
                    }
                }
            }
        case .multi(let f):
            VStack(alignment: .leading, spacing: 6) {
                Text(f.label).font(.subheadline)
                FlowRow(spacing: 8) {
                    ForEach(f.options, id: \.0) { k, l in
                        let sel = editor.values[f.key] as? [String] ?? []
                        FilterChip(selected: sel.contains(k),
                                   onClick: { editor.values[f.key] = sel.contains(k) ? sel.filter { $0 != k } : sel + [k] },
                                   label: { Text(l) })
                    }
                }
            }
        case .order(let f):
            VStack(alignment: .leading, spacing: 6) {
                Text(f.label).font(.subheadline)
                if let help = f.help {
                    Text(help).font(.caption).foregroundColor(cs.muted)
                }
                let list = editor.values[f.key] as? [String] ?? []
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element) { i, name in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.subheadline.weight(.semibold)).foregroundColor(cs.accent)
                                .frame(width: 22)
                            Text(f.names[name] ?? name).font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                var l = list; let v = l.remove(at: i); l.insert(v, at: i - 1); editor.values[f.key] = l
                            } label: {
                                Image(systemName: "arrow.up").frame(width: 32, height: 32)
                            }
                            .disabled(i == 0)
                            .opacity(i == 0 ? 0.35 : 1)
                            .accessibilityLabel("Monter")
                            Button {
                                var l = list; let v = l.remove(at: i); l.insert(v, at: i + 1); editor.values[f.key] = l
                            } label: {
                                Image(systemName: "arrow.down").frame(width: 32, height: 32)
                            }
                            .disabled(i >= list.count - 1)
                            .opacity(i >= list.count - 1 ? 0.35 : 1)
                            .accessibilityLabel("Descendre")
                        }
                        .padding(.vertical, 6)
                        if i < list.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { editor.values[key] as? Bool ?? false },
                set: { editor.values[key] = $0 })
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { editor.values[key] as? String ?? "" },
                set: { editor.values[key] = $0 })
    }
}

private extension Binding where Value == String {
    /// Ne garde que les chiffres (champ numérique).
    func digitsOnly() -> Binding<String> {
        Binding(get: { wrappedValue },
                set: { wrappedValue = String($0.filter { $0.isNumber }) })
    }
}

// MARK: - Réglages → Web

/// Réglages qui n'ont pas (encore) d'éditeur dans l'app : ils s'ouvrent dans l'interface web.
private let WEB_SETTINGS: [(String, String)] = [
    ("indexeurs", "EBDZ : choix des forums à indexer"),
    ("indexeurs", "Canaux Telegram : compte, canaux, indexation"),
    ("oidc", "Clé API de Bullarr (affichage et régénération)"),
    ("backup", "Sauvegarde et restauration (contient les secrets)"),
]

struct WebSettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Ces réglages se modifient dans l'interface web de Bullarr : connexion Telegram par code, fichiers de sauvegarde et clé API ne se prêtent pas au téléphone.")
                    .font(.subheadline).foregroundColor(cs.muted)
                    .padding(16)
                ForEach(Array(WEB_SETTINGS.enumerated()), id: \.offset) { i, pair in
                    let (anchor, label) = pair
                    Button {
                        if let api = state.api { openInBrowser(api.absoluteUrl("settings") + "#\(anchor)") }
                    } label: {
                        HStack(spacing: 16) {
                            webSettingIcon(label)
                            Text(label).font(.subheadline).foregroundColor(cs.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(cs.muted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < WEB_SETTINGS.count - 1 { Divider() }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func webSettingIcon(_ label: String) -> some View {
        let logo = logoKey(String(label.prefix(while: { $0 != " " })))
        return RoundedRectangle(cornerRadius: 8).fill(cs.alt)
            .frame(width: 36, height: 36)
            .overlay {
                if hasLogo(logo) {
                    Logo(key: logo, label: label, size: 22, tip: false)
                } else {
                    Image(systemName: label.contains("Clé") ? "key" : "arrow.clockwise.icloud")
                        .font(.system(size: 16))
                        .foregroundColor(cs.accent)
                }
            }
    }
}

// MARK: - Réglages → Notifications

private struct NotifEvent: Identifiable {
    let id: String
    let label: String
    let description: String
}

private struct NotifChannel {
    var enabled: Bool
    var configured: Bool
    var events: [String: Bool]
}

private let NOTIF_COL_W: CGFloat = 76

/**
 * Réglages → Notifications, comme la page web : le tableau « Événements » (une case Telegram et
 * une case ntfy par type d'événement, enregistrées aussitôt), puis les cartes des deux canaux.
 * Les notifications sont envoyées par le serveur ; l'app ne fait que les régler.
 */
struct NotificationsScreen: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let api = state.api {
            NotificationsView(api: api)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct NotificationsView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    @StateObject private var telegram = ConfigEditor(NOTIFICATIONS[0])
    @StateObject private var ntfy = ConfigEditor(NTFY_CHANNEL)
    @State private var open: String? = nil
    /// Recharge le tableau quand une carte a enregistré (canal activé, topic…).
    @State private var reloadKey = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                EventsTable(reloadKey: reloadKey)
                Text("Canaux")
                    .font(.subheadline.weight(.semibold)).foregroundColor(cs.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 8)
                ConfigCard(api: api, editor: telegram, expanded: open == "telegram",
                           onToggle: { open = open == "telegram" ? nil : "telegram" },
                           onSaved: { reloadKey += 1 })
                ConfigCard(api: api, editor: ntfy, expanded: open == "ntfy",
                           onToggle: { open = open == "ntfy" ? nil : "ntfy" },
                           onSaved: { reloadKey += 1 })
            }
            .padding(12)
        }
        .task {
            if telegram.loaded == nil { await telegram.load(api) }
            if ntfy.loaded == nil { await ntfy.load(api) }
        }
    }
}

/// Tableau « Événements » : une ligne par type, une case par canal.
private struct EventsTable: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let reloadKey: Int

    @State private var events: [NotifEvent]? = nil
    @State private var channels: [String: NotifChannel] = [:]
    @State private var error: String? = nil
    @State private var busy: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Événements").font(.headline).padding(.horizontal, 16).padding(.top, 12)
            Text("Choisissez ce que chaque canal reçoit. Un canal se configure et s'active dans sa carte, plus bas.")
                .font(.caption).foregroundColor(cs.muted)
                .padding(.horizontal, 16).padding(.top, 2)

            if let e = error, events == nil {
                Text(e).font(.caption).foregroundColor(cs.error).padding(16)
            } else if events == nil {
                ProgressView().padding(16)
            } else {
                HStack(alignment: .center, spacing: 0) {
                    Text("Événement").font(.footnote.weight(.semibold)).foregroundColor(cs.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    channelHead("telegram", "Telegram")
                    channelHead("ntfy", "ntfy")
                }
                .padding(.leading, 16).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 6)
                Rectangle().fill(cs.outlineVariant).frame(height: 1)
                ForEach(Array((events ?? []).enumerated()), id: \.element.id) { i, ev in
                    eventRow(ev)
                        .background(i % 2 == 1 ? cs.alt.opacity(0.35) : Color.clear)
                }
                Rectangle().fill(cs.outlineVariant).frame(height: 1)
                if let e = error {
                    Text(e).font(.caption).foregroundColor(cs.error)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(cs.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(cs.outlineVariant, lineWidth: 1))
        .task(id: reloadKey) { await load() }
    }

    private func load() async {
        guard let api = state.api else { return }
        do {
            let o = try await api.getObject("api/notifications/events")
            events = o.objects("events").map { ev in
                NotifEvent(id: ev.str("id") ?? "", label: ev.str("label") ?? "", description: ev.str("description") ?? "")
            }
            let ch = o.dict("channels") ?? [:]
            for name in ["telegram", "ntfy"] {
                guard let c = ch[name] as? JSONDict else { continue }
                let ev = c.dict("events") ?? [:]
                channels[name] = NotifChannel(
                    enabled: c.bool("enabled") ?? false,
                    configured: c.bool("configured") ?? false,
                    events: Dictionary(uniqueKeysWithValues: ev.keys.map { ($0, ev.bool($0) ?? false) })
                )
            }
            error = nil
        } catch {
            let msg = readable(error)
            self.error = msg.contains("404") ? "Ce serveur Bullarr n'a pas encore le tableau des notifications : mettez-le à jour." : msg
        }
    }

    private func toggle(_ channel: String, _ kind: String, _ value: Bool) {
        guard let api = state.api, let before = channels[channel] else { return }
        var evts = before.events; evts[kind] = value
        channels[channel] = NotifChannel(enabled: before.enabled, configured: before.configured, events: evts)
        busy = "\(channel)/\(kind)"
        Task {
            defer { busy = nil }
            do {
                try await api.postObject("api/notifications/events", [channel: [kind: value]])
            } catch {
                channels[channel] = before
                self.error = readable(error)
            }
        }
    }

    private func channelHead(_ name: String, _ label: String) -> some View {
        let c = channels[name]
        return VStack(spacing: 2) {
            Logo(key: name, label: label, size: 20, tip: false)
            Text(label).font(.caption2.weight(.semibold)).foregroundColor(cs.text)
            Text(c == nil ? "" : (c!.enabled ? "activé" : (c!.configured ? "désactivé" : "à configurer")))
                .font(.caption2)
                .foregroundColor(c?.enabled == true ? cs.accent : cs.muted)
        }
        .frame(width: NOTIF_COL_W)
        .opacity(c?.enabled == true ? 1 : 0.55)
    }

    private func eventRow(_ ev: NotifEvent) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.label).font(.subheadline.weight(.medium)).foregroundColor(cs.text)
                if !ev.description.isEmpty {
                    Text(ev.description).font(.caption).foregroundColor(cs.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["telegram", "ntfy"], id: \.self) { name in
                let c = channels[name]
                Group {
                    if busy == "\(name)/\(ev.id)" {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { toggle(name, ev.id, !(c?.events[ev.id] ?? false)) } label: {
                            Image(systemName: (c?.events[ev.id] ?? false) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 19))
                                .foregroundColor((c?.events[ev.id] ?? false) ? cs.accent : cs.muted)
                        }
                    }
                }
                .frame(width: NOTIF_COL_W)
                .opacity(c?.enabled == true ? 1 : 0.55)
                .disabled(c == nil)
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
    }
}
