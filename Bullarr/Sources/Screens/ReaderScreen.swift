import SwiftUI
import UIKit

// Lecteur plein écran : pages (glissement horizontal, double page en paysage), mode webtoon
// (défilement vertical continu), sens manga (droite → gauche), zoom par pincement, reprise et
// envoi de l'avancement (Komga via Bullarr), tomes voisins, miniatures et curseur.
// (Pas d'upscaling sur iOS pour l'instant : écran dédié côté Android seulement.)

struct ReaderScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let target: ReaderTarget

    @State private var meta: ReaderMeta? = nil
    @State private var error: String? = nil
    @State private var attempt = 0
    /// Tomes voisins de la série (possédés) : le précédent à la première page, le suivant à la dernière.
    @State private var neighbours: (ReaderTarget?, ReaderTarget?) = (nil, nil)

    var body: some View {
        Group {
            if let m = meta {
                ReaderView(
                    api: state.api ?? ReaderScreen.dummyApi,
                    offline: state.offline.store,
                    progress: state.reads,
                    meta: m,
                    manga: state.series.first { $0.id == m.seriesId }?.origin == "Asie",
                    prev: neighbours.0, next: neighbours.1,
                    onOpen: { state.reading = $0 },
                    onClose: { dismiss() }
                )
                .id(m.volumeId) // Une clé par tome : passer au suivant repart d'un lecteur neuf.
            } else {
                VStack(spacing: 16) {
                    if let error {
                        Text(error).foregroundColor(.white).multilineTextAlignment(.center)
                        HStack(spacing: 24) {
                            Button("Réessayer") { attempt += 1 }.foregroundColor(.white)
                            Button("Fermer") { dismiss() }.foregroundColor(.white)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task(id: target.volumeId) { await loadMeta() }
        .task(id: meta?.seriesId) { await loadNeighbours() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Débogage : `--bullarr-landscape` force la rotation du simulateur pour tester le lecteur.
            if ProcessInfo.processInfo.arguments.contains("--bullarr-landscape") {
                let set = { UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation") }
                set()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { set(); UIViewController.attemptRotationToDeviceOrientation() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { set(); UIViewController.attemptRotationToDeviceOrientation() }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // La mémoire des pages est rendue à la fermeture.
            PageCache.shared.clear()
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
    }

    /// Un client factice suffit hors connexion : les albums copiés sont lus sans réseau.
    static let dummyApi = try! BullarrApi("http://localhost/", apiKey: "")

    /// Copie hors ligne : le lecteur démarre sans réseau. En ligne, l'avancement Komga du serveur
    /// est repris même pour une copie hors ligne (3 s d'attente au plus).
    private func loadMeta() async {
        let store = state.offline.store
        let online = state.api != nil
        let api = state.api ?? ReaderScreen.dummyApi
        error = nil
        do {
            let stored = store.metaOf(target.volumeId)
            if stored == nil {
                meta = try parseReaderMeta(target.volumeId, try await api.getObject("api/volumes/\(target.volumeId)/reader"))
            } else if !online {
                meta = stored
            } else {
                do {
                    let fresh = try parseReaderMeta(target.volumeId, try await withTimeout(3) {
                        try await api.getObject("api/volumes/\(target.volumeId)/reader")
                    })
                    meta = ReaderMeta(
                        volumeId: stored!.volumeId, seriesTitle: stored!.seriesTitle, label: stored!.label,
                        title: stored!.title, pageCount: stored!.pageCount, seriesId: stored!.seriesId,
                        resumePage: fresh.resumePage, readCompleted: fresh.readCompleted
                    )
                } catch {
                    // Serveur injoignable : on garde la copie hors ligne.
                    meta = stored
                }
            }
        } catch {
            self.error = readable(error)
        }
    }

    private func loadNeighbours() async {
        guard let m = meta, let sid = m.seriesId else { neighbours = (nil, nil); return }
        let store = state.offline.store
        let online = state.api != nil
        let api = state.api
        if online, let api {
            do {
                let d = parseSeriesDetail(try await api.getObject("api/series/\(sid)"))
                let owned = d.volumes.filter { $0.owned }
                let i = owned.firstIndex { $0.id == m.volumeId }
                func at(_ j: Int) -> ReaderTarget? {
                    guard let i, owned.indices.contains(j) else { return nil }
                    return ReaderTarget(volumeId: owned[j].id, title: "\(d.title) · \(owned[j].label)")
                }
                neighbours = (i.flatMap { at($0 - 1) }, i.flatMap { at($0 + 1) })
            } catch {
                neighbours = offlineNeighbours(store, sid, m)
            }
        } else {
            neighbours = offlineNeighbours(store, sid, m)
        }
    }

    /// Sans réseau : les tomes voisins parmi les albums copiés sur le téléphone.
    private func offlineNeighbours(_ store: OfflineStore, _ sid: Int, _ m: ReaderMeta) -> (ReaderTarget?, ReaderTarget?) {
        let copies = store.list().map { $0.meta }.filter { $0.seriesId == sid }
            .sorted {
                let a = $0.label?.firstMatch("\\d+").flatMap { Int($0) } ?? Int.max
                let b = $1.label?.firstMatch("\\d+").flatMap { Int($0) } ?? Int.max
                return a < b
            }
        let i = copies.firstIndex { $0.volumeId == m.volumeId }
        func at(_ j: Int) -> ReaderTarget? {
            guard let i, copies.indices.contains(j) else { return nil }
            let c = copies[j]
            return ReaderTarget(volumeId: c.volumeId, title: [c.seriesTitle, c.label].compactMap { $0 }.joined(separator: " · "))
        }
        return (i.flatMap { at($0 - 1) }, i.flatMap { at($0 + 1) })
    }
}

/// `withTimeout` minimal : la première tâche terminée gagne, les autres sont annulées.
private func withTimeout<T>(_ seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ApiException("Délai dépassé.")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

extension String {
    /// Premier groupe de chiffres (pour trier les albums d'une série hors ligne).
    func firstMatch(_ pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = r.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        return range.flatMap { Range($0.range, in: self).map { String(self[$0]) } }
    }
}

// MARK: - Le lecteur

/// Couverture seule, puis les pages deux par deux (2-3, 4-5…), comme un album ouvert.
private func spreadsOf(_ total: Int, _ double: Bool) -> [[Int]] {
    if !double || total < 3 { return (0..<total).map { [$0] } }
    var out: [[Int]] = [[0]]
    var i = 1
    while i < total {
        var pair = [i]
        if i + 1 < total { pair.append(i + 1) }
        out.append(pair)
        i += 2
    }
    return out
}

private struct ReaderView: View {
    let api: BullarrApi
    let offline: OfflineStore
    let progress: ReadingProgress
    let meta: ReaderMeta
    let manga: Bool
    let prev: ReaderTarget?
    let next: ReaderTarget?
    let onOpen: (ReaderTarget) -> Void
    let onClose: () -> Void

    @Environment(\.verticalSizeClass) private var verticalClass

    @State private var bars = true
    @State private var zoomed = false
    @State private var sliderPos: Double? = nil
    @State private var fitWidth = false
    @State private var webtoon = false
    @State private var rtl = false
    @State private var doublePref = false
    @State private var jumpRequest: Int? = nil
    /// Page courante (0-based) et fin d'album, tenus à jour par les vues de pages.
    @State private var current = 0
    @State private var atEnd = false
    /// Vrai une fois la page de départ posée : un lecteur recréé (passage en double page à la
    /// rotation) repart alors de la page courante, pas de la page de reprise de l'ouverture.
    @State private var started = false
    /// Taille de la zone de lecture, pour les zones d'appui.
    @State private var viewSize: CGSize = .zero

    var body: some View {
        let total = meta.pageCount
        Group {
            if total <= 0 {
                VStack(spacing: 12) {
                    Text("Ce tome n'a aucune page lisible.").foregroundColor(.white)
                    Button("Fermer") { onClose() }.foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(total: total)
                    .overlay(alignment: .top) { topBar }
                    .overlay(alignment: .bottom) { bottomBar(total: total) }
                    .overlay(alignment: .bottom) { endOverlay(total: total) }
                    .overlay(alignment: .top) { pageNotices }
            }
        }
        .background(Color.black)
        .onAppear {
            fitWidth = progress.fitWidth
            // Débogage : `--bullarr-fitwidth` force le mode pleine largeur (simulateur).
            if ProcessInfo.processInfo.arguments.contains("--bullarr-fitwidth") { fitWidth = true }
            webtoon = progress.webtoon
            rtl = progress.rtl(meta.seriesId, manga)
            doublePref = progress.doublePage
            current = startPage(total: total)
            started = true
            scheduleBarsHide()
        }
        .onChange(of: current) { _ in saveProgress(total: total) }
        .onChange(of: atEnd) { _ in saveProgress(total: total) }
        .task(id: current) { await reportKomgaProgress(total: total) }
        .task(id: current) { await preload(around: current, total: total) }
    }

    /// Komga d'abord (synchronisé avec le site et les autres lecteurs), sinon la page mémorisée sur l'appareil.
    private func startPage(total: Int) -> Int {
        let p: Int
        if meta.readCompleted { p = 0 }
        else if let resume = meta.resumePage { p = resume - 1 }
        else { p = progress.get(meta.volumeId) ?? 0 }
        return min(max(0, p), total - 1)
    }

    @ViewBuilder
    private func content(total: Int) -> some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height || ProcessInfo.processInfo.arguments.contains("--bullarr-double")
            let double = landscape && doublePref && !webtoon
            let spreads = spreadsOf(total, double)
            // Zone de pages en plein écran : le centrage et le pli double-page restent symétriques par
            // rapport aux bords physiques (les safe-area asymétriques en paysage décalaient les images).
            GeometryReader { full in
                ZStack {
                    Color.black
                    if webtoon {
                        WebtoonContent(
                            api: api, offline: offline, volumeId: meta.volumeId, total: total,
                            current: $current, atEnd: $atEnd, jumpRequest: $jumpRequest,
                            zoomed: $zoomed
                        )
                    } else {
                        PagedContent(
                            api: api, offline: offline, volumeId: meta.volumeId,
                            spreads: spreads, start: started ? current : startPage(total: total),
                            fitWidth: fitWidth && !double, rtl: rtl,
                            current: $current, atEnd: $atEnd, zoomed: $zoomed, jumpRequest: $jumpRequest
                        )
                        // Recréé quand on passe d'une à deux pages (l'ancien découpage ne doit plus servir) et à
                        // chaque changement de taille (rotation) : la ScrollView horizontale garderait sinon son
                        // décalage en points (page × ancienne largeur) et s'arrêterait à cheval sur deux pages.
                        // Le lecteur neuf repart de la page courante (`started`), sans zoom.
                        .id(PagerKey(double: double, width: Int(full.size.width.rounded()), height: Int(full.size.height.rounded())))
                    }
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    let x = value.location.x / full.size.width
                    if x < 0.3 {
                        go(if: rtl ? +1 : -1, total: total)
                    } else if x > 0.7 {
                        go(if: rtl ? -1 : +1, total: total)
                    } else {
                        withAnimation { bars.toggle() }
                        scheduleBarsHide()
                    }
                })
                .onChange(of: full.size) { viewSize = $0 }
                .onAppear { viewSize = full.size }
            }
            .ignoresSafeArea()
        }
    }

    // --- Déplacement -------------------------------------------------------------

    private func go(if delta: Int, total: Int) {
        let isLast = webtoon ? current == total - 1 : atEnd
        if delta > 0 && isLast { next.map(onOpen); return }
        if delta < 0 && current == 0 { prev.map(onOpen); return }
        jumpRequest = min(max(0, current + delta), total - 1)
    }

    private func bumpBars() {
        withAnimation { bars = true }
        scheduleBarsHide()
    }

    /// Barres masquées après quelques secondes.
    private func scheduleBarsHide() {
        // Débogage : `--bullarr-bars` garde les barres visibles (simulateur).
        if ProcessInfo.processInfo.arguments.contains("--bullarr-bars") { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { withAnimation { bars = false } }
        }
    }

    // --- Progression --------------------------------------------------------------

    /// Mémorise la page (et l'album pour « Continuer la lecture ») ; un album fini repart du début.
    private func saveProgress(total: Int) {
        progress.save(meta.volumeId, atEnd ? total - 1 : current, total, meta: meta)
    }

    /// Envoie la page lue à Bullarr, qui la transmet à Komga (sans effet si Komga n'est pas relié).
    private func reportKomgaProgress(total: Int) async {
        guard state_isOnline else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { return }
        let body: JSONDict = ["page": atEnd ? total : current + 1, "completed": atEnd]
        _ = try? await api.postObject("api/volumes/\(meta.volumeId)/reader/progress", body)
    }

    private var state_isOnline: Bool { api !== ReaderScreen.dummyApi }

    /// Précharge d'abord la page courante, puis les suivantes (et la précédente pour revenir).
    private func preload(around page: Int, total: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for i in [page, page + 1, page + 2, page + 3, page - 1] where i >= 0 && i < total {
                group.addTask {
                    _ = try? await PageCache.shared.get(api, meta.volumeId, i + 1, offline: offline)
                }
            }
            await group.waitForAll()
        }
    }

    // --- Barre du haut -----------------------------------------------------------

    private var landscape: Bool { verticalClass == .compact }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Fermer le lecteur")
            VStack(alignment: .leading, spacing: 0) {
                Text(meta.seriesTitle ?? meta.title ?? "")
                    .font(.subheadline).foregroundColor(.white).lineLimit(1)
                let sub = [meta.label, meta.title != meta.seriesTitle ? meta.title : nil].compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer()
            // Sens de lecture : gauche → droite ou manga (droite → gauche), mémorisé pour la série.
            if !webtoon {
                Button {
                    rtl.toggle()
                    progress.setRtl(meta.seriesId, rtl)
                    bumpBars()
                } label: {
                    Text(rtl ? "D→G" : "G→D")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(minWidth: 36, minHeight: 36)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityLabel(rtl ? "Sens manga (droite → gauche)" : "Sens de lecture gauche → droite")
            }
            // Double page en paysage.
            if landscape && !webtoon {
                Button {
                    doublePref.toggle()
                    progress.doublePage = doublePref
                    zoomed = false
                    bumpBars()
                } label: {
                    Text("2×")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(doublePref ? 1 : 0.45))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Deux pages côte à côte")
            }
            // Pages ↔ webtoon (lecture en défilement vertical continu) : le libellé est le mode qu'on va prendre.
            Button {
                webtoon.toggle()
                progress.webtoon = webtoon
                zoomed = false
                bumpBars()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: webtoon ? "rectangle.split.2x2" : "arrow.up.and.down")
                        .foregroundColor(.white)
                    Text(webtoon ? "Pages" : "Webtoon")
                        .font(.caption.weight(.medium)).foregroundColor(.white)
                }
            }
            // Page entière ↔ pleine largeur (on fait défiler la page vers le bas).
            if !webtoon && !doublePref {
                Button {
                    fitWidth.toggle()
                    progress.fitWidth = fitWidth
                    bumpBars()
                } label: {
                    Image(systemName: fitWidth ? "rectangle.compress.vertical" : "arrow.up.and.down.text.horizontal")
                        .foregroundColor(.white).frame(width: 36, height: 36)
                }
                .accessibilityLabel(fitWidth ? "Page entière" : "Pleine largeur")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.7))
        .opacity(bars ? 1 : 0)
        .allowsHitTesting(bars)
        .onTapGesture { bumpBars() }
    }

    // --- Barre du bas ------------------------------------------------------------

    private func bottomBar(total: Int) -> some View {
        VStack(spacing: 8) {
            ThumbnailsRow(
                api: api, offline: offline, volumeId: meta.volumeId, total: total,
                current: sliderPos.map { Int($0) - 1 } ?? current
            ) { to in
                bumpBars()
                jumpRequest = to
            }
            Text("\(sliderPos.map { Int($0) } ?? (current + 1)) / \(total)")
                .font(.headline).foregroundColor(.white)
            if total > 1 {
                Slider(
                    value: Binding(
                        get: { sliderPos ?? Double(current + 1) },
                        set: { sliderPos = $0; bumpBars() }
                    ),
                    in: 1...Double(total),
                    onEditingChanged: { editing in
                        if !editing {
                            let to = (sliderPos.map { Int($0) } ?? current + 1) - 1
                            sliderPos = nil
                            bumpBars()
                            jumpRequest = to
                        }
                    }
                )
                .environment(\.layoutDirection, rtl && !webtoon ? .rightToLeft : .leftToRight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.7))
        .opacity(bars ? 1 : 0)
        .allowsHitTesting(bars)
        .onTapGesture { bumpBars() }
    }

    // --- Encarts -------------------------------------------------------------------

    /// Première page : retour au tome précédent ; dernière page : « Fin de l'album » avec le tome suivant.
    @ViewBuilder
    private func endOverlay(total: Int) -> some View {
        if current == 0 && prev != nil && !atEnd {
            Button {
                prev.map(onOpen)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text("Tome précédent : \(prev?.title.components(separatedBy: " · ").last ?? "")")
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            }
            .padding(.bottom, 60)
            .transition(.opacity)
        } else if atEnd {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").foregroundColor(.white)
                    Text("Fin de l'album").font(.headline).foregroundColor(.white)
                }
                Text(next != nil
                     ? "Marqué comme lu."
                     : "Marqué comme lu. Pas d'autre tome possédé à suivre dans cette série.")
                    .font(.caption).foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Button("Fermer") { onClose() }.foregroundColor(.white)
                    if let next {
                        Button {
                            onOpen(next)
                        } label: {
                            HStack(spacing: 8) {
                                Text("Tome suivant : \(next.title.components(separatedBy: " · ").last ?? "")").lineLimit(1)
                                Image(systemName: "chevron.right")
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white.opacity(0.2)))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.82)))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    /// (Pas d'indicateur d'upscaling sur iOS : la fonction n'y est pas portée.)
    @ViewBuilder
    private var pageNotices: some View { EmptyView() }
}

// MARK: - Pages (mode pager)

/// Une vue du lecteur : une page, ou deux côte à côte (paysage). Zoom par pincement (jusqu'à ×5)
/// puis déplacement ; erreur lisible avec réessai.
/// Espace de coordonnées de la ScrollView d'une page (pleine largeur), pour la sonde de défilement.
private let PageScrollSpace = "bullarr.page.scroll"

/// Position instantanée d'une page dans sa ScrollView : minY (négatif quand on a défilé) et hauteur.
private struct PageScrollProbe: Equatable {
    let page: Int
    let minY: CGFloat
    let height: CGFloat
}

private struct PageScrollProbeKey: PreferenceKey {
    static var defaultValue: [PageScrollProbe] = []
    static func reduce(value: inout [PageScrollProbe], nextValue: () -> [PageScrollProbe]) {
        value.append(contentsOf: nextValue())
    }
}

/// Identité du pager : un nouveau lecteur de pages à chaque découpage (simple/double) ou taille d'écran.
private struct PagerKey: Hashable {
    let double: Bool
    let width: Int
    let height: Int
}

private struct PagedContent: View {
    let api: BullarrApi
    let offline: OfflineStore
    let volumeId: Int
    let spreads: [[Int]]
    let start: Int
    let fitWidth: Bool
    let rtl: Bool
    @Binding var current: Int
    @Binding var atEnd: Bool
    @Binding var zoomed: Bool
    @Binding var jumpRequest: Int?

    /// Sens manga : les pages sont posées de droite à gauche (le tome suivant vient de la gauche).
    private func displayIndex(of spread: Int) -> Int { rtl ? spreads.count - 1 - spread : spread }
    private func spreadIndex(of display: Int) -> Int { rtl ? spreads.count - 1 - display : display }
    private func spreadOf(page: Int) -> Int {
        spreads.firstIndex { $0.contains(page) } ?? 0
    }

    @State private var displayPosition: Int? = nil
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var viewW: CGFloat = 1
    @State private var viewH: CGFloat = 1
    /// Fraction de défilement par page (pleine largeur), pour retrouver la position après une rotation.
    @State private var scrollFracs: [Int: CGFloat] = [:]

    var body: some View {
        GeometryReader { geo in
            let ordered = rtl ? spreads.reversed().map { $0 } : spreads
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { j, pages in
                        spreadView(pages: pages, geo: geo)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(j)
                    }
                }
                // Zoom : la transformation visuelle ne touche pas au découpage des pages.
                .scaleEffect(scale)
                .offset(offset)
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $displayPosition)
            .scrollDisabled(zoomed)
            .onAppear {
                viewW = geo.size.width
                viewH = geo.size.height
                if displayPosition == nil {
                    displayPosition = displayIndex(of: spreadOf(page: start))
                }
            }
            .onChange(of: geo.size) { s in
                viewW = s.width
                viewH = s.height
            }
            .onChange(of: displayPosition) { d in
                guard let d, spreads.indices.contains(spreadIndex(of: d)) else { return }
                let s = spreads[spreadIndex(of: d)]
                current = s.first ?? 0
                atEnd = (s.last ?? -1) == spreads.last?.last
            }
            .onChange(of: jumpRequest) { p in
                guard let p else { return }
                jumpRequest = nil
                withAnimation {
                    displayPosition = displayIndex(of: spreadOf(page: p))
                }
                scale = 1
                offset = .zero
                zoomed = false
            }
            // Zoom : pincement, puis déplacement ; la page se resserre quand on repasse sous ×1.
            .simultaneousGesture(magnification)
            .gesture(zoomed ? pan : nil)
        }
    }

    @ViewBuilder
    private func spreadView(pages: [Int], geo: GeometryProxy) -> some View {
        if pages.count > 1 {
            HStack(spacing: 0) {
                // Double page : chaque moitié colle sa page au pli (bord intérieur), comme un album ouvert.
                half(pages[0], geo: geo, fold: Alignment(horizontal: .trailing, vertical: .center))
                half(pages[1], geo: geo, fold: Alignment(horizontal: .leading, vertical: .center))
            }
        } else {
            single(pages[0], geo: geo)
        }
    }

    private func half(_ page: Int, geo: GeometryProxy, fold: Alignment) -> some View {
        ReaderPageView(api: api, offline: offline, volumeId: volumeId, page: page + 1) { img, w, h in
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        }
        .frame(width: geo.size.width / 2, height: geo.size.height, alignment: fold)
    }

    @ViewBuilder
    private func single(_ page: Int, geo: GeometryProxy) -> some View {
        if fitWidth {
            // Pleine largeur : la page tient en hauteur → centrée ; sinon on la fait défiler.
            ReaderPageView(api: api, offline: offline, volumeId: volumeId, page: page + 1) { img, w, h in
                let vh = geo.size.height
                if w == 0 || h * geo.size.width / w <= vh {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: vh)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width)
                                .id(page)
                                .background(scrollProbe(page: page))
                        }
                        .coordinateSpace(name: PageScrollSpace)
                        .onPreferenceChange(PageScrollProbeKey.self) { probes in
                            for p in probes {
                                let maxScroll = p.height - vh
                                if maxScroll > 1 {
                                    scrollFracs[p.page] = min(max(0, -p.minY / maxScroll), 1)
                                }
                            }
                        }
                        // Rotation : la page est reposée à la même fraction de défilement qu'avant.
                        .onChange(of: geo.size) { _ in
                            let f = scrollFracs[page] ?? 0
                            DispatchQueue.main.async {
                                proxy.scrollTo(page, anchor: UnitPoint(x: 0.5, y: f))
                            }
                        }
                    }
                }
            }
        } else {
            ReaderPageView(api: api, offline: offline, volumeId: volumeId, page: page + 1) { img, w, h in
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Sonde de défilement : mesure la position de la page dans sa ScrollView (pleine largeur).
    private func scrollProbe(page: Int) -> some View {
        GeometryReader { g in
            Color.clear.preference(
                key: PageScrollProbeKey.self,
                value: [PageScrollProbe(page: page, minY: g.frame(in: .named(PageScrollSpace)).minY, height: g.size.height)]
            )
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                let s = min(max(1, scale * v), 5)
                scale = s < 1.03 ? 1 : s
                zoomed = scale > 1.01
                clampOffset()
            }
            .onEnded { _ in
                if scale <= 1.01 { scale = 1; offset = .zero; zoomed = false }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                offset = CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height)
                clampOffset()
            }
            .onEnded { _ in clampOffset() }
    }

    private func clampOffset() {
        guard scale > 1 else { offset = .zero; return }
        let maxX = viewW * (scale - 1) / 2
        let maxY = viewH * (scale - 1) / 2
        offset = CGSize(width: min(max(-maxX, offset.width), maxX), height: min(max(-maxY, offset.height), maxY))
    }
}

// MARK: - Webtoon

/// Webtoon : pages à la largeur de l'écran, collées les unes aux autres, on fait défiler.
private struct WebtoonContent: View {
    let api: BullarrApi
    let offline: OfflineStore
    let volumeId: Int
    let total: Int
    @Binding var current: Int
    @Binding var atEnd: Bool
    @Binding var jumpRequest: Int?
    @Binding var zoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var offsetX: CGFloat = 0
    @State private var frames: [Int: CGRect] = [:]
    @State private var viewport: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<total, id: \.self) { i in
                            page(i)
                        }
                    }
                    .scaleEffect(scale, anchor: .top)
                    .offset(x: offsetX)
                }
                .coordinateSpace(name: "wt")
                .onAppear { viewport = geo.size }
                .onChange(of: geo.size) { viewport = $0 }
                .onPreferenceChange(PageFramesKey.self) { frames = $0 }
                .onChange(of: frames) { updateCurrent() }
                .simultaneousGesture(magnification)
                .gesture(scale > 1.01 ? pan : nil)
                .onChange(of: jumpRequest) { p in
                    guard let p else { return }
                    jumpRequest = nil
                    scale = 1
                    offsetX = 0
                    zoomed = false
                    withAnimation { proxy.scrollTo(p, anchor: .top) }
                }
            }
        }
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        WebtoonPageView(api: api, offline: offline, volumeId: volumeId, page: index + 1, width: viewport.width)
            .background(
                GeometryReader { inner in
                    Color.clear.preference(
                        key: PageFramesKey.self,
                        value: [index: inner.frame(in: .named("wt"))]
                    )
                }
            )
            .frame(width: viewport.width)
            .id(index)
    }

    private func updateCurrent() {
        guard viewport.height > 0 else { return }
        // Offset de défilement : la position du premier cadre dans l'espace nommé.
        let minY = frames.values.map { $0.minY }.min() ?? 0
        let scrollOffset = -minY
        let mid = scrollOffset + viewport.height / 2
        // La page courante est celle qui occupe le milieu de l'écran (la dernière une fois en bas).
        let visible = frames.filter { $0.value.minY <= mid && $0.value.maxY > mid }.keys
        if visible.contains(total - 1) {
            current = total - 1
            atEnd = true
        } else if let idx = visible.min() {
            current = idx
            atEnd = false
        } else if let last = frames.map({ $0.key }).max(), frames[last]!.maxY <= mid {
            current = total - 1
            atEnd = true
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                let s = min(max(1, scale * v), 4)
                scale = s < 1.03 ? 1 : s
                zoomed = scale > 1.01
                if scale == 1 { offsetX = 0 } else { clampX() }
            }
            .onEnded { _ in if scale <= 1.01 { scale = 1; offsetX = 0; zoomed = false } }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                offsetX += v.translation.width
                clampX()
            }
            .onEnded { _ in clampX() }
    }

    private func clampX() {
        let maxX = viewport.width * (scale - 1) / 2
        offsetX = min(max(-maxX, offsetX), maxX)
    }
}

/// Cadres des pages webtoon dans l'espace de défilement.
private struct PageFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Chargement des pages

/// Chargement d'une page : bitmap en cache, sinon téléchargée ; erreur lisible avec réessai.
private struct ReaderPageView<Content: View>: View {
    let api: BullarrApi
    let offline: OfflineStore
    let volumeId: Int
    /// Numéro 1-based, comme l'API.
    let page: Int
    @ViewBuilder let content: (UIImage, CGFloat, CGFloat) -> Content

    @State private var image: UIImage? = nil
    @State private var error: String? = nil
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let img = image {
                content(img, img.size.width, img.size.height)
            } else if let error {
                PageError(message: error) { attempt += 1 }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: "\(volumeId):\(page):\(attempt)") {
            if image != nil { return }
            error = nil
            do {
                image = try await PageCache.shared.get(api, volumeId, page, offline: offline)
            } catch {
                self.error = "Page \(page) : \(readable(error))"
            }
        }
    }
}

/// Page du mode webtoon : pleine largeur, hauteur selon l'image (une hauteur provisoire pendant le chargement).
private struct WebtoonPageView: View {
    let api: BullarrApi
    let offline: OfflineStore
    let volumeId: Int
    let page: Int
    let width: CGFloat

    @State private var image: UIImage? = nil
    @State private var error: String? = nil
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else if let error {
                PageError(message: error) { attempt += 1 }
                    .frame(width: width, height: width / 0.72)
            } else {
                Color.white.opacity(0.06)
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .frame(width: width)
        .task(id: "\(volumeId):\(page):\(attempt)") {
            if image != nil { return }
            error = nil
            do {
                image = try await PageCache.shared.get(api, volumeId, page, offline: offline)
            } catch {
                self.error = "Page \(page) : \(readable(error))"
            }
        }
    }
}

private struct PageError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message).foregroundColor(.white).multilineTextAlignment(.center)
            Button("Réessayer", action: onRetry).foregroundColor(.white)
        }
        .padding(24)
    }
}

// MARK: - Miniatures

/// Bandeau de miniatures : la page courante est cerclée et centrée ; toucher une miniature y saute.
private struct ThumbnailsRow: View {
    let api: BullarrApi
    let offline: OfflineStore
    let volumeId: Int
    let total: Int
    let current: Int
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { index in
                        ThumbnailCell(api: api, offline: offline, volumeId: volumeId, page: index + 1, selected: index == current)
                            .onTapGesture { onPick(index) }
                            .id(index)
                    }
                }
                .padding(.bottom, 4)
            }
            // Hauteur fixe : sinon le ScrollView accepte toute la hauteur proposée par
            // l'overlay (plein écran) et les miniatures se retrouvent centrées au milieu.
            .frame(height: 92)
            .onChange(of: current) { c in
                withAnimation {
                    proxy.scrollTo(c, anchor: .center)
                }
            }
        }
    }
}

private struct ThumbnailCell: View {
    let api: BullarrApi
    let offline: OfflineStore
    let volumeId: Int
    let page: Int
    let selected: Bool

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
            }
            Text("\(page)")
                .font(.caption2)
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .background(Color.black.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: 62, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .task(id: "\(volumeId):\(page)") {
            if image != nil { return }
            image = try? await PageCache.shared.thumb(api, volumeId, page, offline: offline)
        }
    }
}
