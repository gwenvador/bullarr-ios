import SwiftUI
import UIKit

// MARK: - Réglages → Intégrations (lecteurs)

/**
 * Relier SON compte Komga. Le serveur se connecte une fois avec l'identifiant et le mot de passe,
 * crée une clé API à son nom et ne garde que cette clé ; l'avancement de lecture affiché et envoyé
 * est alors celui de ce compte (api/komga/me).
 */
struct IntegrationsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @State private var status: JSONDict? = nil
    @State private var error: String? = nil
    @State private var busy = false
    @State private var useKey = false
    @State private var user = ""
    @State private var pass = ""
    @State private var key = ""
    @State private var askUnlink = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = error { ErrorCard(message: e) }
                if let s = status { komgaCard(s) }
            }
            .padding(12)
        }
        .task { await load() }
        .overlay {
            if askUnlink {
                ConfirmDialog(
                    title: "Délier Komga ?",
                    text: "Bullarr n'affichera plus votre avancement Komga. Votre compte Komga n'est pas modifié.",
                    confirm: "Délier",
                    onConfirm: { run("Compte Komga délié") { api in try await api.deleteObject("api/komga/me") } },
                    onDismiss: { askUnlink = false }
                )
            }
        }
    }

    private func load() async {
        guard let api = state.api else { return }
        error = nil
        do { status = try await api.getObject("api/komga/me") }
        catch { self.error = readable(error) }
    }

    /// Action : remplace l'état, vide les mots de passe ; toast de réussite ou d'erreur.
    private func run(_ ok: String, _ block: @escaping (BullarrApi) async throws -> JSONDict) {
        guard let api = state.api else { return }
        busy = true
        launchAction(ok, then: { busy = false }) {
            status = try await block(api)
            pass = ""
            key = ""
        }
    }

    // --- La carte Komga ------------------------------------------------------------

    @ViewBuilder
    private func komgaCard(_ s: JSONDict) -> some View {
        let available = s.bool("available") == true
        let linked = s.bool("linked") == true
        let head = !available ? "Non disponible sur ce serveur"
            : (linked ? "Relié : \(s.str("komga_user") ?? "compte Komga")" : "Non relié · avancement enregistré dans Bullarr")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Logo(key: "komga", label: "Komga", size: 32, tip: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Komga").font(.subheadline.weight(.semibold)).foregroundColor(cs.text)
                    Text(head).font(.caption).foregroundColor(cs.muted)
                }
                Spacer()
                if linked { Image(systemName: "checkmark.circle.fill").foregroundColor(cs.accent) }
            }
            if busy { ProgressView().tint(cs.accent).frame(maxWidth: .infinity, alignment: .leading) }
            if !available {
                Text("Komga n'est pas configuré sur ce serveur : votre avancement de lecture est enregistré par Bullarr, pour votre compte uniquement.")
                    .font(.subheadline).foregroundColor(cs.text)
            } else if linked {
                linkedSection(s)
            } else {
                linkSection(s)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    @ViewBuilder
    private func linkedSection(_ s: JSONDict) -> some View {
        Text("Votre avancement de lecture est celui de votre compte Komga : ce que vous lisez dans Bullarr y est enregistré, et ce que vous lisez dans Komga apparaît ici.")
            .font(.subheadline).foregroundColor(cs.text)
        if let st = s.dict("stats") {
            let line = "\(st.int("read") ?? 0) lu(s) · \(st.int("reading") ?? 0) en cours"
            Text(line).font(.caption).foregroundColor(cs.muted)
        }
        if let lastError = s.str("last_error") {
            Text(lastError).font(.caption).foregroundColor(cs.error)
        }
        HStack(spacing: 8) {
            Button {
                run("Lecture synchronisée") { api in
                    _ = try await api.postObject("api/komga/read-progress/sync", [:])
                    return try await api.getObject("api/komga/me")
                }
            } label: {
                Label("Synchroniser", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(OutlinedPillButtonStyle())
            .disabled(busy)

            Button { askUnlink = true } label: {
                Label("Délier", systemImage: "link.slash")
            }
            .buttonStyle(OutlinedPillButtonStyle())
            .tint(cs.error)
            .foregroundColor(cs.error)
            .disabled(busy)
        }
    }

    @ViewBuilder
    private func linkSection(_ s: JSONDict) -> some View {
        Text("Reliez votre compte Komga pour y retrouver et y enregistrer votre avancement de lecture. Sans compte relié, il est enregistré par Bullarr, pour votre compte uniquement.")
            .font(.subheadline).foregroundColor(cs.text)
        if let komgaUrl = s.str("komga_url") {
            Text(komgaUrl).font(.caption).foregroundColor(cs.muted)
        }
        if useKey {
            FormField(value: $key, label: "Clé API Komga", password: true)
        } else {
            FormField(value: $user, label: "E-mail Komga", keyboardType: .emailAddress)
            FormField(value: $pass, label: "Mot de passe Komga", password: true)
            Text("Le mot de passe n'est pas enregistré : Bullarr crée une clé API à votre nom dans Komga.")
                .font(.caption).foregroundColor(cs.muted)
        }
        let canConnect = useKey ? !key.trimmed.isBlank : (!user.trimmed.isBlank && !pass.isEmpty)
        Button {
            let body: JSONDict = useKey
                ? ["api_key": key.trimmed]
                : ["username": user.trimmed, "password": pass]
            run("Compte Komga relié") { api in try await api.putObject("api/komga/me", body) }
        } label: {
            Text("Se connecter")
        }
        .buttonStyle(AccentPillButtonStyle())
        .disabled(busy || !canConnect)
        .opacity(canConnect && !busy ? 1 : 0.5)
        Button {
            useKey.toggle()
        } label: {
            Text(useKey ? "Utiliser mon e-mail et mon mot de passe" : "Utiliser une clé API")
                .font(.subheadline)
        }
        .foregroundColor(cs.accent)
    }
}

// MARK: - Réglages → À propos

/// Version, mise à jour et liens vers les dépôts GitHub.
struct AboutScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image("bullarr_logo").resizable().scaledToFit().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bullarr").font(.title2.weight(.semibold)).foregroundColor(cs.accent)
                        Text("Version \(state.installedVersion)").font(.subheadline).foregroundColor(cs.muted)
                    }
                }
                UpdateCard()
                linksCard
            }
            .padding(16)
        }
    }

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Liens").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ForEach(Array(links.enumerated()), id: \.offset) { i, link in
                Button { openInBrowser(link.url) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: link.icon).foregroundColor(cs.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.label).font(.subheadline).foregroundColor(cs.text)
                            Text(link.url.replacingOccurrences(of: "https://", with: ""))
                                .font(.caption).foregroundColor(cs.muted).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundColor(cs.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < links.count - 1 { Divider().padding(.leading, 44) }
            }
            .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
    }

    private struct LinkRow {
        let icon: String
        let label: String
        let url: String
    }

    private var links: [LinkRow] {
        [
            LinkRow(icon: "iphone", label: "Application iOS", url: "https://github.com/gwenvador/bullarr-ios"),
            LinkRow(icon: "server.rack", label: "Serveur Bullarr", url: "https://github.com/gwenvador/bullarr"),
            LinkRow(icon: "newspaper", label: "Versions de l'application", url: "https://github.com/gwenvador/bullarr-ios/releases"),
            LinkRow(icon: "ladybug", label: "Signaler un problème", url: "https://github.com/gwenvador/bullarr-ios/issues"),
        ]
    }
}

/// Version installée et état de la mise à jour, d'après les releases GitHub (une vérification par
/// lancement ; le bouton relance à la demande).
struct UpdateCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Application").font(.subheadline.weight(.semibold))
            Text("Version installée : \(state.installedVersion)").font(.subheadline)
            switch state.update {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(cs.accent)
                    Text("Recherche d'une mise à jour…").font(.footnote).foregroundColor(cs.muted)
                }
            case let .upToDate(latest):
                let v = latest?.version ?? ""
                Text(v.isEmpty ? "À jour · aucune version publiée trouvée" : "À jour · dernière version publiée : \(v)")
                    .font(.footnote).foregroundColor(cs.accent)
            case let .available(r):
                availableBlock(r)
            case let .failed(message):
                ErrorCard(message: message)
            }
            if state.update != .idle && state.update != .checking {
                Button { state.checkUpdate() } label: { Text("Vérifier maintenant") }
                    .buttonStyle(OutlinedPillButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.surface))
        .task { if state.update == .idle { state.checkUpdate() } }
    }

    @ViewBuilder
    private func availableBlock(_ r: AppRelease) -> some View {
        let when = r.publishedAt.map { String($0.prefix(10)) } ?? ""
        let size = r.sizeBytes.flatMap { formatBytes($0) }.map { " · \($0)" } ?? ""
        Text("Mise à jour disponible : \(r.version)\(when.isEmpty ? "" : " (publiée le \(when))")\(size)")
            .font(.subheadline.weight(.medium)).foregroundColor(cs.tertiary)
        Button { openInBrowser(r.page ?? r.url) } label: { Text("Voir la version") }
            .buttonStyle(AccentPillButtonStyle())
        Text("Sur iOS, l'app se met à jour via Xcode ou TestFlight ; la page de la version détaille les changements.")
            .font(.caption).foregroundColor(cs.muted)
    }
}
