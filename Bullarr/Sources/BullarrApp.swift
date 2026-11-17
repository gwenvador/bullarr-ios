import SwiftUI
import WebKit

@main
struct BullarrApp: App {
    @StateObject private var state = AppState()
    @StateObject private var theme = ThemePref.shared
    @Environment(\.colorScheme) private var systemScheme

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.offline)
                .environmentObject(state.search)
                .environmentObject(state.downloads)
                .environmentObject(ThemePref.shared)
                .bullTheme(theme, colorScheme: systemScheme)
                .onOpenURL { url in
                    // Retour du SSO par navigateur : bullarr://auth?code=…
                    if url.scheme == "bullarr", url.host == "auth" {
                        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                            let code = (comps.queryItems?.first { $0.name == "code" }?.value) ?? ""
                            if code.isBlank {
                                state.ssoError = (comps.queryItems?.first { $0.name == "error" }?.value) ?? "Le serveur n'a renvoyé aucun code de connexion."
                            } else {
                                state.completeSso(code: code)
                            }
                        }
                        return
                    }
                    // Lien d'une page du site (bullarr://series/12, https://serveur/…) : ouvre l'écran équivalent.
                    if let msg = state.openWebLink(url) {
                        ToastCenter.shared.show(msg)
                    }
                }
        }
    }
}

@MainActor
final class ToastCenter: ObservableObject {
    /// Un seul centre pour toute l'app : les écrans montrent un toast sans passer par l'environnement.
    static let shared = ToastCenter()
    @Published var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var toast = ToastCenter.shared

    var body: some View {
        ZStack {
            if state.api == nil {
                // Non connecté : seulement la connexion et les albums déjà copiés sur le téléphone.
                LoggedOutView()
            } else {
                MainTabs()
                    .task(id: state.api?.baseUrl.absoluteString ?? "") { await state.loadMe() }
            }
            if let msg = toast.message {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.2, green: 0.2, blue: 0.22).opacity(0.95)))
                        .foregroundColor(.white)
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            DownloadDialogsView()
        }
        .animation(.easeInOut(duration: 0.2), value: toast.message)
        .onAppear { state.downloads.showSnackbar = { toast.show($0) } }
        .fullScreenCover(item: Binding(
            get: { state.reading },
            set: { if $0 == nil { state.reading = nil; state.progressVersion += 1 } }
        )) { target in
            ReaderScreen(target: target)
        }
    }
}

// --- Écran déconnecté --------------------------------------------------------

struct LoggedOutView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LoginScreenView(firstRun: true, onSaved: { state.section = .library })
                .tabItem { Label("Connexion", systemImage: "key.horizontal") }
                .tag(0)
            OfflineScreen()
                .tabItem { Label("Hors ligne", systemImage: "arrow.down.circle") }
                .tag(1)
        }
    }
}

// --- Onglets principaux --------------------------------------------------------

struct MainTabs: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: Binding(
                get: { state.section },
                set: { s in state.openSeries = nil; state.section = s }
            )) {
                ForEach(state.sections) { s in
                    SectionView(section: s)
                        .tabItem { Label(s.label, systemImage: s.icon) }
                        .badge(s == .tracking ? badgeTotal : 0)
                        .tag(s)
                }
            }
        }
    }

    private var badgeTotal: Int {
        state.importCount + state.newsCount + state.reviewCount + state.requestCount
    }
}

struct SectionView: View {
    @EnvironmentObject private var state: AppState
    let section: Section

    var body: some View {
        VStack(spacing: 0) {
            let sub = state.subTab[section] ?? 0
            let subs = state.subsOf(section)
            if !subs.isEmpty {
                SubTabRow(subs: subs, selected: min(sub, subs.count - 1), onSelect: { i, label in
                    state.subTab[section] = i
                    if section == .tracking && label == "Nouveautés" { state.markNewsSeen() }
                })
                .padding(.top, 2)
            }
            if state.openSeries != nil {
                SeriesScreen(series: state.openSeries!, onBack: { state.openSeries = nil }, onSearch: { ctx in
                    state.search.prefill(ctx)
                    state.goToSearch()
                })
            } else {
                Group {
                    switch section {
                    case .library:
                        if sub == 1 {
                            // Albums hors ligne, ouverts depuis le bouton de la barre d'outils.
                            OfflineScreenOpened()
                        } else {
                            LibraryScreen { summary in state.openSeries = summary }
                        }
                    case .search: SearchScreen()
                    case .requests: RequestsScreen(openSeries: { id, title in state.openSeriesById(id, title) })
                    case .tracking: TrackingSection(sub: sub)
                    case .actions: ActionsSection(sub: sub)
                    case .config: ConfigSection(subs: subs, sub: sub)
                    }
                }
                .task { Poller.run(state) }
            }
        }
        // Bandeau des actions en cours, au-dessus de la barre du bas (comme Android).
        .safeAreaInset(edge: .bottom, spacing: 0) { RunningActionsBanner() }
    }
}

/// Rafraîchit les pastilles toutes les 60 s (même cadence que l'app Android).
@MainActor
enum Poller {
    private static var task: Task<Void, Never>?
    static func run(_ state: AppState) {
        if task == nil {
            task = Task { [weak state] in
                while !Task.isCancelled {
                    await state?.refreshBadges()
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
        }
        Task { await state.refreshBadges() }
    }
}

struct SubTabRow: View {
    @Environment(\.bullColors) private var cs
    let subs: [String]
    let selected: Int
    let onSelect: (Int, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(subs.enumerated()), id: \.offset) { i, label in
                    Button { onSelect(i, label) } label: {
                        Text(label)
                            .font(.subheadline)
                            .fontWeight(selected == i ? .semibold : .regular)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 18).fill(selected == i ? cs.accentContainer : Color.clear))
                            .foregroundColor(selected == i ? cs.accent : cs.muted)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}

struct TrackingSection: View {
    @EnvironmentObject private var state: AppState
    let sub: Int

    var body: some View {
        Group {
            switch sub {
            case 0: ActivityScreen()
            case 1: NewsScreen(openSeries: { id, title in state.openSeriesById(id, title) })
            case 2: ValidationScreen()
            default: HistoryScreen(openSeries: { id, title in state.openSeriesById(id, title) })
            }
        }
    }
}

struct ActionsSection: View {
    @EnvironmentObject private var state: AppState
    let sub: Int

    var body: some View {
        Group {
            switch sub {
            case 0: EnrichScreen(openSeries: { id, title in state.openSeriesById(id, title) })
            case 1: MonitorScreen(openSeries: { id, title in state.openSeriesById(id, title) })
            default: VerificationScreen(openSeries: { id, title in state.openSeriesById(id, title) })
            }
        }
    }
}

struct ConfigSection: View {
    @EnvironmentObject private var state: AppState
    let subs: [String]
    let sub: Int

    var body: some View {
        let label = subs[safe: min(sub, subs.count - 1)] ?? subs.last ?? "À propos"
        Group {
            switch label {
            case "Indexeurs": ConfigScreen(integrations: INDEXERS)
            case "Clients": ConfigScreen(integrations: CLIENTS)
            case "Intégrations": IntegrationsScreen()
            case "Notifications": NotificationsScreen()
            case "Imports": ConfigScreen(integrations: IMPORTS)
            case "Recherche": ConfigScreen(integrations: SEARCH_SETTINGS)
            case "Surveillance": ConfigScreen(integrations: MONITOR)
            case "Apparence": AppearanceScreen()
            case "Upscaling": UpscalingScreen()
            case "Accès": ConfigScreen(integrations: ACCESS, header: { AnyView(LoginScreenView(firstRun: false, onSaved: {}, embedded: true).padding(.bottom, 8)) })
            case "Utilisateurs": UsersScreen()
            case "IA": AiSettingsScreen()
            case "Web": WebSettingsScreen()
            case "Profil": ProfileScreen()
            default: AboutScreen()
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Albums hors ligne, ouverts depuis le bouton de la barre d'outils de la bibliothèque :
/// une barre avec retour plutôt qu'un onglet.
struct OfflineScreenOpened: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    state.subTab[Section.library] = nil
                } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Retour à la bibliothèque")
                Text("Albums hors ligne").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 8)
            OfflineScreen()
        }
    }
}

// --- Écran de connexion --------------------------------------------------------

struct LoginScreenView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    var firstRun: Bool
    var onSaved: () -> Void
    var embedded: Bool = false

    @State private var url = ""
    @State private var key = ""
    @State private var mode = "key"
    @State private var user = ""
    @State private var pass = ""
    @State private var cookie = ""
    @State private var sso = false
    @State private var testing = false
    @State private var success: String?
    @State private var error: String?
    @State private var savedNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if firstRun {
                    VStack(spacing: 8) {
                        Image("bullarr_logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                        Text("Bullarr").font(.system(size: 42, weight: .bold)).foregroundColor(cs.accent)
                    }
                    .frame(maxWidth: .infinity)
                    Text("Pilotez votre collection de BD depuis le téléphone.").font(.body)
                } else {
                    Text("Connexion de l'app").font(.title2.bold())
                }

                ClearableField(value: $url, label: "URL du serveur", placeholder: "http://192.168.1.10:4000", supportingText: nil)
                    .onChange(of: url) { success = nil; error = nil }
                Picker("Mode", selection: $mode) {
                    Text("Clé API").tag("key")
                    Text("Compte").tag("password")
                    Text("SSO").tag("oidc")
                }
                .pickerStyle(.segmented)

                if mode == "key" {
                    ClearableField(value: $key, label: "Clé API", placeholder: nil, supportingText: "Dans Bullarr : Paramètres → Login → carte « Accès API ».", secure: true)
                        .onChange(of: key) { success = nil; error = nil }
                }
                if mode == "password" {
                    ClearableField(value: $user, label: "Identifiant")
                        .onChange(of: user) { success = nil; error = nil }
                    ClearableField(value: $pass, label: "Mot de passe", supportingText: "Compte défini dans Bullarr : Paramètres → Login.", secure: true)
                        .onChange(of: pass) { success = nil; error = nil }
                }
                if mode == "oidc" {
                    Button {
                        // Navigateur du système (passkeys possibles) : Bullarr renvoie ensuite vers bullarr://auth?code=…
                        do {
                            let base = try BullarrApi.normalizeBaseUrl(url)
                            state.settings.lastUrl = url.trimmed
                            state.ssoError = nil
                            let redirect = base.absoluteString.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/login/redirect?app=1"
                            UIApplication.shared.open(URL(string: redirect)!)
                        } catch {
                            state.ssoError = readable(error)
                        }
                    } label: {
                        HStack {
                            if state.ssoBusy { ProgressView() } else { Image(systemName: "shield") }
                            Text(state.ssoBusy ? "Connexion en cours…" : "Se connecter avec le SSO (navigateur)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(url.isBlank || state.ssoBusy)
                    if let err = state.ssoError { ErrorCard(message: err) }
                    // Secours : fenêtre intégrée, sans passkey (code de connexion ou autre appareil seulement).
                    Button {
                        sso = true
                    } label: {
                        Text(cookie.isBlank ? "Dans l'app (sans passkey)" : "Se reconnecter dans l'app")
                    }
                    if !cookie.isBlank { Text("Session SSO ouverte.").font(.footnote).foregroundColor(cs.muted) }
                }
                if sso {
                    OidcLoginView(serverUrl: url) { c, origin in
                        // Le serveur redirige peut-être vers https : on garde l'adresse réellement atteinte.
                        url = origin
                        cookie = c
                        sso = false
                        success = "Session SSO ouverte : appuyez sur Se connecter."
                        error = nil
                    } onCancel: { sso = false }
                }

                HStack(spacing: 12) {
                    if !firstRun {
                        Button {
                            testConnection()
                        } label: {
                            if testing { ProgressView() } else { Text("Tester") }
                        }
                        .buttonStyle(.bordered)
                        .disabled(testing)
                    }
                    Button {
                        connect()
                    } label: {
                        Text("Se connecter").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(url.isBlank)
                }
                .padding(.top, 4)

                if let success {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                        Text(success)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(cs.secondaryContainer))
                    .foregroundColor(cs.text)
                }
                if let error { ErrorCard(message: error) }
                if let savedNote { Text(savedNote).font(.footnote).foregroundColor(cs.muted) }

                Text("L'URL, la clé et la session sont chiffrées sur l'appareil (trousseau iOS). Exemple d'URL : http://192.168.1.10:4000 ou https://bullarr.mondomaine.fr.")
                    .font(.caption)
                    .foregroundColor(cs.muted)
                if !firstRun {
                    Button {
                        state.logout()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.left.circle")
                            Text("Se déconnecter")
                        }
                        .foregroundColor(cs.error)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(embedded ? 8 : 20)
        }
        .onAppear {
            url = state.settings.serverUrl.isBlank ? state.settings.lastUrl : state.settings.serverUrl
            key = state.settings.apiKey
            mode = state.settings.authMode
            user = state.settings.username
            pass = state.settings.password
            cookie = state.settings.sessionCookie
        }
    }

    private func testConnection() {
        testing = true
        success = nil
        error = nil
        Task {
            defer { testing = false }
            do {
                let api: BullarrApi
                if mode == "key" {
                    api = try BullarrApi(url, apiKey: key)
                } else {
                    api = try BullarrApi(url, apiKey: "", session: SessionAuth(cookie: cookie, username: user, password: pass))
                }
                if mode == "password" { cookie = try await api.loginPassword(user, pass) }
                if mode == "oidc" && cookie.isBlank {
                    throw ApiException("Ouvrez d'abord la session avec « Se connecter avec le SSO ».")
                }
                let me = try await api.getObject("api/auth/me")
                let u = me.dict("user")
                let who = u?.str("name").ifBlank(nil) ?? u?.str("preferred_username").ifBlank(nil) ?? u?.str("email").ifBlank(nil) ?? u?.str("username").ifBlank(nil)
                if mode != "key" && u == nil {
                    throw ApiException("Session non ouverte : le serveur ne vous reconnaît pas (identifiants ou SSO).")
                }
                if mode == "key" && key.isBlank {
                    success = "Serveur joignable, mais sans clé API : cela ne marchera que si l'authentification de Bullarr est désactivée."
                } else if let who {
                    success = "Connexion réussie (utilisateur : \(who))."
                } else {
                    success = "Connexion réussie : la clé API est acceptée."
                }
            } catch {
                self.error = readable(error)
            }
        }
    }

    private func connect() {
        Task {
            do {
                _ = try BullarrApi.normalizeBaseUrl(url)
                if mode == "password" {
                    let api = try BullarrApi(url, apiKey: "", session: SessionAuth(cookie: "", username: user, password: pass))
                    cookie = try await api.loginPassword(user, pass)
                }
                if mode == "oidc" && cookie.isBlank {
                    throw ApiException("Ouvrez d'abord la session avec « Se connecter avec le SSO ».")
                }
                state.save(url: url, key: key, mode: mode, user: user, pass: pass, cookie: cookie)
                savedNote = "Connecté."
                onSaved()
            } catch {
                self.error = readable(error)
            }
        }
    }
}

/// Connexion SSO : ouvre /login/redirect de Bullarr dans une fenêtre intégrée (le fournisseur
/// OIDC gère son propre écran), puis récupère le cookie de session posé par /callback. Terminé
/// dès que la fenêtre atterrit sur une page de Bullarr autre que les pages de connexion.
struct OidcLoginView: View {
    let serverUrl: String
    let onCookie: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        SheetWebView(serverUrl: serverUrl, onCookie: onCookie, onCancel: onCancel)
            .navigationTitle("Connexion SSO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer", action: onCancel)
                }
            }
    }
}

struct SheetWebView: UIViewRepresentable {
    let serverUrl: String
    let onCookie: (String, String) -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        let base = try? BullarrApi.normalizeBaseUrl(serverUrl)
        if let base, let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/login/redirect") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SheetWebView
        var done = false

        init(_ parent: SheetWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !done {
                // Une erreur de ressource annexe ne bloque pas ; on tente de continuer.
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !done else { return }
            parent.onCancel()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            check(webView, navigationAction.request.url?.absoluteString)
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("location.href") { [weak self, weak webView] result, _ in
                guard let webView else { return }
                self?.check(webView, result as? String)
            }
        }

        func check(_ webView: WKWebView, _ urlString: String?) {
            guard !done, let urlString, let url = URL(string: urlString) else { return }
            let base = try? BullarrApi.normalizeBaseUrl(parent.serverUrl)
            guard let base else { return }
            let path = url.path
            // Même hôte seulement : l'utilisateur peut avoir saisi http:// alors que le serveur
            // redirige vers https (reverse proxy), donc ni le schéma ni le port ne comptent.
            if url.host == base.host && !path.hasPrefix("/login") && path != "/callback" {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] (cookies: [HTTPCookie]) in
                    guard let self, !self.done else { return }
                    let joined = cookies.filter { url.host == nil || url.host?.hasSuffix($0.domain) == true || $0.domain.hasSuffix(url.host ?? "") }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    if !joined.isBlank {
                        self.done = true
                        let port = url.port.map { ":\($0)" } ?? ""
                        DispatchQueue.main.async {
                            self.parent.onCookie(joined, "\(url.scheme ?? "http")://\(url.host ?? "")\(port)")
                        }
                    }
                }
            }
        }
    }
}

// --- Avatar -------------------------------------------------------------------

/// Avatar rond d'un compte ; icône neutre tant que l'image n'est pas chargée (ou sans avatar).
struct AvatarView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi?
    let url: String?
    var size: CGFloat = 40

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person")
                    .font(.system(size: size * 0.6))
                    .foregroundColor(cs.muted)
            }
        }
        .frame(width: size, height: size)
        .background(cs.alt)
        .clipShape(Circle())
        .task(id: "\(url ?? "")@\(Int(size))") {
            guard let api, let url else { return }
            if let bytes = try? await api.getBytes(url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), image == nil {
                image = UIImage(data: bytes) // SVG non géré par UIImage : icône neutre à la place.
            }
        }
    }
}

// --- Dialogues d'envoi ----------------------------------------------------------

/// Boîte de dialogue modale maison (le style Material d'Android, adapté à iOS).
struct BullDialog<Content: View, Buttons: View>: View {
    @Environment(\.bullColors) private var cs
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { }
            VStack(alignment: .leading, spacing: 16) {
                content
                HStack(spacing: 8) {
                    Spacer()
                    buttons
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 22).fill(cs.surface))
            .foregroundColor(cs.text)
            .padding(.horizontal, 32)
        }
    }
}

struct DownloadDialogsView: View {
    @EnvironmentObject private var downloads: DownloadController
    @Environment(\.bullColors) private var cs

    var body: some View {
        Group {
            if let item = downloads.quick {
                BullDialog(content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.seriesId == nil ? "Ajouter la série et télécharger ?" : "Télécharger ?").font(.headline)
                        Text(item.seriesTitle).fontWeight(.semibold)
                        Text(item.title).font(.footnote).foregroundColor(.secondary)
                        if item.seriesId == nil {
                            Text("La série sera créée depuis Bédéthèque, ou envoyée en validation si aucune fiche ne correspond.").font(.footnote)
                        }
                        let toSend = item.type == .ebdz ? item.files.filter { !$0.owned }.count : 1
                        Text(toSend > 1 ? "\(toSend) fichiers seront envoyés." : "Le fichier sera envoyé au client de téléchargement.").font(.footnote)
                    }
                }, buttons: {
                    Button("Annuler", role: .cancel) { downloads.quick = nil }
                    Button("Lancer") { downloads.runQuick() }
                })
            }
            if let choices = downloads.choices {
                BullDialog(content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(choices.title).font(.headline)
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(choices.jobs.enumerated()), id: \.offset) { _, pair in
                                    let job = pair.job
                                    let note = pair.note
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(job.name).font(.subheadline)
                                            let sentTo = downloads.sent[job.key]
                                            let line = [note, sentTo.map { "Envoyé à \($0)" }].compactMap { $0 }.joined(separator: " · ")
                                            if !line.isEmpty { Text(line).font(.caption).foregroundColor(.secondary) }
                                        }
                                        Spacer()
                                        Button {
                                            downloads.request(job)
                                        } label: {
                                            Image(systemName: "arrow.down.circle")
                                                .font(.title3)
                                                .foregroundColor(cs.accent)
                                        }
                                        .disabled(downloads.sent[job.key] != nil)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                    }
                }, buttons: {
                    Button("Fermer") { downloads.choices = nil }
                })
            }
            if let p = downloads.pending {
                BullDialog(content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Télécharger ?").font(.headline)
                        Text(p.job.name).fontWeight(.semibold)
                        if let ctx = p.context { Text(ctx).font(.footnote) }
                        if let w = p.warning { Text(w).font(.footnote).foregroundColor(cs.tertiary) }
                        if p.replace {
                            Text("Cet album existe déjà dans Bullarr : son fichier sera remplacé.").font(.footnote).foregroundColor(cs.error)
                        }
                        if p.clients.count > 1 {
                            Text("Client :").font(.footnote).foregroundColor(.secondary)
                            Picker("Client", selection: Binding(
                                get: { p.chosen ?? downloads.pending?.chosen ?? p.clients[0] },
                                set: { downloads.pending?.chosen = $0 }
                            )) {
                                ForEach(p.clients, id: \.key) { c in Text(c.label).tag(c) }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            Text("Client : \(p.clients.first?.label ?? "").").font(.footnote)
                        }
                    }
                }, buttons: {
                    Button("Annuler", role: .cancel) { downloads.pending = nil }
                    Button("Télécharger") { downloads.confirm() }
                })
            }
        }
    }
}
