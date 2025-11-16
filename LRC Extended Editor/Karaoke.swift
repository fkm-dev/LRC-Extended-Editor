import SwiftUI
import AppKit

/// A lightweight Karaoke player view that renders a rolling lyrics window
/// around the aktuell gesungenen (aktiven) Zeile. Oben kann gewählt werden,
/// wie viele Zeilen sichtbar sein sollen.
public struct KaraokePlayerView: View {
    @Binding var lyrics: LyricsDocument?
    @ObservedObject var audio: AudioPlayer

    /// Anzahl der sichtbaren Zeilen (gesamt). Mindestens 1.
    @State private var linesToShow: Int = 3
    @State private var windowStart: Int = 0
    @ObservedObject private var styleStore = KaraokeStyleStore.shared

    init(lyrics: Binding<LyricsDocument?>, audio: AudioPlayer, initialLinesToShow: Int = 3) {
        self._lyrics = lyrics
        self.audio = audio
        self._linesToShow = State(initialValue: max(1, initialLinesToShow))
    }

    public var body: some View {
        ZStack {
            Group {
                if let top = styleStore.selectedStyle.gradientTop?.color,
                   let bottom = styleStore.selectedStyle.gradientBottom?.color {
                    LinearGradient(colors: [top, bottom],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                        .opacity(styleStore.selectedStyle.backgroundOpacity)
                } else {
                    styleStore.selectedStyle.background.color
                        .opacity(styleStore.selectedStyle.backgroundOpacity)
                }
            }
            .ignoresSafeArea()

            VStack(alignment: .center, spacing: styleStore.selectedStyle.lineSpacing / 2) {
                // Config bar
                HStack(spacing: 12) {
                    Text("Karaoke")
                        .font(.headline)
                    Spacer()
                    Stepper(value: $linesToShow, in: 1...11, step: 2) {
                        Text("Zeilen anzeigen: \(linesToShow)")
                    }
                    .help("Gesamtanzahl der sichtbaren Zeilen (ungerade empfohlen, z. B. 3 / 5 / 7).")
                }

                Divider()

                // Centered lyrics window (no ScrollView/GeometryReader needed)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .center, spacing: styleStore.selectedStyle.lineSpacing) {
                        if let remaining = timeUntilFirstStart(), Int(remaining) >= 1 {
                            // Show header tags + countdown (only while > 3s before start)
                            VStack(spacing: 12) {
                                if let ti = tagValue("ti") {
                                    Text(ti)
                                        .font(.system(size: 64, weight: .bold))
                                        .foregroundStyle(styleStore.selectedStyle.foreground.color)
                                        .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                                                      width: styleStore.selectedStyle.outlineWidth,
                                                      alpha: Double(styleStore.selectedStyle.outlineAlpha))
                                }
                                if let ar = tagValue("ar") {
                                    Text(ar)
                                        .font(.system(size: 36, weight: .semibold))
                                        .foregroundStyle(styleStore.selectedStyle.foreground.color)
                                        .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                                                      width: styleStore.selectedStyle.outlineWidth,
                                                      alpha: Double(styleStore.selectedStyle.outlineAlpha))
                                }
                                // Countdown number while >3s
                                Text("\(Int(remaining))")
                                    .font(.system(size: 48, weight: .black))
                                    .foregroundStyle(styleStore.selectedStyle.foreground.color)
                                    .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                                                  width: styleStore.selectedStyle.outlineWidth,
                                                  alpha: Double(styleStore.selectedStyle.outlineAlpha))
                                    .padding(.top, 16)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            // Show karaoke lyrics (no fade)
                            ForEach(visibleLines(), id: \.id) { (line: LyricLine) in
                                KaraokeLineRow(
                                    line: line,
                                    currentTime: audio.currentTime,
                                    isActive: (line.id == activeLineID()),
                                    fade: fadeForLine(line),
                                    nextLineStart: nextStartAfter(line)
                                )
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .opacity(rowOpacityForLine(line))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        // Center the window on first show without jumping each frame
                        let total = (lyrics?.lines ?? []).filter { ($0.tokens.first?.time ?? $0.startTime) >= 0 || !$0.tokens.isEmpty }.count
                        adjustWindowStart(active: activeLineIndex() ?? 0, total: total, span: linesToShow)
                    }
                    .onChange(of: activeLineIndex() ?? 0) { newVal in
                        let total = (lyrics?.lines ?? []).filter { ($0.tokens.first?.time ?? $0.startTime) >= 0 || !$0.tokens.isEmpty }.count
                        adjustWindowStart(active: newVal, total: total, span: linesToShow)
                    }
                    .animation(.easeOut(duration: 0.12), value: windowStart)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .padding(12)
        }
    }


    // MARK: - Windowing helpers to reduce jolty re-centering
    private func windowSlice(total: Int, span: Int) -> ClosedRange<Int> {
        let start = min(max(0, windowStart), max(0, total - 1))
        let end = min(total - 1, start + max(1, span) - 1)
        return start...end
    }

    private func adjustWindowStart(active: Int, total: Int, span: Int) {
        guard total > 0 else { windowStart = 0; return }
        let spanClamped = max(1, min(span, total))
        let start = min(max(0, windowStart), max(0, total - spanClamped))
        let end = min(total - 1, start + spanClamped - 1)

        if active < start {
            // Jump one full window back
            windowStart = max(0, start - spanClamped)
        } else if active > end {
            // Jump one full window forward
            windowStart = min(max(0, total - spanClamped), start + spanClamped)
        } else {
            // Active is within the current window: do nothing (no scroll)
            windowStart = start
        }
    }

    // MARK: - Computations

    private func firstStartTime() -> TimeInterval? {
        guard let all = lyrics?.lines, !all.isEmpty else { return nil }
        var t: TimeInterval = .greatestFiniteMagnitude
        for l in all {
            if let ft = l.tokens.first?.time {
                t = min(t, ft)
            } else if l.startTime >= 0 {
                t = min(t, l.startTime)
            }
        }
        return t == .greatestFiniteMagnitude ? nil : t
    }

    private func visibleLines() -> [LyricLine] {
        guard let all = lyrics?.lines else { return [] }
        var usable: [LyricLine] = []
        for line in all {
            let hasTokens = !line.tokens.isEmpty
            let hasLabel = (line.label != nil && !(line.label!.trimmingCharacters(in: .whitespaces).isEmpty))
            let start = line.tokens.first?.time ?? line.startTime
            if hasTokens || hasLabel || start >= 0 {
                usable.append(line)
            }
        }
        guard !usable.isEmpty else { return [] }

        let activeIdx = activeLineIndex() ?? 0
        let span = max(1, linesToShow)
        // Use a stable window anchored by `windowStart` to avoid constant re-centering
        let slice = windowSlice(total: usable.count, span: span)
        return Array(usable[slice])
    }

    private func activeLineIndex(time: TimeInterval? = nil) -> Int? {
        guard let all = lyrics?.lines else { return nil }
        // Use only timed lines (same criterion as visibleLines)
        var timed: [LyricLine] = []
        for line in all {
            let start = line.tokens.first?.time ?? line.startTime
            if start >= 0 || !line.tokens.isEmpty {
                timed.append(line)
            }
        }
        guard !timed.isEmpty else { return nil }

        let t = time ?? audio.currentTime
        // Tolerances for stable selection
        let startEps: TimeInterval = 0.15
        let endEps: TimeInterval = 0.20

        for i in 0..<timed.count {
            let line = timed[i]
            let start = line.tokens.first?.time ?? line.startTime
            let rawNext: TimeInterval = {
                if i + 1 < timed.count {
                    let n = timed[i + 1]
                    return n.tokens.first?.time ?? n.startTime
                }
                return (line.tokens.last?.time ?? start) + 0.5
            }()
            let nextStart = max(start + 0.02, rawNext)
            let windowStart = start - startEps
            let windowEnd = nextStart + endEps
            if t >= windowStart && t <= windowEnd { return i }
        }
        // If we're before the very first line, show the first line (not the last).
        if let first = timed.first {
            let firstStart = first.tokens.first?.time ?? first.startTime
            if t < firstStart - startEps {
                return 0
            }
        }
        // Otherwise (e.g., beyond the last window), keep showing the last line.
        return timed.indices.last
    }

    private func activeLineID() -> UUID? {
        guard let all = lyrics?.lines else { return nil }
        var timed: [LyricLine] = []
        for line in all {
            let start = line.tokens.first?.time ?? line.startTime
            if start >= 0 || !line.tokens.isEmpty {
                timed.append(line)
            }
        }
        guard !timed.isEmpty else { return nil }
        guard let idx = activeLineIndex() else { return nil }
        return timed[idx].id
    }

    // MARK: - Line time helpers
    private func lineStart(_ line: LyricLine) -> TimeInterval {
        return line.tokens.first?.time ?? line.startTime
    }
    private func lineEnd(_ line: LyricLine) -> TimeInterval {
        if let lastTok = line.tokens.last { return lastTok.time }
        if line.startTime >= 0 { return line.startTime }
        return 0
    }
    private func timedLines() -> [LyricLine] {
        guard let all = lyrics?.lines else { return [] }
        var result: [LyricLine] = []
        for line in all {
            let start = line.tokens.first?.time ?? line.startTime
            if start >= 0 || !line.tokens.isEmpty {
                result.append(line)
            }
        }
        return result
    }
    private func previousTimedLine() -> LyricLine? {
        let t = timedLines()
        guard !t.isEmpty, let idx = activeLineIndex() else { return nil }
        let prev = idx - 1
        guard prev >= 0 else { return nil }
        return t[prev]
    }
    private func currentActiveTimedLine() -> LyricLine? {
        let t = timedLines()
        guard !t.isEmpty, let idx = activeLineIndex() else { return nil }
        return t[idx]
    }

    private func nextStartAfter(_ line: LyricLine) -> TimeInterval? {
        let t = timedLines()
        guard let idx = t.firstIndex(where: { $0.id == line.id }) else { return nil }
        let next = idx + 1
        guard next < t.count else { return nil }
        return lineStart(t[next])
    }

    // MARK: - Row rendering helpers
    private func fadeForLine(_ line: LyricLine) -> Double {
        // Outline should persist until the next line starts (not only until the last token of this line).
        let baseEnd: TimeInterval = {
            if let lastTok = line.tokens.last { return lastTok.time }
            if line.startTime >= 0 { return line.startTime }
            return 0
        }()
        let outlineEnd: TimeInterval = nextStartAfter(line) ?? baseEnd
        let dt = audio.currentTime - outlineEnd
        return (dt <= 0) ? 1.0 : 0.0
    }

    private func rowOpacityForLine(_ line: LyricLine) -> Double {
        // Always render rows at full opacity; do not keep the previous line visible.
        return 1.0
    }

    // MARK: - Metadata / Counter helpers
    private func tagValue(_ key: String) -> String? {
        // Preferred aliases per LRC conventions
        let aliases: [String: [String]] = [
            "ti": ["ti", "title", "song", "name"],
            "ar": ["ar", "artist", "singer"],
            "al": ["al", "album", "record"],
            "by": ["by", "editor", "creator"]
        ]
        let want = Set((aliases[key.lowercased()] ?? [key]).map { $0.lowercased() })

        guard let lyr = lyrics else { return fallbackFor(key: key) }

        // --- generic value extractors ---
        func matchKey(_ k: String) -> Bool { want.contains(k.lowercased()) }

        func fromDict(_ d: [String: String]) -> String? {
            for (k,v) in d where matchKey(k) { return v }
            return nil
        }

        // Search a String for [k: v] lines
        func fromRaw(_ s: String) -> String? {
            let lines = s.split(whereSeparator: \.isNewline).prefix(24)
            for line in lines {
                let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard s.hasPrefix("[") && s.hasSuffix("]"), let colon = s.firstIndex(of: ":") else { continue }
                let inner = s.dropFirst().dropLast()
                let k = inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if matchKey(k) { return String(v) }
            }
            return nil
        }

        // Recursive reflection over arbitrary objects
        var visited = Set<ObjectIdentifier>()
        func fromAny(_ any: Any) -> String? {
            // Direct access
            if let d = any as? [String:String], let v = fromDict(d) { return v }
            if let s = any as? String, let v = fromRaw(s) { return v }

            let m = Mirror(reflecting: any)
            if m.displayStyle == .class || m.displayStyle == .struct {
                if let obj = any as AnyObject?, m.displayStyle == .class {
                    let id = ObjectIdentifier(obj)
                    if visited.contains(id) { return nil }
                    visited.insert(id)
                }
                for child in m.children {
                    // If the child key matches exactly and is a String, return it
                    if let label = child.label, matchKey(label), let v = child.value as? String { return v }
                    // If it is a dictionary or string block, recurse
                    if let v = fromAny(child.value) { return v }
                }
            }
            // Arrays / collections
            if let arr = any as? [Any] {
                for item in arr { if let v = fromAny(item) { return v } }
            }
            return nil
        }

        // 1) Try whole LyricsDocument recursively
        if let v = fromAny(lyr) { return v }

        // 2) Last-chance: look for common raw/text properties by name
        let m = Mirror(reflecting: lyr)
        for name in ["raw", "rawText", "text", "source", "sourceText", "original", "originalText"] {
            if let s = m.children.first(where: { $0.label == name })?.value as? String, let v = fromRaw(s) { return v }
        }

        // 3) Fallback to something sensible if available (e.g., from audio URL)
        return fallbackFor(key: key)
    }

    private func fallbackFor(key: String) -> String? {
        // Try to extract something from the audio filename as a last resort
        let keyL = key.lowercased()
        // best-effort read url from AudioPlayer via reflection (we don't own its API)
        let m = Mirror(reflecting: audio)
        var fileName: String?
        if let url = m.children.first(where: { $0.label?.lowercased().contains("url") == true })?.value as? URL {
            fileName = url.deletingPathExtension().lastPathComponent
        }
        if keyL == "ti" { return fileName }
        return nil
    }


    private func timeUntilFirstStart() -> TimeInterval? {
        guard let t0 = firstStartTime() else { return nil }
        return max(0, t0 - audio.currentTime)
    }

}

// MARK: - View Extension for outlinedText
public extension View {
    func outlinedText(color: Color = .black, width: CGFloat = 2, alpha: Double = 1) -> some View {
        let c = color.opacity(alpha)
        return self
            .shadow(color: c, radius: 0, x: width, y: 0)
            .shadow(color: c, radius: 0, x: -width, y: 0)
            .shadow(color: c, radius: 0, x: 0, y: width)
            .shadow(color: c, radius: 0, x: 0, y: -width)
            .shadow(color: c, radius: 0, x: width, y: width)
            .shadow(color: c, radius: 0, x: -width, y: width)
            .shadow(color: c, radius: 0, x: width, y: -width)
            .shadow(color: c, radius: 0, x: -width, y: -width)
    }
}

// MARK: - A single karaoke line row with word-level highlighting
public struct KaraokeLineRow: View {
    let line: LyricLine
    let currentTime: TimeInterval
    let isActive: Bool
    let fade: Double  // 1.0 = fully visible, 0.0 = fully invisible
    let nextLineStart: TimeInterval?
    @ObservedObject private var styleStore = KaraokeStyleStore.shared

    private func fontSize(for geo: GeometryProxy) -> CGFloat {
        // Use ~80% of available width; scale text proportionally and clamp to reasonable bounds
        let usableWidth = geo.size.width * 0.8
        // Heuristic: target around 18 average characters; clamp between 32pt and 96pt
        let byWidth = usableWidth / 18.0
        return min(max(byWidth, 32), 96)
    }

    private func labelText(fontSize: CGFloat) -> Text {
        let label = (line.label ?? "").uppercased()
        return Text(label)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(isActive ? Color(NSColor.systemBlue) : .white)
    }

    private func composedText(fontSize: CGFloat) -> some View {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        let fullText = NSMutableAttributedString()

        for i in 0..<line.tokens.count {
            let tok = line.tokens[i]
            let nextT: TimeInterval = {
                if i + 1 < line.tokens.count { return line.tokens[i + 1].time }
                // last token: keep highlighted until next line begins (if known)
                if let nls = nextLineStart { return max(tok.time, nls) }
                return tok.time + 0.35
            }()
            let activeTok = isActiveToken(start: tok.time, end: nextT)

            let fillColor: NSColor = (activeTok ? styleStore.selectedStyle.highlight.nsColor : styleStore.selectedStyle.foreground.nsColor)
            let word = NSMutableAttributedString(string: tok.text)
            word.addAttributes([
                .strokeColor: styleStore.selectedStyle.outlineColor.nsColor,
                .foregroundColor: fillColor,
                .strokeWidth: -max(2.0, styleStore.selectedStyle.outlineWidth * 2.0),
                .font: font
            ], range: NSRange(location: 0, length: word.length))

            fullText.append(word)

            if i < line.tokens.count - 1 {
                let space = NSMutableAttributedString(string: " ")
                space.addAttributes([
                    .strokeColor: styleStore.selectedStyle.outlineColor.nsColor,
                    .foregroundColor: (activeTok ? styleStore.selectedStyle.highlight.nsColor : styleStore.selectedStyle.foreground.nsColor),
                    .strokeWidth: -max(2.0, styleStore.selectedStyle.outlineWidth * 2.0),
                    .font: font
                ], range: NSRange(location: 0, length: space.length))
                fullText.append(space)
            }
        }

        return Text(AttributedString(fullText))
    }

    public var body: some View {
        GeometryReader { geo in
            HStack {
                Spacer(minLength: 0)
                Group {
                    if line.tokens.isEmpty {
                        labelText(fontSize: fontSize(for: geo))
                    } else {
                        composedText(fontSize: fontSize(for: geo))
                    }
                }
                // Kontur nur für aktive/kommende Zeilen. Abgelaufen: keine Kontur, aber Füllung bleibt weiß.
                .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                               width: styleStore.selectedStyle.outlineWidth,
                               alpha: (fade >= 1 ? Double(styleStore.selectedStyle.outlineAlpha) : 0))
                .frame(width: max(0, geo.size.width * 0.8), alignment: .center)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(false) // keine dynamische Laufweitenänderung
                .kerning(0)              // konstante Spationierung
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 72)
        .padding(.vertical, 14)
    }

    private func isActiveToken(start: TimeInterval, end: TimeInterval) -> Bool {
        let endAdj = max(start + 0.02, end)
        return currentTime >= start - 0.02 && currentTime < endAdj + 0.02
    }
}
