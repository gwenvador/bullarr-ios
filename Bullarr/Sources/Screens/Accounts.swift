import SwiftUI
import PhotosUI

// Comptes (Accounts.kt) : demandes de BD du lecteur, validation côté administrateur,
// profil (avatar, nom, e-mail, mot de passe) et déconnexion.

/// Date SQLite du serveur (UTC, « yyyy-MM-dd HH:mm:ss ») en heure locale « dd/MM/yyyy HH:mm ».
func utcToLocal(_ s: String?) -> String? {
    guard let s else { return nil }
    let inFmt = DateFormatter()
    inFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    inFmt.locale = Locale(identifier: "en_US_POSIX")
    inFmt.timeZone = TimeZone(identifier: "UTC")
    if let d = inFmt.date(from: String(s.trimmed.prefix(19))) {
        let out = DateFormatter()
        out.dateFormat = "dd/MM/yyyy HH:mm"
        return out.string(from: d)
    }
    return String(s.prefix(16))
}

/// Libellé et couleur d'un statut de demande de BD.
func requestStatus(_ status: String?, cs: BullColors) -> (String, Color) {
    switch status {
    case "pending": return ("En attente", cs.tertiary)
    case "adding": return ("Ajout en cours", cs.accent)
    case "added": return ("Ajoutée", cs.accent)
    case "already": return ("Déjà présente", cs.accent)
    case "rejected": return ("Refusée", cs.error)
    case "error": return ("Erreur", cs.error)
    case "cancelled": return ("Annulée", cs.muted)
    default: return (status ?? "?", cs.muted)
    }
}

/// Devine le type MIME d'une image à partir de sa signature.
func imageMime(_ data: Data) -> String {
    if data.count > 2, data[0] == 0x89, data[1] == 0x50 { return "image/png" }
    if data.count > 2, data[0] == 0x47, data[1] == 0x49 { return "image/gif" }
    if data.count > 12, data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return "image/webp" }
    return "image/jpeg"
}

// MARK: - Avatar

/** Avatar rond d'un compte ; icône neutre tant que l'image n'est pas chargée (ou sans avatar). */
struct Avatar: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi?
    let url: String?
    var size: CGFloat = 40

    @State private var image: UIImage? = nil

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundColor(cs.muted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .background(Circle().fill(cs.alt))
        .task(id: url) {
            guard let api, let url, !url.isBlank else { return }
            let key = "\(url)@\(Int(size))" as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            guard let data = try? await api.getBytes(url.trimmed) else { return }
            // Les avatars proposés sont des SVG : iOS ne les décode pas, on garde l'icône neutre.
            if let head = String(data: data.prefix(16), encoding: .utf8)?.trimmed, head.hasPrefix("<") { return }
            if let img = UIImage(data: data) {
                Self.cache.setObject(img, forKey: key)
                image = img
            }
        }
    }
}

// MARK: - Ligne de demande

/** Une demande de BD : couverture (si la série existe), titre, statut, détails ; [actions] à droite. */
struct RequestRow<Actions: View>: View {
    @Environment(\.bullColors) private var cs
    @ObservedObject var state: AppState
    let r: JSONDict
    let showUser: Bool
    var onOpen: ((Int, String) -> Void)? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let title = r.str("title") ?? r.str("url") ?? "(sans titre)"
        let sid = r.int("series_id")
        let st = requestStatus(r.str("status"), cs: cs)
        HStack(spacing: 12) {
            ZStack {
                if let cover = r.str("cover_url") {
                    Cover(url: state.coverUrl(cover), width: 44)
                } else {
                    Image(systemName: "books.vertical").foregroundColor(cs.muted)
                }
            }
            .frame(width: 44, height: 60)
            .background(RoundedRectangle(cornerRadius: 6).fill(cs.alt))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(st.0).font(.caption).foregroundColor(st.1)
                let total = r.int("total")
                let meta = [
                    showUser ? r.str("user_name") : nil,
                    utcToLocal(r.str("created_at")),
                    r.str("library_name"),
                    (total != nil && sid != nil) ? "\(r.int("owned") ?? 0)/\(total!) tomes" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundColor(cs.muted).lineLimit(2)
                }
                if let err = r.str("error") {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(r.str("status") == "rejected" ? cs.muted : cs.error)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if let sid, let onOpen { onOpen(sid, title) }
        }
    }
}

// MARK: - Demandes du lecteur

/** Rubrique « Demandes » d'un lecteur : ses demandes de BD, l'annulation de celles en attente, et « Demander une BD ». */
struct RequestsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    var openSeries: (Int, String) -> Void

    @State private var list: [JSONDict]? = nil
    @State private var error: String? = nil
    @State private var loading = false
    @State private var asking = false
    @State private var autoApprove = false

    private func load() async {
        guard let api = state.api else { return }
        loading = true
        error = nil
        do {
            let o = try await api.getObject("api/requests")
            list = o.objects("requests")
            autoApprove = o.bool("auto_approve") == true
        } catch {
            self.error = readable(error)
        }
        loading = false
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
        .task { await load() }
        // Un ajout validé se fait en arrière-plan : on relit tant qu'une demande est « en cours ».
        .task(id: "\(list?.count ?? -1)|\(list?.filter { $0.str("status") == "adding" }.count ?? 0)") {
            if list?.contains(where: { $0.str("status") == "adding" }) == true {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await load()
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        asking = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "books.vertical").font(.caption)
                            Text("Demander une BD")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentPillButtonStyle())
                    Text(autoApprove
                         ? "Vos demandes sont ajoutées tout de suite à la bibliothèque."
                         : "Un administrateur valide chaque demande avant l'ajout à la bibliothèque.")
                        .font(.caption)
                        .foregroundColor(cs.muted)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                if loading && list == nil {
                    ProgressView().progressViewStyle(.linear).padding(16)
                }
                if let error {
                    ErrorCard(message: error, onRetry: { Task { await load() } }).padding(16)
                }
                if let list, list.isEmpty {
                    EmptyStateView(title: "Aucune demande", detail: "Cherchez une série sur Bédéthèque et demandez-la.")
                        .padding(16)
                }
                if let list {
                    ForEach(list.indices, id: \.self) { i in
                        let r = list[i]
                        RequestRow(state: state, r: r, showUser: false, onOpen: openSeries) {
                            if r.str("status") == "pending" {
                                Button {
                                    guard let id = r.int("id") else { return }
                                    launchAction("Demande annulée", then: { Task { await load() } }) {
                                        _ = try await state.api!.deleteObject("api/requests/\(id)")
                                    }
                                } label: {
                                    Image(systemName: "xmark").frame(width: 32, height: 32)
                                }
                                .accessibilityLabel("Annuler la demande")
                            }
                        }
                        Divider().overlay(cs.outlineVariant).padding(.leading, 68)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await load() }
        .overlay {
            if asking {
                SeriesAddDialog(initialQuery: "", onRequested: { Task { await load() } }, onDismiss: { asking = false }, onAdded: { _, _ in })
            }
        }
    }
}

// MARK: - Validation côté admin

/**
 * Haut de Validation (administrateurs) : comptes en attente et demandes de BD des lecteurs.
 * La validation d'une demande rend la main tout de suite (statut « adding ») ; l'ajout se fait côté serveur.
 */
struct AdminRequestsBlock: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    var onOpenSeries: (Int, String) -> Void

    @State private var requests: [JSONDict] = []
    @State private var accounts: [JSONDict] = []
    @State private var autoApprove: Bool? = nil
    @State private var approving: JSONDict? = nil
    @State private var rejecting: JSONDict? = nil
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !accounts.isEmpty {
                accountsCard
            }
            requestsCard
        }
        .task(id: tick) { await reload() }
        .overlay {
            if let r = approving, let id = r.int("id") {
                ApproveRequestDialog(r: r, id: id, onDismiss: { approving = nil }, onApproved: { approving = nil; tick += 1 })
            }
        }
        .overlay {
            if let r = rejecting, let id = r.int("id") {
                RejectRequestDialog(r: r, id: id, onDismiss: { rejecting = nil }, onRejected: { rejecting = nil; tick += 1 })
            }
        }
    }

    private func reload() async {
        guard let api = state.api else { return }
        if let o = try? await api.getObject("api/requests", query: ["status": "pending"]) {
            requests = o.objects("requests")
            autoApprove = o.bool("auto_approve")
        }
        if let o = try? await api.getObject("api/auth/users") {
            accounts = o.objects("users").filter { $0.str("status") == "pending" }
        }
        state.requestCount = requests.count + accounts.count
        if state.libraries.isEmpty { await state.loadLibrary() }
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Comptes en attente · \(accounts.count)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            ForEach(accounts.indices, id: \.self) { i in
                if let key = accounts[i].str("key") {
                    let u = accounts[i]
                    HStack(spacing: 12) {
                    Avatar(api: state.api, url: u.str("avatar_url"), size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.str("name") ?? u.str("username") ?? key).lineLimit(1)
                        Text([u.str("email"), utcToLocal(u.str("first_seen"))].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(cs.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        launchAction("Demande d'inscription refusée", then: { tick += 1 }) {
                            _ = try await state.api!.deleteObject("api/auth/users", ["key": key])
                        }
                    } label: {
                        Image(systemName: "xmark").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Refuser")
                    Button {
                        launchAction("Compte validé (lecteur)", then: { tick += 1 }) {
                            _ = try await state.api!.postObject("api/auth/users/approve", ["key": key, "role": "reader"])
                        }
                    } label: {
                        Image(systemName: "checkmark").frame(width: 32, height: 32)
                    }
                    .foregroundColor(cs.accent)
                    .accessibilityLabel("Valider comme lecteur")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    private var requestsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Demandes de BD" + (requests.isEmpty ? "" : " · \(requests.count)"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Auto").font(.caption).foregroundColor(cs.muted)
                Toggle("", isOn: Binding(
                    get: { autoApprove == true },
                    set: { on in
                        autoApprove = on
                        launchAction(on ? "Validation automatique activée" : "Validation automatique désactivée") {
                            _ = try await state.api!.putObject("api/requests/settings", ["auto_approve": on])
                        }
                    },
                ))
                .labelsHidden()
                .disabled(autoApprove == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if requests.isEmpty {
                Text(autoApprove == true ? "Les demandes des lecteurs sont ajoutées automatiquement." : "Aucune demande en attente.")
                    .font(.caption)
                    .foregroundColor(cs.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            ForEach(requests.indices, id: \.self) { i in
                let r = requests[i]
                RequestRow(state: state, r: r, showUser: true, onOpen: onOpenSeries) {
                    Button { rejecting = r } label: {
                        Image(systemName: "xmark").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Refuser")
                    Button { approving = r } label: {
                        Image(systemName: "checkmark").frame(width: 32, height: 32)
                    }
                    .foregroundColor(cs.accent)
                    .accessibilityLabel("Valider")
                }
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }
}

/** Validation d'une demande : choix de la bibliothèque si plusieurs. */
private struct ApproveRequestDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let r: JSONDict
    let id: Int
    let onDismiss: () -> Void
    let onApproved: () -> Void

    @State private var lib: Int? = nil

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Valider la demande").font(.headline)
                    Text("« \(r.str("title") ?? r.str("url") ?? "") », demandée par \(r.str("user_name") ?? "?").")
                        .font(.subheadline)
                    if state.libraries.count > 1 {
                        Text("Bibliothèque").font(.caption.weight(.semibold))
                        FlowRow(spacing: 8) {
                            ForEach(state.libraries, id: \.id) { l in
                                FilterChip(selected: lib == l.id) { lib = l.id } label: {
                                    Text(l.name)
                                }
                            }
                        }
                    }
                    Text("La série est ajoutée en arrière-plan depuis Bédéthèque, puis ses tomes sont recherchés.")
                        .font(.caption)
                        .foregroundColor(cs.muted)
                }
            },
            buttons: {
                Button {
                    launchAction("Demande validée : ajout en cours", then: { onApproved() }) {
                        var body: JSONDict = [:]
                        if let lib { body["library_id"] = lib }
                        _ = try await state.api!.postObject("api/requests/\(id)/approve", body)
                    }
                } label: {
                    Text("Valider").fontWeight(.semibold)
                }
                Button("Annuler", role: .cancel) { onDismiss() }
            },
        )
        .onAppear { lib = r.int("library_id") ?? state.selectedLibrary?.id ?? state.libraries.first?.id }
    }
}

/** Refus d'une demande, avec motif facultatif. */
private struct RejectRequestDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let r: JSONDict
    let id: Int
    let onDismiss: () -> Void
    let onRejected: () -> Void

    @State private var reason = ""

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Refuser la demande").font(.headline)
                    Text("« \(r.str("title") ?? r.str("url") ?? "") », demandée par \(r.str("user_name") ?? "?").")
                        .font(.subheadline)
                    FormField(value: $reason, label: "Motif (facultatif)")
                }
            },
            buttons: {
                Button {
                    launchAction("Demande refusée", then: { onRejected() }) {
                        _ = try await state.api!.postObject("api/requests/\(id)/reject", ["reason": reason.trimmed])
                    }
                } label: {
                    Text("Refuser").fontWeight(.semibold).foregroundColor(cs.error)
                }
                Button("Annuler", role: .cancel) { onDismiss() }
            },
        )
    }
}

// MARK: - Profil

/** Réglages → Profil : avatar (proposés, photo, par défaut), puis nom, e-mail et mot de passe des comptes locaux. */
struct ProfileScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    @State private var profile: JSONDict? = nil
    @State private var error: String? = nil
    @State private var presets: [JSONDict] = []
    @State private var busy = false
    @State private var name = ""
    @State private var email = ""
    @State private var current = ""
    @State private var newPass = ""
    @State private var confirm = ""
    @State private var avatarsOpen = false
    @State private var photoItem: PhotosPickerItem? = nil

    private func applyProfile(_ p: JSONDict) {
        profile = p
        name = p.str("name") ?? ""
        email = p.str("email") ?? ""
        state.avatarUrl = p.str("avatar_url")
        state.profileName = p.str("name") ?? state.profileName
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
        .task { await load() }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    ToastCenter.shared.show("Image illisible.")
                    return
                }
                let mime = imageMime(data)
                avatarAction("Photo de profil enregistrée") {
                    try await state.api!.postMultipart(
                        "api/auth/profile/avatar", field: "avatar",
                        filename: "avatar.\(mime.components(separatedBy: "/").last ?? "jpg")",
                        bytes: data, mime: mime,
                    )
                }
            }
        }
    }

    private func load() async {
        guard let api = state.api else { return }
        do {
            applyProfile((try await api.getObject("api/auth/profile")).dict("profile") ?? JSONDict())
        } catch {
            self.error = readable(error)
        }
        if let o = try? await api.getObject("api/auth/avatar-presets") {
            presets = o.objects("presets")
        }
    }

    private func avatarAction(_ ok: String, _ block: @escaping () async throws -> JSONDict) {
        busy = true
        launchAction(ok, then: { busy = false }) {
            let res = try await block()
            state.avatarUrl = res.str("avatar_url")
            if profile != nil {
                var p = profile!
                p["avatar_url"] = res.str("avatar_url")
                p["avatar_kind"] = res.str("avatar_kind")
                profile = p
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {                if let e = error {
                    // Clé API : aucun compte derrière, donc pas de profil.
                    if e.contains("Aucun compte") {
                        EmptyStateView(title: "Pas de profil", detail: "L'app est connectée par clé API : connectez-vous avec un compte pour avoir un profil.")
                    } else {
                        ErrorCard(message: e)
                    }
                }
                if let p = profile {
                    headerCard(p)
                    avatarCard(p)
                    accountCard(p)
                }
                if error != nil || profile != nil {
                    LogoutCard()
                }
            }
            // Marge basse : « Se déconnecter » doit toujours rester au-dessus de la barre d'onglets,
            // même quand le formulaire est long (petits écrans).
            .padding(12)
            .padding(.bottom, 64)
        }
        .refreshable { await load() }
    }

    private func headerCard(_ p: JSONDict) -> some View {
        HStack(spacing: 16) {
            Avatar(api: state.api, url: state.avatarUrl ?? p.str("avatar_url"), size: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.str("name") ?? p.str("username") ?? "?")
                    .font(.title3)
                    .lineLimit(1)
                Text([p.str("role") == "reader" ? "Lecteur" : "Administrateur", p.str("type") == "local" ? "compte local" : "SSO"].joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(cs.muted)
                if let mail = p.str("email") {
                    Text(mail).font(.caption).foregroundColor(cs.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    private func avatarCard(_ p: JSONDict) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Repliée par défaut : un toucher sur l'en-tête déplie les avatars proposés.
            Button {
                avatarsOpen.toggle()
            } label: {
                HStack {
                    Text("Avatar").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: avatarsOpen ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(cs.muted)
                }
                .foregroundColor(cs.text)
                .padding(16)
            }
            .buttonStyle(.plain)
            if avatarsOpen || busy {
                VStack(alignment: .leading, spacing: 12) {
                    if busy {
                        ProgressView().progressViewStyle(.linear)
                    }
                    FlowRow(spacing: 10) {
                        ForEach(presets.indices, id: \.self) { i in
                            let pr = presets[i]
                            let url = pr.str("url")
                            let chosen = url != nil && url == (state.avatarUrl ?? p.str("avatar_url")) && p.str("avatar_kind") != "photo"
                            Button {
                                guard let n = pr.str("name"), !busy else { return }
                                avatarAction("Avatar changé") {
                                    try await state.api!.putObject("api/auth/profile/avatar", ["preset": n])
                                }
                            } label: {
                                Avatar(api: state.api, url: url, size: 52)
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
                        if p.str("avatar_kind") != "default" {
                            Button {
                                avatarAction("Avatar par défaut") {
                                    try await state.api!.deleteObject("api/auth/profile/avatar")
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
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    private func accountCard(_ p: JSONDict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compte").font(.subheadline.weight(.semibold))
            if p.bool("can_edit_identity") == true {
                FormField(value: $name, label: "Nom")
                FormField(value: $email, label: "E-mail", placeholder: "facultatif", keyboardType: .emailAddress)
                Text("Changer le mot de passe (facultatif)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                FormField(value: $current, label: "Mot de passe actuel", password: true)
                FormField(value: $newPass, label: "Nouveau mot de passe", password: true)
                FormField(value: $confirm, label: "Confirmer", password: true)
                Button {
                    busy = true
                    launchAction("Profil enregistré", then: { busy = false }) {
                        var body: JSONDict = ["name": name.trimmed, "email": email.trimmed]
                        if !newPass.isBlank {
                            body["current_password"] = current
                            body["new_password"] = newPass
                            body["new_password_confirm"] = confirm
                        }
                        let res = try await state.api!.putObject("api/auth/profile", body)
                        if let np = res.dict("profile") { applyProfile(np) }
                        current = ""
                        newPass = ""
                        confirm = ""
                    }
                } label: {
                    Text("Enregistrer")
                }
                .buttonStyle(AccentPillButtonStyle())
                .disabled(busy || name.isBlank || (!newPass.isBlank && (newPass != confirm || current.isBlank)))
                if !newPass.isBlank && newPass != confirm {
                    Text("Les deux mots de passe ne correspondent pas.")
                        .font(.caption)
                        .foregroundColor(cs.error)
                }
            } else {
                Text("Votre nom, votre e-mail et votre mot de passe se changent chez votre fournisseur SSO.")
                    .font(.caption)
                    .foregroundColor(cs.muted)
            }
            if let seen = utcToLocal(p.str("first_seen")) {
                Text("Compte créé le \(seen)").font(.caption).foregroundColor(cs.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }
}

/** Déconnexion, avec confirmation : l'app revient à l'écran de connexion. */
struct LogoutCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @State private var ask = false

    var body: some View {
        Button {
            ask = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right").font(.caption)
                Text("Se déconnecter")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(OutlinedPillButtonStyle())
        .foregroundColor(cs.error)
        .overlay {
            if ask {
                ConfirmDialog(
                    title: "Se déconnecter ?",
                    text: "Vous reviendrez à l'écran de connexion.",
                    confirm: "Se déconnecter",
                    onConfirm: {
                        ask = false
                        state.logout()
                    },
                    onDismiss: { ask = false },
                )
            }
        }
    }
}
