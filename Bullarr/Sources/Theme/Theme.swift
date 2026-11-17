import SwiftUI

/**
 * Palettes, identiques à celles du site (Configuration → Thème) : fond, surface, surface-alt,
 * bordure, texte, texte atténué, accent, accent survol, en clair puis en sombre.
 */
struct Tones {
    let bg: UInt32, surface: UInt32, alt: UInt32, border: UInt32, text: UInt32, muted: UInt32, accent: UInt32, accentHover: UInt32
}

enum Palette: String, CaseIterable, Identifiable, Hashable {
    case atelier = "Atelier"
    case ardoise = "Ardoise"
    case sauge = "Sauge"
    case ocean = "Océan"
    case prune = "Prune"

    var id: String { rawValue }
    var label: String { rawValue }

    var rounder: Bool { self == .ardoise }

    var light: Tones {
        switch self {
        case .atelier: return Tones(bg: 0xFFF2ECE1, surface: 0xFFFFFDF8, alt: 0xFFF7F2E9, border: 0xFFE0D2B8, text: 0xFF2B2318, muted: 0xFF666666, accent: 0xFFA8672A, accentHover: 0xFF8A5220)
        case .ardoise: return Tones(bg: 0xFFF4F6FB, surface: 0xFFFFFFFF, alt: 0xFFF8FAFD, border: 0xFFE3E8F1, text: 0xFF182033, muted: 0xFF68738A, accent: 0xFF6366F1, accentHover: 0xFF4F46E5)
        case .sauge: return Tones(bg: 0xFFEEF2EC, surface: 0xFFFBFDF9, alt: 0xFFF3F7F0, border: 0xFFD3DFCD, text: 0xFF1D2A20, muted: 0xFF5F6F62, accent: 0xFF3F7D58, accentHover: 0xFF2F6346)
        case .ocean: return Tones(bg: 0xFFEDF3F7, surface: 0xFFFBFDFF, alt: 0xFFF2F7FA, border: 0xFFD2E0EA, text: 0xFF132433, muted: 0xFF5B7084, accent: 0xFF0E7490, accentHover: 0xFF0B5D73)
        case .prune: return Tones(bg: 0xFFF5F0F4, surface: 0xFFFFFCFE, alt: 0xFFF9F3F8, border: 0xFFE6D6E3, text: 0xFF2A1A28, muted: 0xFF6F5D6C, accent: 0xFF9D3F86, accentHover: 0xFF7F2F6C)
        }
    }

    var dark: Tones {
        switch self {
        case .atelier: return Tones(bg: 0xFF241F18, surface: 0xFF2C261E, alt: 0xFF342C22, border: 0xFF4D4335, text: 0xFFECE3D3, muted: 0xFFA89A80, accent: 0xFFC98A4B, accentHover: 0xFFDBA066)
        case .ardoise: return Tones(bg: 0xFF131826, surface: 0xFF1B2132, alt: 0xFF232A3E, border: 0xFF343D55, text: 0xFFE6E9F2, muted: 0xFF97A0B5, accent: 0xFF818CF8, accentHover: 0xFFA5B4FC)
        case .sauge: return Tones(bg: 0xFF161D18, surface: 0xFF1D261F, alt: 0xFF243028, border: 0xFF36473A, text: 0xFFE3ECE4, muted: 0xFF95A898, accent: 0xFF6FBF8E, accentHover: 0xFF8FD4A8)
        case .ocean: return Tones(bg: 0xFF0F1A22, surface: 0xFF15232D, alt: 0xFF1B2C38, border: 0xFF2C4352, text: 0xFFE1EDF4, muted: 0xFF8EA7B8, accent: 0xFF22B8CF, accentHover: 0xFF5FD0E0)
        case .prune: return Tones(bg: 0xFF1D151C, surface: 0xFF251B24, alt: 0xFF2E222C, border: 0xFF473645, text: 0xFFF0E4EE, muted: 0xFFAB98A8, accent: 0xFFD47FBF, accentHover: 0xFFE3A0D2)
        }
    }

    func tones(_ dark: Bool) -> Tones { dark ? self.dark : self.light }
}

func colorFromHex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

private func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
    let ar = Double((a >> 16) & 0xFF), ag = Double((a >> 8) & 0xFF), ab = Double(a & 0xFF)
    let br = Double((b >> 16) & 0xFF), bgc = Double((b >> 8) & 0xFF), bb = Double(b & 0xFF)
    return Color(
        red: (ar * t + br * (1 - t)) / 255,
        green: (ag * t + bgc * (1 - t)) / 255,
        blue: (ab * t + bb * (1 - t)) / 255,
    )
}

/// Rôles de couleur de l'interface (équivalent du ColorScheme Material 3 de l'app Android).
struct BullColors {
    let bg, surface, alt, border, text, muted, accent, accentHover, onAccent: Color
    let accentContainer, accentOnContainer, secondaryContainer: Color
    let tertiary, tertiaryContainer, tertiaryOnContainer: Color
    let error, errorContainer, onError, onErrorContainer: Color
    let outlineVariant: Color
    let isDark: Bool

    init(palette: Palette, dark: Bool) {
        let t = palette.tones(dark)
        bg = colorFromHex(t.bg); surface = colorFromHex(t.surface); alt = colorFromHex(t.alt)
        border = colorFromHex(t.border); text = colorFromHex(t.text); muted = colorFromHex(t.muted)
        accent = colorFromHex(t.accent); accentHover = colorFromHex(t.accentHover)
        onAccent = dark ? colorFromHex(t.bg) : Color.white
        isDark = dark
        let surfaceHex = t.surface
        accentContainer = mix(t.accent, surfaceHex, dark ? 0.30 : 0.22)
        accentOnContainer = colorFromHex(t.text)
        secondaryContainer = mix(t.accent, surfaceHex, dark ? 0.18 : 0.12)
        tertiary = dark ? colorFromHex(0xFFD9CA61) : colorFromHex(0xFF6B6000)
        tertiaryContainer = dark ? colorFromHex(0xFF514800) : colorFromHex(0xFFF6E77A)
        tertiaryOnContainer = dark ? colorFromHex(0xFFF6E77A) : colorFromHex(0xFF201C00)
        error = dark ? colorFromHex(0xFFFFB4AB) : colorFromHex(0xFFBA1A1A)
        errorContainer = dark ? colorFromHex(0xFF93000A) : colorFromHex(0xFFFFDAD6)
        onError = dark ? colorFromHex(0xFF690005) : Color.white
        onErrorContainer = dark ? colorFromHex(0xFFFFDAD6) : colorFromHex(0xFF410002)
        outlineVariant = colorFromHex(t.border)
    }

    var fieldBackground: Color {
        if isDark { return colorFromHex(0xFF2B2B2F) }
        return colorFromHex(0xFFE9E9EC)
    }

    var fieldBackgroundOnCard: Color {
        if isDark { return colorFromHex(0xFF1E1E21) }
        return colorFromHex(0xFFF1F1F3)
    }
}

private struct BullColorsKey: EnvironmentKey {
    static let defaultValue = BullColors(palette: .atelier, dark: false)
}

extension EnvironmentValues {
    var bullColors: BullColors {
        get { self[BullColorsKey.self] }
        set { self[BullColorsKey.self] = newValue }
    }
}

/// Thème choisi dans l'app : suivre le téléphone, toujours clair ou toujours sombre. Mémorisé sur l'appareil.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "Système"
    case light = "Clair"
    case dark = "Sombre"
    var id: String { rawValue }
}

@MainActor
final class ThemePref: ObservableObject {
    static let shared = ThemePref()
    private let d = UserDefaults.standard

    @Published var mode: ThemeMode {
        didSet { d.set(mode.rawValue, forKey: "ui_theme") }
    }
    @Published var palette: Palette {
        didSet { d.set(palette.rawValue, forKey: "ui_palette") }
    }

    private init() {
        let m = d.string(forKey: "ui_theme")
        mode = m.flatMap { ThemeMode(rawValue: $0) } ?? .system
        let p = d.string(forKey: "ui_palette")
        palette = p.flatMap { Palette(rawValue: $0) } ?? .atelier
    }
}

extension View {
    /// Applique la palette Bullarr : couleurs injectées dans l'environnement et colorScheme forcé.
    func bullTheme(_ pref: ThemePref, colorScheme: ColorScheme) -> some View {
        let dark: Bool
        switch pref.mode {
        case .system: dark = colorScheme == .dark
        case .light: dark = false
        case .dark: dark = true
        }
        return modifier(BullThemeModifier(colors: BullColors(palette: pref.palette, dark: dark), dark: dark))
    }
}

struct BullThemeModifier: ViewModifier {
    let colors: BullColors
    let dark: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.bullColors, colors)
            .environment(\.colorScheme, dark ? .dark : .light)
            .preferredColorScheme(dark ? .dark : .light)
            .tint(colors.accent)
    }
}

// --- Composants partagés -----------------------------------------------------

/// Onglet Configuration → Apparence : réglages propres à l'app sur ce téléphone.
struct AppearanceScreen: View {
    @EnvironmentObject private var themePref: ThemePref
    @Environment(\.bullColors) private var cs
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Thème").font(.headline)
                Picker("Thème", selection: Binding(get: { themePref.mode }, set: { themePref.mode = $0 })) {
                    ForEach(ThemeMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                Text("« Système » suit le mode clair ou sombre du téléphone. Ces réglages sont propres à cet appareil.")
                    .font(.caption)
                    .foregroundColor(cs.muted)
                Text("Couleurs").font(.headline).padding(.top, 8)
                PalettePickerView(dark: cs.isDark)
            }
            .padding(16)
        }
    }
}

/// Aperçu d'une palette : le fond, une carte, une ligne de texte et un bouton à l'accent.
struct PalettePreview: View {
    let p: Palette
    let dark: Bool

    var body: some View {
        let t = p.tones(dark)
        ZStack {
            RoundedRectangle(cornerRadius: p.rounder ? 12 : 8)
                .fill(colorFromHex(t.bg))
            RoundedRectangle(cornerRadius: p.rounder ? 12 : 8)
                .strokeBorder(colorFromHex(t.border), lineWidth: 1)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(colorFromHex(t.text)).frame(width: 44, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(colorFromHex(t.muted)).frame(width: 30, height: 4)
                RoundedRectangle(cornerRadius: 4).fill(colorFromHex(t.accent)).frame(width: 26, height: 8)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: p.rounder ? 8 : 5).fill(colorFromHex(t.surface)))
            .padding(4)
        }
        .frame(width: 92, height: 56)
    }
}

/// Choix de la palette (les mêmes que sur le site), avec un aperçu dans le mode clair/sombre courant.
struct PalettePickerView: View {
    @EnvironmentObject private var themePref: ThemePref
    @Environment(\.bullColors) private var cs
    let dark: Bool

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(Palette.allCases.enumerated()), id: \.element.rawValue) { pair in
                PaletteRow(pal: pair.element, dark: dark)
            }
        }
    }
}

/// Ligne de choix d'une palette.
struct PaletteRow: View {
    @EnvironmentObject private var themePref: ThemePref
    @Environment(\.bullColors) private var cs
    let pal: Palette
    let dark: Bool

    var body: some View {
        let selected = themePref.palette == pal
        Button {
            themePref.palette = pal
        } label: {
            HStack {
                PalettePreview(p: pal, dark: dark)
                Spacer(minLength: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pal.label)
                        .font(.subheadline)
                        .fontWeight(selected ? .semibold : .regular)
                    PaletteDots(p: pal, dark: dark)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle").foregroundColor(cs.accent) }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? cs.accent : cs.outlineVariant, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Les quatre couleurs d'aperçu de la palette.
struct PaletteDots: View {
    @Environment(\.bullColors) private var cs
    let p: Palette
    let dark: Bool

    var body: some View {
        let t = p.tones(dark)
        HStack(spacing: 4) {
            ForEach([t.accent, t.accentHover, t.alt, t.border], id: \.self) { hexv in
                Circle()
                    .fill(colorFromHex(hexv))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(cs.outlineVariant, lineWidth: 1))
            }
        }
    }
}

struct ErrorCard: View {
    @Environment(\.bullColors) private var cs
    let message: String
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                if let onRetry {
                    Button("Réessayer", action: onRetry).buttonStyle(.plain).fontWeight(.semibold)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cs.errorContainer))
        .foregroundColor(cs.onErrorContainer)
    }
}

/// Bouton principal en pastille (rempli avec la couleur d'accent).
struct AccentPillButtonStyle: ButtonStyle {
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

/// Bouton secondaire en pastille, liseré discret.
struct OutlinedPillButtonStyle: ButtonStyle {
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

/// Pastille de libellé bariolée (variante générique de TagView pour des couleurs imposées).
struct SmallTag: View {
    let text: String
    let container: Color
    let content: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(container))
            .foregroundColor(content)
    }
}

struct EmptyStateView: View {
    @Environment(\.bullColors) private var cs
    let title: String
    var detail: String? = nil
    var icon: String = "tray"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(cs.muted.opacity(0.6))
                .padding(.bottom, 4)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.subheadline).foregroundColor(cs.muted).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

struct TagView: View {
    let text: String
    let container: Color
    let content: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(container))
            .foregroundColor(content)
    }
}

/// Tag de série : pastille discrète bordée, « # » en couleur d'accent.
struct TopicTag: View {
    @Environment(\.bullColors) private var cs
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Text("#").foregroundColor(cs.accent)
            Text(text)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 50).strokeBorder(cs.outlineVariant, lineWidth: 1))
    }
}

/// Couverture chargée depuis Bullarr, avec un dos de livre neutre en attendant.
struct Cover: View {
    @Environment(\.bullColors) private var cs
    let url: String?
    let width: CGFloat

    init(url: String?, width: CGFloat) {
        self.url = url
        self.width = width
    }

    var body: some View {
        CoverInner(url: url, width: width)
            .frame(width: width, height: width * 1.38)
            .background(cs.alt)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct CoverInner: View {
    @Environment(\.bullColors) private var cs
    let url: String?
    let width: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book")
                    .font(.system(size: width / 2.2))
                    .foregroundColor(cs.border)
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            if let cached = CoverLoader.shared.cached(url) {
                image = cached
            } else {
                image = await CoverLoader.shared.load(url, targetWidthPx: Int(width * 2))
            }
        }
    }
}

/**
 * Champ de saisie des formulaires : libellé au-dessus, case arrondie de 44 pt sur un fond plus
 * sombre que la carte, liseré de la couleur principale quand il a le focus.
 */
struct FormField: View {
    @Environment(\.bullColors) private var cs
    @Binding var value: String
    var label: String? = nil
    var placeholder: String? = nil
    var password: Bool = false
    var clearable: Bool = false
    var singleLine: Bool = true
    var leadingIcon: String? = nil
    var supportingText: String? = nil
    var keyboardType: UIKeyboardType? = nil
    var onSubmit: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundColor(focused ? cs.accent : cs.muted)
            }
            HStack(spacing: 0) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .frame(width: 36, height: 36)
                }
                innerField
                    .padding(.vertical, 10)
                if clearable && !value.isEmpty {
                    Button { value = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(cs.muted)
                    }
                    .frame(width: 36, height: 36)
                }
                if password {
                    Button { shown.toggle() } label: {
                        Image(systemName: shown ? "eye.slash" : "eye")
                            .foregroundColor(cs.muted)
                    }
                    .frame(width: 36, height: 36)
                }
                if !clearable && !password { Spacer(minLength: 10) }
            }
            .padding(.leading, leadingIcon == nil ? 14 : 0)
            .padding(.trailing, 4)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(cs.fieldBackgroundOnCard))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? cs.accent : Color.clear, lineWidth: 1.5))
            .focused($focused)
        }
        if let supportingText {
            Text(supportingText).font(.caption).foregroundColor(cs.muted)
        }
    }

    @ViewBuilder
    private var innerField: some View {
        Group {
            if password && !shown {
                SecureField(placeholder ?? "", text: $value)
                    .submitLabel(.done)
                    .onSubmit { onSubmit?() }
            } else if singleLine {
                TextField(placeholder ?? "", text: $value)
                    .keyboardType(keyboardType ?? .default)
                    .submitLabel(.done)
                    .onSubmit { onSubmit?() }
            } else {
                TextField(placeholder ?? "", text: $value, axis: .vertical)
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .foregroundColor(cs.text)
    }
}

/// Champ des réglages (même style que FormField) avec une croix pour l'effacer.
struct ClearableField: View {
    @Binding var value: String
    var label: String? = nil
    var placeholder: String? = nil
    var supportingText: String? = nil
    var singleLine: Bool = true
    var secure: Bool = false

    var body: some View {
        FormField(value: $value, label: label, placeholder: placeholder, password: secure, clearable: true, singleLine: singleLine, supportingText: supportingText)
    }
}

/// Champ de recherche compact (40 pt) : loupe, texte, croix pour effacer. Pour les listes denses.
struct CompactSearchField: View {
    @Environment(\.bullColors) private var cs
    @Binding var value: String
    let placeholder: String
    var showIcon: Bool = true

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showIcon {
                Image(systemName: "magnifyingglass").foregroundColor(cs.muted)
            }
            TextField(placeholder, text: $value)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !value.isEmpty {
                Button { value = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(cs.muted)
                }
            }
        }
        .font(.subheadline)
        .foregroundColor(cs.text)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(cs.fieldBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? cs.accent : cs.outlineVariant.opacity(0.5), lineWidth: 1))
    }
}
