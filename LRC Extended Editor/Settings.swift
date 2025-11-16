import SwiftUI
import Combine

struct SettingsView: View {
    @ObservedObject var store = KaraokeStyleStore.shared
    @State private var selectedVideoFormat: String = "1080p (1920x1080)"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                Text("Videoformat:")
                    .font(.headline)
                Picker("Videoformat", selection: $selectedVideoFormat) {
                    Text("1080p (1920x1080)").tag("1080p (1920x1080)")
                    Text("720p (1280x720)").tag("720p (1280x720)")
                    Text("4K (3840x2160)").tag("4K (3840x2160)")
                }
                .pickerStyle(.menu)
                .frame(width: 220)
                Divider()
                    .frame(height: 24)
                Text("Karaoke-Style:")
                    .font(.headline)
                Picker("Karaoke-Style", selection: Binding(get: { store.selectedID }, set: { store.selectedID = $0 })) {
                    ForEach(store.styles) { style in
                        Text(style.name).tag(Optional(style.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)
            }

            // Vorschau
            StylePreview(style: store.selectedStyle)
                .frame(height: 160)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            Spacer()
        }
        .padding()
    }
}

private extension View {
    func previewOutlinedText(style: KaraokeStyle, alpha: CGFloat? = nil) -> some View {
        let a = Double(alpha ?? style.outlineAlpha)
        let color = style.outlineColor.color.opacity(a)
        return self
            .shadow(color: color, radius: 0, x: style.outlineWidth, y: 0)
            .shadow(color: color, radius: 0, x: -style.outlineWidth, y: 0)
            .shadow(color: color, radius: 0, x: 0, y: style.outlineWidth)
            .shadow(color: color, radius: 0, x: 0, y: -style.outlineWidth)
            .shadow(color: color, radius: 0, x: style.outlineWidth, y: style.outlineWidth)
            .shadow(color: color, radius: 0, x: -style.outlineWidth, y: style.outlineWidth)
            .shadow(color: color, radius: 0, x: style.outlineWidth, y: -style.outlineWidth)
            .shadow(color: color, radius: 0, x: -style.outlineWidth, y: -style.outlineWidth)
    }
}

// MARK: - Vorschau-Komponente
struct StylePreview: View {
    let style: KaraokeStyle

    var body: some View {
        ZStack {
            Group {
                if let top = style.gradientTop?.color,
                   let bottom = style.gradientBottom?.color {
                    LinearGradient(colors: [top, bottom],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                        .opacity(style.backgroundOpacity)
                } else {
                    style.background.color
                        .opacity(style.backgroundOpacity)
                }
            }
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                // Vergangene Zeile: keine Outline
                Text("Noch 10 Sekunden…")
                    .opacity(0.7)
                    .previewOutlinedText(style: style, alpha: 0)
                // Aktuelle Zeile: Highlight + Outline
                Text("[00:12] Weihnachten mit Dir")
                    .foregroundStyle(style.highlight.color)
                    .previewOutlinedText(style: style)
                // Nächste Zeile: Outline aktiv
                Text("Die Sterne singen heut’ mit uns")
                    .opacity(0.9)
                    .previewOutlinedText(style: style)
            }
            .font(.system(size: style.fontSize, weight: .regular))
            .foregroundStyle(style.foreground.color)
            .padding(16)
        }
        .compositingGroup()
        .shadow(color: Color.black.opacity(Double(style.shadowOpacity)), radius: style.shadowRadius, x: 0, y: 0)
        .overlay(contrastOverlay)
    }

    @ViewBuilder private var contrastOverlay: some View {
        if style.contrastBoost > 1.0 {
            // einfache Kontrastverstärkung als halbtransparenter Overlay
            Color.black.opacity(Double(min(max((style.contrastBoost - 1.0) * 0.25, 0.0), 0.6)))
        } else {
            EmptyView()
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(width: 560, height: 300)
    }
}
#endif
