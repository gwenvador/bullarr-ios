import SwiftUI
import PhotosUI

// Réglages → Utilisateurs (UsersScreen.kt, administrateurs) : comptes locaux et SSO, rôle,
// accès aux bibliothèques, contrôle parental, avatar ; création, modification et suppression.

func userTitle(_ u: JSONDict) -> String { u.str("name") ?? u.str("username") ?? u.str("key") ?? "?" }
func userIsLocal(_ u: JSONDict) -> Bool { u.str("type") == "local" }
func userIsPending(_ u: JSONDict) -> Bool { u.str("status") == "pending" }
func userIsAdmin(_ u: JSONDict) -> Bool { u.str("role") == "admin" }

/// Bibliothèques permises : nil = toutes (non restreint).
func userAllowedLibraries(_ u: JSONDict) -> [Int]? {
    if u["allowed_libraries"] is NSNull { return nil }
    return (u.array("allowed_libraries") ?? []).compactMap { $0 as? Int }
}

func userBlockedGenres(_ u: JSONDict) -> [String] {
    u.strings("blocked_genres").filter { !$0.isBlank }
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)" + (n > 1 ? "s" : "") }

private func accessSummary(_ u: JSONDict) -> String {
    let libs = userAllowedLibraries(u)
    var parts = [libs == nil ? "Toutes les bibliothèques" : plural(libs!.count, "bibliothèque")]
    let genres = userBlockedGenres(u).count
    if genres > 0 { parts.append(plural(genres, "genre") + " masqué" + (genres > 1 ? "s" : "")) }
    return parts.joined(separator: " · ")
}

struct UsersScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    @State private var users: [JSONDict]? = nil
    @State private var error: String? = nil
    @State private var tick = 0
    @State private var expanded: String? = nil
    @State private var editing: JSONDict? = nil
    @State private var creating = false
    @State private var accessFor: JSONDict? = nil
    @State private var avatarFor: JSONDict? = nil
    @State private var deleting: JSONDict? = nil

    var body: some View {
        Group {
            if state.api == nil {
                EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
            } else {
                content
            }
        }
        .background(cs.bg)
        .task(id: tick) { await reload() }
        .overlay {
            if creating || editing != nil {
                UserEditDialog(user: editing, onDismiss: { creating = false; editing = nil }, onSaved: { creating = false; editing = nil; tick += 1 })
            }
        }
        .overlay {
            if let u = accessFor {
                AccessDialog(user: u, onDismiss: { accessFor = nil }, onSaved: { accessFor = nil; tick += 1 })
            }
        }
        .overlay {
            if let u = avatarFor {
                UserAvatarDialog(user: u, onDismiss: { avatarFor = nil }, onChanged: { avatarFor = nil; tick += 1 })
            }
        }
        .overlay {
            if let u = deleting {
                deleteDialog(u)
            }
        }
    }

    private func reload() async {
        guard let api = state.api else { return }
        do {
            let o = try await api.getObject("api/auth/users")
            users = o.objects("users")
            error = nil
        } catch {
            self.error = readable(error)
        }
        if state.libraries.isEmpty { await state.loadLibrary() }
    }

    private func deleteDialog(_ u: JSONDict) -> some View {
        ConfirmDialog(
            title: userIsPending(u) ? "Refuser la demande ?" : "Supprimer ce compte ?",
            text: userIsPending(u)
                ? "La demande d'inscription de \(userTitle(u)) sera refusée."
                : "Le compte \(userTitle(u)) sera supprimé et ses sessions ouvertes coupées."
                    + (userIsLocal(u) ? "" : " Il sera recréé (avec le rôle par défaut) s'il se reconnecte par SSO."),
            confirm: userIsPending(u) ? "Refuser" : "Supprimer",
            onConfirm: {
                guard let key = u.str("key") else { return }
                deleting = nil
                launchAction(userIsPending(u) ? "Demande refusée" : "Compte supprimé", then: { tick += 1 }) {
                    _ = try await state.api!.deleteObject("api/auth/users", ["key": key])
                }
            },
            onDismiss: { deleting = nil },
        )
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Utilisateurs").font(.headline)
                        if let list = users {
                            let pending = list.filter { userIsPending($0) }.count
                            Text([
                                plural(list.filter { userIsAdmin($0) && !userIsPending($0) }.count, "admin"),
                                plural(list.filter { !userIsAdmin($0) && !userIsPending($0) }.count, "lecteur"),
                                pending > 0 ? "\(pending) en attente" : nil,
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundColor(cs.muted)
                        }
                    }
                    Spacer()
                    Button {
                        creating = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.plus").font(.caption)
                            Text("Nouveau")
                        }
                    }
                    .buttonStyle(AccentPillButtonStyle())
                }
                if let error {
                    ErrorCard(message: error, onRetry: { tick += 1 })
                }
                if users == nil && error == nil {
                    ProgressView().progressViewStyle(.linear)
                }
                if let list = users {
                    ForEach(list.indices, id: \.self) { i in
                        if let key = list[i].str("key") {
                            let u = list[i]
                            UserCard(
                                u: u, open: expanded == key,
                                onToggle: { expanded = expanded == key ? nil : key },
                                onEdit: { editing = u },
                                onAccess: { accessFor = u },
                                onAvatar: { avatarFor = u },
                                onDelete: { deleting = u },
                                onApprove: { role in
                                    launchAction("Compte validé", then: { tick += 1 }) {
                                        _ = try await state.api!.postObject("api/auth/users/approve", ["key": key, "role": role])
                                    }
                                },
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
        .refreshable { tick += 1 }
    }
}

// MARK: - Carte utilisateur

private struct UserCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let u: JSONDict
    let open: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onAccess: () -> Void
    let onAvatar: () -> Void
    let onDelete: () -> Void
    let onApprove: (String) -> Void

    var body: some View {
        let me = u.bool("is_me") == true
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Avatar(api: state.api, url: u.str("avatar_url"), size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(userTitle(u)).fontWeight(.medium).lineLimit(1)
                        if me {
                            SmallTag(text: "vous", container: cs.alt, content: cs.muted)
                        }
                    }
                    FlowRow(spacing: 6) {
                        if userIsPending(u) {
                            SmallTag(text: "En attente", container: cs.errorContainer, content: cs.onErrorContainer)
                        } else if userIsAdmin(u) {
                            SmallTag(text: "Admin", container: cs.accentContainer, content: cs.accentOnContainer)
                        } else {
                            SmallTag(text: "Lecteur", container: cs.secondaryContainer, content: cs.text)
                        }
                        SmallTag(text: userIsLocal(u) ? "Local" : "SSO", container: cs.alt, content: cs.muted)
                        if !userIsLocal(u) && !userIsPending(u) && (u["role_override"] == nil || u["role_override"] is NSNull) {
                            SmallTag(text: "rôle auto", container: cs.alt, content: cs.muted)
                        }
                    }
                    let detail = [userIsLocal(u) ? u.str("username").map { "@\($0)" } : nil, u.str("email")].compactMap { $0 }.joined(separator: " · ")
                    if !detail.isBlank {
                        Text(detail).font(.caption).foregroundColor(cs.muted).lineLimit(1)
                    }
                    if !userIsAdmin(u) && !userIsPending(u) {
                        Text(accessSummary(u)).font(.caption).foregroundColor(cs.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            if open {
                Divider()
                expandedContent(me)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    @ViewBuilder
    private func expandedContent(_ me: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let first = utcToLocal(u.str("first_seen"))
            let seen = utcToLocal(u.str("last_seen"))
            Text([first.map { "Créé le \($0)" }, seen.map { "vu le \($0)" }].compactMap { $0 }.joined(separator: " · ").ifBlank("Jamais connecté"))
                .font(.caption)
                .foregroundColor(cs.muted)
            if !userIsLocal(u) {
                let groups = u.strings("groups")
                if !groups.isEmpty {
                    Text("Groupes : " + groups.joined(separator: ", ")).font(.caption).foregroundColor(cs.muted)
                }
            }
            FlowRow(spacing: 8) {
                if userIsPending(u) {
                    Button { onApprove("reader") } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").font(.caption)
                            Text("Valider (lecteur)")
                        }
                    }
                    .buttonStyle(AccentPillButtonStyle())
                    Button("Valider (admin)") { onApprove("admin") }
                        .buttonStyle(OutlinedPillButtonStyle())
                    Button {
                        onDelete()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark").font(.caption)
                            Text("Refuser")
                        }
                    }
                    .buttonStyle(OutlinedPillButtonStyle())
                    .foregroundColor(cs.error)
                } else {
                    Button { onEdit() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil").font(.caption)
                            Text("Modifier")
                        }
                    }
                    .buttonStyle(OutlinedPillButtonStyle())
                    Button { onAccess() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock").font(.caption)
                            Text("Accès")
                        }
                    }
                    .buttonStyle(OutlinedPillButtonStyle())
                    Button { onAvatar() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "face.smiling").font(.caption)
                            Text("Avatar")
                        }
                    }
                    .buttonStyle(OutlinedPillButtonStyle())
                    if !me {
                        Button {
                            onDelete()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash").font(.caption)
                                Text("Supprimer")
                            }
                        }
                        .buttonStyle(OutlinedPillButtonStyle())
                        .foregroundColor(cs.error)
                    }
                }
            }
        }
    }
}

// MARK: - Rôle

/// Choix du rôle : « auto » (rôle calculé par les groupes SSO) n'existe que pour un compte SSO.
private struct RolePicker: View {
    @Environment(\.bullColors) private var cs
    let role: String?
    let sso: Bool
    let onChange: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rôle").font(.caption.weight(.semibold))
            FlowRow(spacing: 8) {
                if sso {
                    FilterChip(selected: role == nil) { onChange(nil) } label: { Text("Automatique") }
                }
                FilterChip(selected: role == "admin") { onChange("admin") } label: { Text("Administrateur") }
                FilterChip(selected: role == "reader") { onChange("reader") } label: { Text("Lecteur") }
            }
            Text(
                role == "admin" ? "Accès complet : réglages, ajouts, téléchargements."
                    : role == "reader" ? "Lit et demande des BD ; ne voit que les bibliothèques permises."
                    : "Rôle donné par le groupe administrateur du SSO.",
            )
            .font(.caption)
            .foregroundColor(cs.muted)
        }
    }
}

// MARK: - Création / modification

/** Création (user = nil) ou modification d'un compte. Un compte SSO ne change que de rôle. */
private struct UserEditDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let user: JSONDict?
    let onDismiss: () -> Void
    let onSaved: () -> Void

    @State private var username = ""
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var role: String? = nil
    @State private var busy = false

    private var creating: Bool { user == nil }
    private var local: Bool { user.map { userIsLocal($0) } ?? true }

    private var valid: Bool {
        if busy { return false }
        if creating { return !username.isBlank && password.count >= 8 }
        return !local || !name.isBlank
    }

    var body: some View {
        BullDialog(
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(creating ? "Nouveau compte local" : userTitle(user ?? JSONDict())).font(.headline)
                        if creating {
                            FormField(value: $username, label: "Identifiant")
                        }
                        if local {
                            FormField(value: $name, label: "Nom", placeholder: creating ? "facultatif" : nil)
                            FormField(value: $email, label: "E-mail", placeholder: "facultatif", keyboardType: .emailAddress)
                            FormField(
                                value: $password,
                                label: creating ? "Mot de passe" : "Nouveau mot de passe",
                                placeholder: creating ? "8 caractères minimum" : "laisser vide pour le garder",
                                password: true,
                            )
                            if !password.isEmpty && password.count < 8 {
                                Text("8 caractères minimum.").font(.caption).foregroundColor(cs.error)
                            }
                        } else {
                            Text("Nom, e-mail et mot de passe se gèrent chez le fournisseur SSO.")
                                .font(.caption)
                                .foregroundColor(cs.muted)
                        }
                        if user?.bool("is_me") != true {
                            RolePicker(role: role, sso: !local) { role = $0 }
                        }
                        if busy {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                }
                .frame(maxHeight: 420)
            },
            buttons: {
                Button {
                    busy = true
                    launchAction(creating ? "Compte créé" : "Compte modifié", then: { busy = false; onSaved() }) {
                        if creating {
                            _ = try await state.api!.postObject("api/auth/users", [
                                "username": username.trimmed,
                                "password": password,
                                "name": name.trimmed,
                                "email": email.trimmed,
                                "role": role ?? "reader",
                            ])
                        } else {
                            var body: JSONDict = ["key": user?.str("key") ?? ""]
                            if user?.bool("is_me") != true { body["role"] = role ?? NSNull() }
                            if local {
                                body["name"] = name.trimmed
                                body["email"] = email.trimmed
                                if !password.isEmpty { body["password"] = password }
                            }
                            _ = try await state.api!.putObject("api/auth/users", body)
                        }
                    }
                } label: {
                    Text(creating ? "Créer" : "Enregistrer").fontWeight(.semibold)
                }
                .disabled(!valid || (!password.isEmpty && password.count < 8))
                Button("Annuler", role: .cancel) { onDismiss() }
                    .disabled(busy)
            },
        )
        .onAppear {
            if let user {
                name = user.str("name") ?? ""
                email = user.str("email") ?? ""
                role = userIsLocal(user) ? user.str("role") : user.str("role_override").flatMap { $0 == "admin" || $0 == "reader" ? $0 : nil }
            } else {
                role = "reader"
            }
        }
    }
}

// MARK: - Accès

/** Bibliothèques permises et genres Bédéthèque masqués (contrôle parental). */
private struct AccessDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let user: JSONDict
    let onDismiss: () -> Void
    let onSaved: () -> Void

    @State private var allowed: [Int] = []
    @State private var blocked: [String] = []
    @State private var genres: [(String, Int)] = []
    @State private var preset: [String] = []
    @State private var busy = false

    private var libraries: [Library] { state.libraries }

    private func isBlocked(_ n: String) -> Bool { blocked.contains { $0.lowercased() == n.lowercased() } }

    /// Genres proposés : serveur + préréglage + genres déjà masqués ; les masqués en premier.
    private var names: [String] {
        let blockedList = userBlockedGenres(user)
        var seen = Set<String>()
        var out: [String] = []
        for n in genres.map({ $0.0 }) + preset + blockedList {
            if seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return out.sorted { a, b in
            let ab = blockedList.contains { $0.lowercased() == a.lowercased() }
            let bb = blockedList.contains { $0.lowercased() == b.lowercased() }
            if ab != bb { return ab }
            return a.lowercased() < b.lowercased()
        }
    }

    private var counts: [String: Int] {
        var out: [String: Int] = [:]
        for (n, c) in genres { out[n.lowercased()] = c }
        return out
    }

    var body: some View {
        BullDialog(
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accès de \(userTitle(user))").font(.headline)
                        if userIsAdmin(user) {
                            Text("Ce compte est administrateur : ces limites ne s'appliquent qu'aux lecteurs.")
                                .font(.caption)
                                .foregroundColor(cs.error)
                        }
                        Text("Bibliothèques").font(.caption.weight(.semibold))
                        ForEach(libraries, id: \.id) { lib in
                            Button {
                                if let idx = allowed.firstIndex(of: lib.id) { allowed.remove(at: idx) } else { allowed.append(lib.id) }
                            } label: {
                                HStack {
                                    Image(systemName: allowed.contains(lib.id) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(cs.accent)
                                    Text(lib.name)
                                        .font(.subheadline)
                                        .foregroundColor(cs.text)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if allowed.isEmpty {
                            Text("Aucune bibliothèque : ce lecteur ne verra rien.")
                                .font(.caption)
                                .foregroundColor(cs.error)
                        }
                        Divider().overlay(cs.outlineVariant).padding(.vertical, 4)
                        Text("Contrôle parental : genres masqués").font(.caption.weight(.semibold))
                        Text("Les séries de ces genres (Bédéthèque) n'apparaissent pas pour ce lecteur.")
                            .font(.caption)
                            .foregroundColor(cs.muted)
                        HStack(spacing: 8) {
                            Button("Préréglage enfant") {
                                for p in preset where !isBlocked(p) { blocked.append(p) }
                            }
                            .buttonStyle(OutlinedPillButtonStyle())
                            .disabled(preset.isEmpty)
                            Button("Aucun") { blocked.removeAll() }
                                .buttonStyle(.plain)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(cs.accent)
                                .disabled(blocked.isEmpty)
                        }
                        if names.isEmpty {
                            ProgressView().progressViewStyle(.linear)
                        }
                        FlowRow(spacing: 6) {
                            ForEach(names, id: \.self) { n in
                                let c = counts[n.lowercased()]
                                FilterChip(selected: isBlocked(n)) {
                                    if isBlocked(n) {
                                        blocked.removeAll { $0.lowercased() == n.lowercased() }
                                    } else {
                                        blocked.append(n)
                                    }
                                } label: {
                                    Text(c.map { "\(n) · \($0)" } ?? n)
                                }
                            }
                        }
                        if busy {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                }
                .frame(maxHeight: 460)
            },
            buttons: {
                Button {
                    busy = true
                    launchAction("Accès enregistrés", then: { busy = false; onSaved() }) {
                        let all = libraries.allSatisfy { allowed.contains($0.id) }
                        var body: JSONDict = ["key": user.str("key") ?? "", "blocked_genres": blocked]
                        body["allowed_libraries"] = all ? NSNull() : allowed.sorted()
                        _ = try await state.api!.putObject("api/auth/users/access", body)
                    }
                } label: {
                    Text("Enregistrer").fontWeight(.semibold)
                }
                .disabled(busy || libraries.isEmpty)
                Button("Annuler", role: .cancel) { onDismiss() }
                    .disabled(busy)
            },
        )
        .onAppear {
            allowed = userAllowedLibraries(user) ?? libraries.map { $0.id }
            blocked = userBlockedGenres(user)
        }
        .task {
            guard let api = state.api else { return }
            if let o = try? await api.getObject("api/auth/genres") {
                genres = o.objects("genres").compactMap { g in g.str("name").map { ($0, g.int("count") ?? 0) } }
                preset = o.strings("preset")
            }
        }
    }
}

// MARK: - Avatar d'un autre compte

/** Avatar d'un autre compte : avatars proposés, photo de la galerie ou avatar par défaut. */
private struct UserAvatarDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let user: JSONDict
    let onDismiss: () -> Void
    let onChanged: () -> Void

    @State private var presets: [JSONDict] = []
    @State private var current: String? = nil
    @State private var kind: String? = nil
    @State private var busy = false
    @State private var photoItem: PhotosPickerItem? = nil

    private var key: String { user.str("key") ?? "" }

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Avatar(api: state.api, url: current, size: 40)
                        Text(userTitle(user)).lineLimit(1)
                    }
                    if busy {
                        ProgressView().progressViewStyle(.linear)
                    }
                    FlowRow(spacing: 10) {
                        ForEach(presets.indices, id: \.self) { i in
                            let pr = presets[i]
                            let url = pr.str("url")
                            let chosen = url != nil && url == current && kind != "photo"
                            Button {
                                guard let n = pr.str("name"), !busy else { return }
                                act("Avatar changé") {
                                    try await state.api!.putObject("api/auth/users/avatar", ["key": key, "preset": n])
                                }
                            } label: {
                                Avatar(api: state.api, url: url, size: 48)
                                    .overlay(Circle().strokeBorder(chosen ? cs.accent : Color.clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                    }
                    HStack(spacing: 8) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.badge.plus").font(.caption)
                                Text("Photo")
                            }
                        }
                        .buttonStyle(OutlinedPillButtonStyle())
                        .disabled(busy)
                        if kind != "default" {
                            Button {
                                act("Avatar par défaut") {
                                    try await state.api!.deleteObject("api/auth/users/avatar", ["key": key])
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise").font(.caption)
                                    Text("Par défaut")
                                }
                            }
                            .buttonStyle(OutlinedPillButtonStyle())
                            .disabled(busy)
                        }
                    }
                }
            },
            buttons: {
                Button("Fermer") { onDismiss() }.disabled(busy)
            },
        )
        .task {
            guard let api = state.api else { return }
            current = user.str("avatar_url")
            kind = user.str("avatar_kind")
            if let o = try? await api.getObject("api/auth/avatar-presets") {
                presets = o.objects("presets")
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    ToastCenter.shared.show("Image illisible.")
                    return
                }
                let mime = imageMime(data)
                act("Photo enregistrée") {
                    try await state.api!.postMultipart(
                        "api/auth/users/avatar", field: "avatar",
                        filename: "avatar.\(mime.components(separatedBy: "/").last ?? "jpg")",
                        bytes: data, mime: mime, fields: ["key": key],
                    )
                }
            }
        }
    }

    private func act(_ ok: String, _ block: @escaping () async throws -> JSONDict) {
        busy = true
        launchAction(ok, then: { busy = false; onChanged() }) {
            let res = try await block()
            current = res.str("avatar_url")
            kind = res.str("avatar_kind")
            if user.bool("is_me") == true { state.avatarUrl = current }
        }
    }
}
