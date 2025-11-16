import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - Codable color wrapper (NSColor <-> Codable)
struct CodableColor: Codable, Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }
}

// MARK: - Karaoke Style
struct KaraokeStyle: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String

    // Essentials: Farbe, Kontrast, Schriftgröße, Zeilenabstand, Hintergrund
    var foreground: CodableColor
    var background: CodableColor
    // Optional: Verlaufshintergrund (falls gesetzt, wird dieser statt "background" genutzt)
    var gradientTop: CodableColor? = nil
    var gradientBottom: CodableColor? = nil
    var backgroundOpacity: CGFloat = 1.0
    /// Highlightfarbe (aktuelle Zeile/Wort)
    var highlight: CodableColor

    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var contrastBoost: CGFloat   // 1.0 = neutral, >1 verstärkt Kontrast

    // Optional, aber nützlich für Lesbarkeit
    var shadowOpacity: CGFloat   // 0...1
    var shadowRadius: CGFloat

    // Outline-Effekt (Kontur) für alle Texte
    var outlineColor: CodableColor
    var outlineWidth: CGFloat   // Pixelbreite der Kontur in SwiftUI-Shadow-Heuristik
    var outlineAlpha: CGFloat   // 0...1 Sichtbarkeit der Kontur

    init(id: UUID = UUID(),
         name: String,
         foreground: NSColor,
         background: NSColor,
         highlight: NSColor,
         fontSize: CGFloat,
         lineSpacing: CGFloat,
         contrastBoost: CGFloat = 1.0,
         shadowOpacity: CGFloat = 0.0,
         shadowRadius: CGFloat = 0.0,
         gradientTop: NSColor? = nil,
         gradientBottom: NSColor? = nil,
         backgroundOpacity: CGFloat = 1.0,
         outlineColor: NSColor = .black,
         outlineWidth: CGFloat = 2.0,
         outlineAlpha: CGFloat = 1.0) {
        self.id = id
        self.name = name
        self.foreground = CodableColor(foreground)
        self.background = CodableColor(background)
        self.highlight = CodableColor(highlight)
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.contrastBoost = contrastBoost
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        if let gt = gradientTop { self.gradientTop = CodableColor(gt) }
        if let gb = gradientBottom { self.gradientBottom = CodableColor(gb) }
        self.backgroundOpacity = backgroundOpacity
        self.outlineColor = CodableColor(outlineColor)
        self.outlineWidth = outlineWidth
        self.outlineAlpha = outlineAlpha
    }
}

// MARK: - Persistenter Store (Styles + Auswahl)
final class KaraokeStyleStore: ObservableObject {
    static let shared = KaraokeStyleStore()

    private let stylesKey   = "KaraokeStyles.v1"
    private let selectedKey = "KaraokeSelectedStyleID.v1"

    @Published private(set) var styles: [KaraokeStyle] = []
    @Published var selectedID: UUID? { didSet { saveSelected() } }

    var selectedStyle: KaraokeStyle {
        if let id = selectedID, let s = styles.first(where: { $0.id == id }) { return s }
        return styles.first ?? KaraokeStyleStore.defaultStyle()
    }

    private init() { load() }

    // CRUD
    func add(_ style: KaraokeStyle) { styles.append(style); save() }
    func update(_ style: KaraokeStyle) {
        if let idx = styles.firstIndex(where: { $0.id == style.id }) {
            styles[idx] = style; save()
        }
    }
    func remove(_ styleID: UUID) {
        styles.removeAll { $0.id == styleID }
        if selectedID == styleID { selectedID = styles.first?.id }
        save(); saveSelected()
    }
    func select(_ styleID: UUID) { selectedID = styleID }

    // Persistence
    private func load() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: stylesKey),
           let decoded = try? JSONDecoder().decode([KaraokeStyle].self, from: data) {
            styles = decoded
        }
        if styles.isEmpty {
            styles = Self.presetStyles()
        }
        if let data = ud.data(forKey: selectedKey),
           let id = try? JSONDecoder().decode(UUID.self, from: data) {
            selectedID = id
        } else {
            selectedID = styles.first?.id
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(styles) {
            UserDefaults.standard.set(data, forKey: stylesKey)
        }
    }
    private func saveSelected() {
        if let id = selectedID, let data = try? JSONEncoder().encode(id) {
            UserDefaults.standard.set(data, forKey: selectedKey)
        }
    }
}

// MARK: - Defaults & Migration
extension KaraokeStyleStore {
    /// Default aus bisherigen Einstellungen (falls vorhanden) oder fallback.
    static func defaultStyleFromLegacyOrFallback() -> KaraokeStyle {
        let ud = UserDefaults.standard

        // Versuche aus alten Keys zu migrieren (falls ihr bereits Werte gespeichert hattet)
        let fg = (ud.color(forKey: "KaraokeForegroundColor") ?? .white)
        let bg = (ud.color(forKey: "KaraokeBackgroundColor") ?? .black)
        let hi = (ud.color(forKey: "KaraokeHighlightColor")  ?? .systemYellow)

        let fontSize    = (ud.object(forKey: "KaraokeFontSize")       as? CGFloat) ?? 24
        let lineSpacing = (ud.object(forKey: "KaraokeLineSpacing")    as? CGFloat) ?? 8
        let contrast    = (ud.object(forKey: "KaraokeContrastBoost")  as? CGFloat) ?? 1.0
        let shOpacity   = (ud.object(forKey: "KaraokeShadowOpacity")  as? CGFloat) ?? 0.0
        let shRadius    = (ud.object(forKey: "KaraokeShadowRadius")   as? CGFloat) ?? 0.0

        return KaraokeStyle(
            name: "Classic",
            foreground: .white,
            background: .black, // Fallback solid, wird vom Gradient überlagert
            highlight: .systemBlue,
            fontSize: 32, // dynamisch im Player, hier Basiswert
            lineSpacing: 22,
            contrastBoost: 1.0,
            shadowOpacity: 0.0,
            shadowRadius: 0.0,
            gradientTop: NSColor.systemPurple,
            gradientBottom: NSColor.systemBlue,
            backgroundOpacity: 0.75,
            outlineColor: .black,
            outlineWidth: 1.5,
            outlineAlpha: 1.0
        )
    }

    static func defaultStyle() -> KaraokeStyle {
        KaraokeStyle(
            name: "Classic",
            foreground: .white,
            background: .black,
            highlight: .systemBlue,
            fontSize: 32,
            lineSpacing: 22,
            contrastBoost: 1.0,
            shadowOpacity: 0.0,
            shadowRadius: 0.0,
            gradientTop: NSColor.systemPurple,
            gradientBottom: NSColor.systemBlue,
            backgroundOpacity: 0.75,
            outlineColor: .black,
            outlineWidth: 1.5,
            outlineAlpha: 1.0
        )
    }
    /// Vordefinierte Styles (Classic + 4 weitere gut lesbare Presets)
    static func presetStyles() -> [KaraokeStyle] {
        // 1) Classic – aktueller Player-Look (Purple→Blue)
        let classic = defaultStyle()

        // 2) High Contrast – maximale Lesbarkeit
        let highContrast = KaraokeStyle(
            name: "High Contrast",
            foreground: NSColor.white,
            background: NSColor.black,
            highlight: NSColor.systemYellow,
            fontSize: 34,
            lineSpacing: 20,
            contrastBoost: 1.0,
            shadowOpacity: 0.0,
            shadowRadius: 0.0,
            gradientTop: NSColor.black,
            gradientBottom: NSColor.black,
            backgroundOpacity: 1.0,
            outlineColor: .black,
            outlineWidth: 1.5,
            outlineAlpha: 1.0
        )

        // 3) Minimal – monochrom, ruhig
        let minimal = KaraokeStyle(
            name: "Minimal",
            foreground: NSColor(calibratedWhite: 0.85, alpha: 1.0),
            background: NSColor.black,
            highlight: NSColor.white,
            fontSize: 30,
            lineSpacing: 18,
            contrastBoost: 1.0,
            shadowOpacity: 0.0,
            shadowRadius: 0.0,
            gradientTop: nil,
            gradientBottom: nil,
            backgroundOpacity: 1.0,
            outlineColor: .black,
            outlineWidth: 1.5,
            outlineAlpha: 1.0
        )

        // 4) Sunset – warm, lebendig
        let sunset = KaraokeStyle(
            name: "Sunset",
            foreground: NSColor.white,
            background: NSColor.black,
            highlight: NSColor.systemYellow,
            fontSize: 32,
            lineSpacing: 22,
            contrastBoost: 1.0,
            shadowOpacity: 0.0,
            shadowRadius: 0.0,
            gradientTop: NSColor.systemOrange,
            gradientBottom: NSColor.systemRed,
            backgroundOpacity: 0.80,
            outlineColor: .black,
            outlineWidth: 1.5,
            outlineAlpha: 1.0
        )

        // 5) Ocean – kühl, modern
        let ocean = KaraokeStyle(
            name: "Ocean",
            foreground: NSColor.white,
            background: NSColor.black,
            highlight: NSColor.systemCyan,
            fontSize: 32,
            lineSpacing: 22,
            contrastBoost: 1.0,
            shadowOpacity: 0.0,
            shadowRadius: 0.0,
            gradientTop: NSColor.systemTeal,
            gradientBottom: NSColor.systemBlue,
            backgroundOpacity: 0.80,
            outlineColor: .black,
            outlineWidth: 1.5,
            outlineAlpha: 1.0
        )

        // 6) Greenscreen – schwarzer Text auf grünem Hintergrund
        let greenscreen = KaraokeStyle(
            name: "Greenscreen",
                foreground: NSColor.white, // weißer Text
                background: NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.0, alpha: 1.0), // reines Chroma-Grün
                highlight: NSColor.white,
                fontSize: 32,
                lineSpacing: 22,
                contrastBoost: 1.2,
                shadowOpacity: 0.0,
                shadowRadius: 0.0,
                gradientTop: nil,
                gradientBottom: nil,
                backgroundOpacity: 1.0,
                outlineColor: NSColor.black,
                outlineWidth: 0.5, // ganz fein, für klare Kanten
                outlineAlpha: 0.4  // schwach, nur zur Abhebung
            )

        return [classic, highContrast, minimal, sunset, ocean, greenscreen]
    }
}

// MARK: - UserDefaults <-> NSColor Helpers
private extension UserDefaults {
    func color(forKey key: String) -> NSColor? {
        guard let data = data(forKey: key) else { return nil }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data))
    }
    func setColor(_ color: NSColor?, forKey key: String) {
        guard let color else { removeObject(forKey: key); return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            set(data, forKey: key)
        }
    }
}

// MARK: - SwiftUI Helper (optional)
extension View {
    /// Schnelles Anwenden von Foreground/Background aus einem Style
    func karaokeStyled(_ style: KaraokeStyle) -> some View {
        self
            .foregroundStyle(style.foreground.color)
            .background(style.background.color)
    }
}
