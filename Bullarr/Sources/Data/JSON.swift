import Foundation

// Formats relevés dans blueprints/*/routes.py de Bullarr (comme Models.kt côté Android).

typealias JSONDict = [String: Any]
typealias JSONArray = [Any]

extension Dictionary where Key == String, Value == Any {
    /// Valeur de clé chaîne ; null/absent/blank → nil (équivalent de `str()`).
    func str(_ key: String) -> String? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        let s: String
        if let str = v as? String { s = str }
        else if let n = v as? NSNumber { s = n.stringValue }
        else { return nil }
        return s.isBlank ? nil : s
    }

    func int(_ key: String) -> Int? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Double(s).map { Int($0) } }
        return nil
    }

    func long(_ key: String) -> Int64? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Double(s).map { Int64($0) } }
        return nil
    }

    func dbl(_ key: String) -> Double? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func double(_ key: String) -> Double? { dbl(key) }

    /// Booléen SQLite (0/1), JSON ou null.
    func bool(_ key: String) -> Bool? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let s = v as? String {
            if s == "1" { return true }
            if s.caseInsensitiveCompare("true") == .orderedSame { return true }
        }
        return nil
    }

    func dict(_ key: String) -> JSONDict? { (self[key] as? [String: Any]) }
    func array(_ key: String) -> [Any]? { (self[key] as? [Any]) }

    /// Tableau d'objets (équivalent de `optJSONArray(...).objects()`).
    func objects(_ key: String) -> [JSONDict] {
        (array(key) as? [JSONDict]) ?? []
    }

    /// Tableau de chaînes ; absent ou vide → [].
    func strings(_ key: String) -> [String] {
        (array(key) as? [String]) ?? []
    }

    /// Chemin « a.b » dans les objets imbriqués.
    func getPath(_ path: String) -> Any? {
        var cur: Any? = self
        for part in path.split(separator: ".").map(String.init) {
            guard let d = cur as? JSONDict, let v = d[part], !(v is NSNull) else { return nil }
            cur = v
        }
        return cur
    }

    mutating func putPath(_ path: String, _ value: Any?) {
        var parts = path.split(separator: ".").map(String.init)
        let last = parts.removeLast()
        if value == nil { setPathNil(parts, last); return }
        setPath(parts, last, value!)
    }

    private mutating func setPath(_ parts: [String], _ last: String, _ value: Any) {
        if parts.isEmpty { self[last] = value; return }
        var sub = (self[parts[0]] as? JSONDict) ?? [:]
        sub.setPath(Array(parts.dropFirst()), last, value)
        self[parts[0]] = sub
    }

    private mutating func setPathNil(_ parts: [String], _ last: String) {
        if parts.isEmpty { removeValue(forKey: last); return }
        guard var sub = self[parts[0]] as? JSONDict else { return }
        sub.setPathNil(Array(parts.dropFirst()), last)
        self[parts[0]] = sub
    }
}

extension Array where Element == Any {
    func objects() -> [JSONDict] { (self as? [JSONDict]) ?? [] }
    func strings() -> [String] { (self as? [String]) ?? [] }
}

extension Optional where Wrapped == Array<Any> {
    func objects() -> [JSONDict] { self?.objects() ?? [] }
    func strings() -> [String] { self?.strings() ?? [] }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func ifBlank(_ other: String) -> String { isBlank ? other : self }
}

extension Optional where Wrapped == String {
    func ifBlank(_ other: String?) -> String? {
        guard let s = self, !s.isBlank else { return other }
        return s
    }
    var isBlank: Bool { self?.isBlank ?? true }
}

// --- Lecture / écriture JSON (remplace JSONObject / JSONTokener) -------------

enum JSON {
    static func parse(_ text: String) throws -> Any {
        guard !text.isBlank else { return JSONDict() }
        let data = Data(text.utf8)
        let v = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if v is NSNull { return JSONDict() }
        return v
    }

    static func stringify(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension NSNumber {
    /// Booléen SQLite reçu en NSNumber.
    var asBool: Bool { boolValue }
}

/// Minuscules sans accents, pour une recherche tolérante (equivalent de normalize()) :
/// « Sœur.Marie-Thérèse » et « soeur marie therese » se retrouvent (ligatures œ/æ/ß,
/// points, tirets et soulignés = espace).
func normalize(_ s: String) -> String {
    var out = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        .lowercased()
    for (ligature, plain) in [("œ", "oe"), ("æ", "ae"), ("ß", "ss")] {
        out = out.replacingOccurrences(of: ligature, with: plain)
    }
    out = out.replacingOccurrences(of: "[._\\-]+", with: " ", options: .regularExpression)
    return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

/// Libellé d'un tome : Tome 3, Intégrale 2, HS 1, Épisode 4… (même logique que l'interface web).
func volumeLabel(_ o: JSONDict) -> String {
    func n(_ key: String) -> String { (o.str(key) ?? "").replacingOccurrences(of: ".0", with: "") }
    if o.bool("is_integral") == true { return "Intégrale \(n("integral_number"))".trimmed }
    if o.bool("is_hs") == true { return "HS \(n("hs_number"))".trimmed }
    if o.bool("is_episode") == true { return "Épisode \(n("episode_number"))".trimmed }
    if o.bool("is_special") == true { return o.str("special_label") ?? "Spécial" }
    if o.str("volume_number") != nil { return "Tome \(n("volume_number"))\(o.str("bis_suffix") ?? "")" }
    if o.bool("is_oneshot") == true { return "One-shot" }
    return ""
}
