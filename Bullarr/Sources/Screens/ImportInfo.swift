import SwiftUI

// État d'import partagé (ImportScreen.kt) : progression, fichiers en attente, explications.
// Utilisé par l'écran Activité (et par l'écran Import / Enrichir).

/** Détail d'un fichier en attente : série assignée, raison de l'arrêt automatique, taille. */
struct WaitingDetail {
    let seriesId: Int?
    let seriesTitle: String?
    let reason: String?
    let sizeBytes: Int64?
    var filepath: String? = nil
}

func waitingKey(_ trackingId: Int?, _ filename: String) -> String { "\(trackingId ?? -1)|\(filename)" }

/// État de l'import, sondé toutes les 5 s (lecture seule en base, sans scan disque).
@MainActor
final class ImportInfo: ObservableObject {
    @Published var progress: ImportProgress? = nil
    @Published var counts: ImportPendingCount? = nil
    @Published var error: String? = nil
    /// Téléchargements terminés que Bullarr ne peut pas importer seul (dossier d'images en vrac) : id de suivi → explication.
    @Published var blocked: [Int: String] = [:]
    /// Clé « suivi|nom de fichier » (voir waitingKey).
    @Published var waitingDetail: [String: WaitingDetail] = [:]

    private let apiProvider: () -> BullarrApi?

    init(apiProvider: @escaping () -> BullarrApi?) {
        self.apiProvider = apiProvider
    }

    /// Progression + compteurs : rapide (5 s).
    func pollFast() async {
        guard let api = apiProvider() else { return }
        do {
            progress = parseImportProgress(try await api.getObject("api/import/progress"))
            counts = try? await parsePendingCount(api.getObject("api/import/pending-count"))
            error = nil
        } catch {
            self.error = readable(error)
        }
    }

    /// Détail des fichiers suivis + dossiers incompatibles : plus lent (15 s), aussi forcé après « Réessayer ».
    func pollState() async {
        guard let api = apiProvider() else { return }
        do {
            let st = try await api.getObject("api/import/state")
            // Série assignée, raison de l'arrêt automatique et taille de chaque fichier suivi.
            var details: [String: WaitingDetail] = [:]
            for f in st.objects("files") {
                let dest = f.dict("destination")
                details[waitingKey(dest?.int("tracking_id"), f.str("filename") ?? "")] = WaitingDetail(
                    seriesId: dest?.int("series_id"),
                    seriesTitle: dest?.str("series_title"),
                    reason: f.str("auto_import_skip_reason").flatMap { $0.isBlank ? nil : $0 },
                    sizeBytes: f.long("file_size"),
                    filepath: f.str("filepath"),
                )
            }
            waitingDetail = details
            var map: [Int: String] = [:]
            for f in st.objects("incompatible_folders") {
                guard let id = f.int("pack_download_id") else { continue }
                let ext = (f.array("sample_extensions")?.strings() ?? [])
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).uppercased() }
                    .joined(separator: ", ")
                map[id] = "Non importable automatiquement : dossier de \(f.int("file_count") ?? 0) fichier(s)"
                    + (ext.isBlank ? "" : " \(ext)") + " au lieu d'une archive CBZ/CBR/PDF. Sélectionnez-le puis « Importer » pour le convertir en CBZ."
            }
            blocked = map
        } catch {
            // L'état reste celui du dernier sondage ; pas d'erreur bloquante ici.
        }
    }
}

/// Boucle de sondage tant que l'écran est visible (équivalent de Polling d'Android) :
/// le .task qui l'appelle est annulé à la disparition de la vue.
func pollLoop(_ seconds: UInt64, _ block: @escaping () async -> Void) async {
    while !Task.isCancelled {
        await block()
        do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
    }
}

/// Import en cours / fichiers en attente, intégrés en tête de l'Activité.
struct ImportStatusCard: View {
    @Environment(\.bullColors) private var cs
    let info: ImportInfo

    var body: some View {
        if let error = info.error {
            ErrorCard(message: error)
        }
        if let p = info.progress {
            if p.processingFile != nil || !p.claimedFiles.isEmpty || p.paused {
                VStack(alignment: .leading, spacing: 8) {
                    if p.processingFile != nil {
                        Text("Import en cours").font(.headline)
                        Text(p.processingFile ?? "").font(.subheadline)
                        ProgressView().progressViewStyle(.linear)
                        let meta = [
                            formatDuration(p.elapsedSeconds).map { "depuis \($0)" },
                            p.startedAt.map { "démarré le \($0.prefix(16))" },
                        ].compactMap { $0 }.joined(separator: " · ")
                        if !meta.isEmpty {
                            Text(meta).font(.caption).foregroundColor(cs.muted)
                        }
                    } else if !p.claimedFiles.isEmpty {
                        Text("Import en préparation").font(.headline)
                    }
                    if p.paused {
                        TagView(text: "Import arrêté (mis en pause)", container: cs.tertiaryContainer, content: cs.tertiaryOnContainer)
                    }
                    if !p.claimedFiles.isEmpty && p.processingFile == nil {
                        Text("Fichiers réservés par l'import (\(p.claimedFiles.count))").font(.headline).padding(.top, 6)
                        ForEach(p.claimedFiles, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(path.components(separatedBy: "/").last ?? path).font(.subheadline)
                                Text(String(path.components(separatedBy: "/").dropLast().joined(separator: "/")))
                                    .font(.caption).foregroundColor(cs.muted)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(p.processingFile != nil ? cs.accentContainer : cs.surface))
            }
            if let c = info.counts, c.waitingFiles > 0 || c.awaitingDiscovery > 0 {
                Text("\(c.waitingFiles) fichier(s) en attente d'import · \(c.awaitingDiscovery) téléchargement(s) pas encore repéré(s) sur le disque")
                    .font(.subheadline)
                    .foregroundColor(cs.muted)
            }
        }
    }
}
