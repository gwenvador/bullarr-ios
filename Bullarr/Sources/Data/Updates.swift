import Foundation

/// Release publiée sur GitHub (pièce jointe d'une release nommée bullarr-ios-<version>.ipa).
struct AppRelease: Hashable {
    let version: String
    let url: String
    let sizeBytes: Int64?
    let publishedAt: String?
    let page: String?
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(AppRelease?)
    case available(AppRelease)
    case failed(String)
}

/**
 * Cherche la dernière version de l'app iOS dans les releases GitHub de bullarr-ios
 * (API publique, sans clé) : l'IPA jointe se nomme bullarr-ios-<version>.ipa.
 */
enum UpdateChecker {
    static let repos = ["gwenvador/bullarr-ios"]
    static let assetPattern = try! NSRegularExpression(pattern: "^bullarr-ios-(\\d+(?:\\.\\d+)*)\\.ipa$")

    static func latest() async throws -> AppRelease? {
        var best: AppRelease?
        var firstError: Error?
        var answered = false
        for repo in repos {
            do {
                for r in try await fetch(repo) {
                    if best == nil || compareVersions(r.version, best!.version) > 0 { best = r }
                }
                answered = true
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !answered { throw firstError ?? ApiException("GitHub n'a répondu pour aucun dépôt.") }
        return best
    }

    private static func fetch(_ repo: String) async throws -> [AppRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await BullarrApi.sharedClient.data(for: req)
        } catch {
            throw ApiException("GitHub injoignable : \(readable(error)). Vérifiez la connexion internet.")
        }
        guard let http = resp as? HTTPURLResponse else { throw ApiException("GitHub a répondu une réponse illisible.") }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw ApiException("GitHub limite les requêtes (HTTP \(http.statusCode)) : réessayez dans quelques minutes.")
        }
        if http.statusCode == 404 { throw ApiException("Dépôt GitHub \(repo) introuvable ou privé (HTTP 404).") }
        guard (200..<300).contains(http.statusCode) else { throw ApiException("GitHub a répondu HTTP \(http.statusCode) pour \(repo).") }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ApiException("Réponse GitHub illisible.")
        }
        var out: [AppRelease] = []
        for el in arr {
            guard let r = el as? JSONDict else { continue }
            if r.bool("draft") == true || r.bool("prerelease") == true { continue }
            for a in r.objects("assets") {
                guard let name = a.str("name"), let m = assetPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { continue }
                let version = String(name[Range(m.range(at: 1), in: name)!])
                out.append(AppRelease(
                    version: version,
                    url: a.str("browser_download_url") ?? "",
                    sizeBytes: { let s = a.long("size") ?? 0; return s > 0 ? s : nil }(),
                    publishedAt: r.str("published_at"),
                    page: r.str("html_url"),
                ))
            }
        }
        return out
    }
}

/// Compare « 1.10 » et « 1.2 » numériquement, segment par segment.
func compareVersions(_ a: String, _ b: String) -> Int {
    let x = a.dropPrefix("v").split(separator: ".").map { Int($0) ?? 0 }
    let y = b.dropPrefix("v").split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let c = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
        if c != 0 { return c }
    }
    return 0
}

extension String {
    func dropPrefix(_ p: String) -> String { hasPrefix(p) ? String(dropFirst(p.count)) : self }
}
