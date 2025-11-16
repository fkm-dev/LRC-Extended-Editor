

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Accelerate

// MARK: - Editor Command Notifications
extension Notification.Name {
    static let editorInsertSnippet = Notification.Name("LRCEditor_InsertSnippet")
    static let editorFocusTextView = Notification.Name("LRCEditor_FocusTextView")
    static let forceEditorRefresh = Notification.Name("ForceEditorRefresh")
}

/// Reusable LRC editor view with transport + editing controls
struct LRCEditorView: View {
    @Binding var rawLyrics: String
    @Binding var lyrics: LyricsDocument?
    @ObservedObject var audio: AudioPlayer

    @State private var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @State private var highlightRange: NSRange = NSRange(location: NSNotFound, length: 0)
    @State private var tokenHighlightRange: NSRange = NSRange(location: NSNotFound, length: 0)
    @State private var hasUserEditedText: Bool = false
    // --- Search & Replace State ---
    @State private var searchQuery: String = ""
    @State private var replaceQuery: String = ""
    @State private var selectedRangeForSearch: NSRange? = nil
    @State private var searchResults: [Range<String.Index>] = []
    @State private var currentSearchIndex: Int = 0

    @AppStorage("MaxVisibleCharsPerLine") private var maxVisibleCharsPerLine: Int = 60
    // Persist editor state between launches
    @AppStorage("LastEditorText") private var lastEditorText: String = ""
    @AppStorage("LastEditorCaret") private var lastEditorCaret: Int = 0

    @State private var startModeEnabled: Bool = false

    @State private var peaks: [Float] = []
    @State private var zoom: CGFloat = 1
    @State private var offset: CGFloat = 0
    @State private var peaksLoading: Bool = false

    /// Called when the user taps "Übernehmen → Vorschau" (e.g., to switch mode in parent)
    var onApply: (() -> Void)? = nil
    /// Called when the user taps "Lyrics speichern…"
    var onSave: (() -> Void)? = nil


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Max. Zeichen/Zeile, Startmodus und Datei/Projekt/Audio-Buttons in einer Zeile
            HStack(spacing: 6) {
                Stepper(value: $maxVisibleCharsPerLine, in: 30...120, step: 5) {
                    Text("Max. Zeichen/Zeile: \(maxVisibleCharsPerLine)")
                }
                .help("Schwelle für rote Zeilenwarnung (ohne Zeit-Tags).")
                .controlSize(.small)

                Toggle("Startmodus", isOn: $startModeEnabled)
                    .toggleStyle(.switch)
                    .help("Startmodus: Enter setzt den aktuellen Zeilen-Zeitcode am Zeilenanfang. Erste Enter-Taste startet in der aktuellen Zeile.")
                    .controlSize(.small)

                // --- Datei/Projekt/Audio-Buttons ---
                Button("Lyrics speichern…") { if let onSave { onSave() } }
                    .help("Speichert die Lyrics in eine Datei.")
                    .controlSize(.small)

                Button("Lyrics laden…") {
                    let panel = NSOpenPanel()
                    panel.allowedFileTypes = ["lrc", "txt"]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canCreateDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            let content = try String(contentsOf: url, encoding: .utf8)
                            rawLyrics = content
                            print("[LyricsLoad] Lyrics geladen aus: \(url.path), Länge: \(content.count) Zeichen")
                        } catch {
                            let alert = NSAlert(error: error)
                            alert.messageText = "Fehler beim Laden der Lyrics"
                            alert.informativeText = error.localizedDescription
                            alert.runModal()
                        }
                    }
                }
                .help("Lädt Lyrics aus einer .lrc oder .txt Datei in den Editor.")
                .controlSize(.small)

                Button("Projekt speichern") {
                    saveProjectNow()
                }
                .help("Speichert das aktuelle Projekt. Wenn bereits ein Projekt geöffnet ist, wird im selben Ordner gespeichert, sonst wirst du gefragt.")
                .controlSize(.small)

                Button("Audio laden…") { pickAudioAndLoad() }
                    .help("Lädt eine Audiodatei zum Abspielen und Synchronisieren.")
                    .controlSize(.small)
            }
            .padding(.horizontal)

            // Suchen & Ersetzen
            HStack(spacing: 8) {
                TextField("Suchen", text: $searchQuery)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 120)

                Button("Suchen") {
                    searchResults = rawLyrics.ranges(of: searchQuery)
                    currentSearchIndex = 0
                    if let first = searchResults.first {
                        selectedRange = NSRange(first, in: rawLyrics)
                        NotificationCenter.default.post(name: .editorFocusTextView, object: nil)
                    }
                }
                Button("Weiter") {
                    guard !searchResults.isEmpty else { return }
                    currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
                    let range = searchResults[currentSearchIndex]
                    selectedRange = NSRange(range, in: rawLyrics)
                    NotificationCenter.default.post(name: .editorFocusTextView, object: nil)
                }

                TextField("Ersetzen mit", text: $replaceQuery)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 120)

                Button("Ersetzen") {
                    if let range = rawLyrics.range(of: searchQuery, options: [.caseInsensitive]), !searchQuery.isEmpty {
                        rawLyrics.replaceSubrange(range, with: replaceQuery)
                    }
                }
            }
            .padding(.horizontal)

            // Kompakt-Toolbar: Buttons etc.
            VStack(alignment: .leading, spacing: 4) {
                // Erste Zeile: Buttons (nur die verbleibenden Buttons)
                HStack(spacing: 6) {
                    Button("Zeitstempel (Wort) einfügen ⏱") { insertWordTimestamp() }
                        .help("Fügt einen Zeitstempel an der aktuellen Cursor-Position ein.")
                        .controlSize(.small)
                    Button("Zeilen-Zeitstempel einfügen ⏱") { insertLineTimestamp() }
                        .help("Fügt einen Zeilen-Zeitstempel an der aktuellen Cursor-Position ein.")
                        .controlSize(.small)
                    Button("Header-Tags einfügen…") { insertHeaderTagsPrompt() }
                        .help("Fügt Zeilen für Titel, Artist, Album und By als Header-Tags ein.")
                        .controlSize(.small)
                    Button("Wort-Zeitstempel automatisch setzen") { autoTimestampWords() }
                        .help("Setzt automatisch Zeitstempel für jedes Wort zwischen zwei Zeilen-Zeitstempeln.")
                        .controlSize(.small)
                }
                .buttonStyle(.bordered)
                // Zweite Zeile: Undo/Redo
                HStack(spacing: 6) {
                    // Undo / Redo arrows
                    HStack(spacing: 4) {
                        Button {
                            NSApp?.sendAction(Selector(("undo:")), to: nil, from: nil)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .help("Rückgängig")
                        .controlSize(.small)

                        Button {
                            NSApp?.sendAction(Selector(("redo:")), to: nil, from: nil)
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                        }
                        .help("Wiederholen")
                        .controlSize(.small)
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .padding(.horizontal)

            // Transport for editing
            TransportBar(audio: audio)
                .controlSize(.small)

            if peaksLoading {
                HStack { ProgressView(); Text("Wellenform wird berechnet…") }
                    .frame(height: 80)
            } else if !peaks.isEmpty {
                WaveformView(
                    peaks: peaks,
                    duration: audio.duration,
                    currentTime: Binding(get: { audio.currentTime }, set: { audio.seek(to: max(0, $0)) }),
                    zoom: $zoom,
                    offset: $offset
                )
                .frame(height: 80)
            } else if audio.currentURL != nil {
                Text("Keine Samples gefunden – prüfe Audioformat")
                    .frame(height: 80)
                    .foregroundStyle(.secondary)
            }

            MacTextView(text: $rawLyrics,
                        selectedRange: $selectedRange,
                        highlightRange: $highlightRange,
                        tokenHighlightRange: $tokenHighlightRange,
                        maxChars: maxVisibleCharsPerLine,
                        onSeek: { t in audio.seek(to: max(0, t)) },
                        currentTime: { audio.currentTime },
                        startMode: startModeEnabled)
                .frame(minHeight: 300)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .onAppear {
                    restoreEditorConfiguration()
                    updateHighlight()
                    if let url = audio.currentURL {
                        loadPeaksAsync(for: url)
                    }
                }
                .onChange(of: selectedRange) { _, _ in updateHighlight() }
                .onChange(of: audio.currentTime) { _, _ in updateHighlight() }
                .onChange(of: audio.currentURL) { _, newURL in
                    if let url = newURL {
                        loadPeaksAsync(for: url)
                    } else {
                        peaks = []
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppPerformSaveToFile"))) { note in
                    if let filename = note.object as? String {
                        saveProjectNow(filename: filename)
                    } else {
                        saveProjectNow()
                    }
                }
        }
        // MARK: - Notification Handling (Safe Version)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppClearEditor"))) { _ in
            print("[EditorDebug] AppClearEditor empfangen – Editor wird geleert und visuell aktualisiert.")
            rawLyrics = ""
            lyrics = nil
            // Editor sofort refreshen
            NotificationCenter.default.post(name: .forceEditorRefresh, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppDidOpenProject"))) { notif in
            if let newText = notif.object as? String {
                if !hasUserEditedText {
                    rawLyrics = newText
                    print("[EditorDebug] Neues Projekt geladen, Textlänge: \(newText.count)")
                } else {
                    print("[EditorDebug] Ignoriere AppDidOpenProject, da Benutzer aktiv editiert hat.")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppRequestEditorContent"))) { notif in
            print("[LRCEditorView] AppRequestEditorContent empfangen, Textlänge: \(rawLyrics.count)")
            if let completion = notif.userInfo?["completion"] as? (String) -> Void {
                completion(rawLyrics)
            }
        }
    }
    // MARK: - Waveform loader
    private func loadPeaksAsync(for url: URL, points: Int = 6000) {
        self.peaksLoading = true; self.peaks = []
        DispatchQueue.global(qos: .userInitiated).async {
            let p = (try? Self.loadPeaks(url: url, points: points)) ?? []
            DispatchQueue.main.async {
                self.peaks = p
                self.zoom = 1
                self.offset = 0
                self.peaksLoading = false
            }
        }
    }

    private static func loadPeaks(url: URL, points: Int = 4000) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { dst in
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: dst.baseAddress!)
            }
            // Downmix simple stereo→mono by absolute average of interleaved samples
            if track.formatDescriptions.count > 0 {
                var mono: [Float] = []
                mono.reserveCapacity(data.count / 2)
                var i = 0
                while i + 1 < data.count {
                    mono.append(0.5 * (abs(data[i]) + abs(data[i+1])))
                    i += 2
                }
                samples.append(contentsOf: mono)
            } else {
                samples.append(contentsOf: data.map { abs($0) })
            }
            CMSampleBufferInvalidate(buffer)
        }
        if reader.status == .failed { return [] }
        guard !samples.isEmpty else { return [] }

        // Downsample to target point count (peak hold)
        let stride = max(1, samples.count / max(1, points))
        var peaks: [Float] = []
        peaks.reserveCapacity(points)
        var i = 0
        while i < samples.count {
            let end = min(i + stride, samples.count)
            let sliceMax = samples[i..<end].max() ?? 0
            peaks.append(sliceMax)
            i = end
        }
        if let m = peaks.max(), m > 0 {
            var inv = Float(1.0 / m)
            vDSP_vsmul(peaks, 1, &inv, &peaks, 1, vDSP_Length(peaks.count))
        }
        return peaks
    }

    // MARK: - Helpers (local)
    private func formatTag(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "<00:00.00>" }
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        return String(format: "<%02d:%02d.%02d>", mm, ss, cs)
    }

    private func formatLineTag(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "[00:00.00]" }
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        return String(format: "[%02d:%02d.%02d]", mm, ss, cs)
    }

    private func insertWordTimestamp() {
        NotificationCenter.default.post(name: .editorInsertSnippet, object: nil, userInfo: ["snippet": formatTag(audio.currentTime)])
    }

    private func insertLineTimestamp() {
        let tag = formatLineTag(audio.currentTime)
        NotificationCenter.default.post(name: .editorInsertSnippet, object: nil, userInfo: ["snippet": tag])
    }

    private func insertHeaderTagsPrompt() {
        // Build an NSAlert with four labeled text fields
        let alert = NSAlert()
        alert.messageText = "Header-Tags einfügen"
        alert.informativeText = "Bitte Titel, Artist, Album und By eingeben. Die Tags werden als erste Zeilen eingefügt."

        // Create labels and fields
        let titleLabel = NSTextField(labelWithString: "Titel (ti):")
        let artistLabel = NSTextField(labelWithString: "Artist (ar):")
        let albumLabel = NSTextField(labelWithString: "Album (al):")
        let byLabel = NSTextField(labelWithString: "By (by):")

        let titleField = NSTextField(string: "")
        let artistField = NSTextField(string: "")
        let albumField = NSTextField(string: "")
        let byField = NSTextField(string: "")

        // Layout in a grid
        let grid = NSGridView(views: [
            [titleLabel, titleField],
            [artistLabel, artistField],
            [albumLabel, albumField],
            [byLabel, byField]
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        artistField.widthAnchor.constraint(equalTo: titleField.widthAnchor).isActive = true
        albumField.widthAnchor.constraint(equalTo: titleField.widthAnchor).isActive = true
        byField.widthAnchor.constraint(equalTo: titleField.widthAnchor).isActive = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        container.addSubview(grid)
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        grid.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        grid.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true

        alert.accessoryView = container
        alert.addButton(withTitle: "Einfügen")
        alert.addButton(withTitle: "Abbrechen")

        // Present as sheet if possible
        let applyBlock: () -> Void = {
            let ti = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ar = artistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let al = albumField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let by = byField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            insertHeaderTags(ti: ti, ar: ar, al: al, by: by)
        }
        if let window = NSApp?.keyWindow {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn { applyBlock() }
            }
        } else {
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn { applyBlock() }
        }
    }

    private func insertHeaderTags(ti: String, ar: String, al: String, by: String) {
        // Compose header lines exactly as requested
        let lineTI = "[ti:\(ti)]"
        let lineAR = "[ar:\(ar)]"
        let lineAL = "[al:\(al)]"
        let lineBY = "[by:\(by)]"
        let headerBlock = [lineTI, lineAR, lineAL, lineBY].joined(separator: "\n")

        // Prepend to the editor text (first lines)
        if rawLyrics.isEmpty {
            rawLyrics = headerBlock + "\n"
        } else {
            // Avoid duplicating if the same block already present at top
            let ns = rawLyrics as NSString
            let firstLineRange = ns.lineRange(for: NSRange(location: 0, length: 0))
            let firstChunkLen = min(ns.length, headerBlock.utf16.count + 8)
            let headPreview = ns.substring(with: NSRange(location: 0, length: firstChunkLen))
            if !headPreview.hasPrefix(lineTI) {
                rawLyrics = headerBlock + "\n" + rawLyrics
            } else {
                // Replace existing header if it starts with [ti:]
                rawLyrics = headerBlock + "\n" + ns.substring(from: firstLineRange.upperBound)
            }
        }
        // Move caret to start of document
        selectedRange = NSRange(location: 0, length: 0)
    }

    private func insertAtCaret(_ snippet: String) {
        NotificationCenter.default.post(name: .editorInsertSnippet, object: nil, userInfo: ["snippet": snippet])
    }

    private func updateHighlight(minGap: TimeInterval = 0.02) {
        // Consider only lines that actually carry timing (header or tokens)
        let timed = timedLinesInfo()
        guard !timed.isEmpty else {
            highlightRange = NSRange(location: NSNotFound, length: 0)
            tokenHighlightRange = NSRange(location: NSNotFound, length: 0)
            return
        }
        let t = audio.currentTime
        var activeIdx: Int? = nil
        for i in 0..<timed.count {
            let startT = timed[i].start
            let endT: TimeInterval = {
                if i + 1 < timed.count { return max(startT + minGap, timed[i+1].start) }
                // fallback to last token + 0.5s if no next line
                return max(startT + minGap, (timed[i].lastToken ?? startT) + 0.5)
            }()
            if t >= startT - 0.05 && t <= endT + 0.05 { activeIdx = i; break }
        }
        guard let idx = activeIdx else {
            highlightRange = NSRange(location: NSNotFound, length: 0)
            tokenHighlightRange = NSRange(location: NSNotFound, length: 0)
            return
        }

        // Highlight the active timed line
        let line = timed[idx]
        highlightRange = line.range

        // If there are tokens, compute active token text range
        guard !line.tokens.isEmpty else {
            tokenHighlightRange = NSRange(location: NSNotFound, length: 0)
            return
        }

        let ns = rawLyrics as NSString
        let lineStr = ns.substring(with: line.range)
        // Header prefix length (if present) to offset scanning
        let headerRegex = try? NSRegularExpression(pattern: "^\\[(\\d{2}):(\\d{2}\\.?\\d*)\\]", options: [])
        var headerConsumed = 0
        if let m = headerRegex?.firstMatch(in: lineStr, options: [], range: NSRange(location: 0, length: (lineStr as NSString).length)) {
            headerConsumed = m.range.length
        }

        var scanStart = headerConsumed
        let lns = lineStr as NSString
        var activeTokRange: NSRange = NSRange(location: NSNotFound, length: 0)
        for (j, tok) in line.tokens.enumerated() {
            let ltRangeRaw = lns.range(of: "<", options: [], range: NSRange(location: scanStart, length: lns.length - scanStart))
            if ltRangeRaw.location == NSNotFound { break }
            let gtRangeRaw = lns.range(of: ">", options: [], range: NSRange(location: ltRangeRaw.location + 1, length: lns.length - (ltRangeRaw.location + 1)))
            if gtRangeRaw.location == NSNotFound { break }
            let afterGT = gtRangeRaw.location + gtRangeRaw.length
            let nextLT = lns.range(of: "<", options: [], range: NSRange(location: afterGT, length: lns.length - afterGT))
            let textEnd = (nextLT.location == NSNotFound) ? lns.length : nextLT.location
            let textLen = max(0, textEnd - afterGT)
            let textRangeInLine = NSRange(location: afterGT, length: textLen)

            let startTok = tok.time
            let endTok: TimeInterval = {
                if j + 1 < line.tokens.count { return max(startTok + minGap, line.tokens[j+1].time) }
                // last token window ends at next timed line's start, or +0.5s fallback
                let nextStart = (idx + 1 < timed.count) ? timed[idx+1].start : ((line.lastToken ?? startTok) + 0.5)
                return max(startTok + minGap, nextStart)
            }()

            if t >= startTok - 0.02 && t < endTok + 0.02 {
                activeTokRange = NSRange(location: line.range.location + textRangeInLine.location, length: textRangeInLine.length)
                break
            }
            scanStart = textEnd
        }
        tokenHighlightRange = activeTokRange
    }

    /// Return only lines that have timing (either header time or at least one token), with precomputed start and last token time.
    private func timedLinesInfo() -> [(range: NSRange, start: TimeInterval, lastToken: TimeInterval?, tokens: [LineToken])] {
        let all = documentLinesInfo()
        var out: [(NSRange, TimeInterval, TimeInterval?, [LineToken])] = []
        for item in all {
            let start = item.tokens.first?.time ?? item.headerTime
            let hasTiming = (start >= 0) || (!item.tokens.isEmpty)
            if hasTiming {
                let lastTok = item.tokens.last?.time
                out.append((item.range, start, lastTok, item.tokens))
            }
        }
        return out
    }

    private func documentLinesInfo() -> [(range: NSRange, headerTime: TimeInterval, tokens: [LineToken])] {
        var result: [(NSRange, TimeInterval, [LineToken])] = []
        let ns = rawLyrics as NSString
        var loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let lineStr = ns.substring(with: lineRange)
            // Parse header [mm:ss.xx]
            let headerRegex = try? NSRegularExpression(pattern: "^\\[(\\d{2}):(\\d{2}\\.?\\d*)\\]", options: [])
            var cursor = lineStr
            var headerTime: TimeInterval = -1
            if let m = headerRegex?.firstMatch(in: lineStr, options: [], range: NSRange(location: 0, length: (lineStr as NSString).length)) {
                let mm = (lineStr as NSString).substring(with: m.range(at: 1))
                let ss = (lineStr as NSString).substring(with: m.range(at: 2))
                headerTime = parseTime(mm, ss)
                let cut = Range(m.range, in: lineStr)!
                cursor = String(lineStr[cut.upperBound...])
            }
            // Parse tokens <mm:ss.xx>text
            var tokens: [LineToken] = []
            var scan = cursor
            while let lt = scan.range(of: "<"), let gt = scan[lt.upperBound...].firstIndex(of: ">") {
                let timeStamp = scan[lt.upperBound..<gt].trimmingCharacters(in: .whitespaces)
                let comps = timeStamp.split(separator: ":")
                guard comps.count == 2 else { break }
                let t = parseTime(String(comps[0]), String(comps[1]))
                let rest = scan[gt...]
                let nextLT = rest.dropFirst().firstIndex(of: "<") ?? scan.endIndex
                let textSeg = String(scan[gt...].dropFirst().prefix(upTo: nextLT)).trimmingCharacters(in: .whitespaces)
                if !textSeg.isEmpty { tokens.append(LineToken(time: t, text: textSeg)) }
                scan = String(scan[nextLT...])
            }
            result.append((lineRange, headerTime, tokens))
            loc = lineRange.upperBound
        }
        return result
    }

    private func pickAudioAndLoad() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mp3")!,
            UTType(filenameExtension: "m4a")!,
            UTType(filenameExtension: "wav")!,
            UTType(filenameExtension: "aiff")!
        ]
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                do {
                    try audio.load(url: url)
                } catch {
                    // optional: present an alert later; for now ignore
                }
            }
        }
    }



    // MARK: - Project save (current folder or ask)
    /// Speichert einen Projekt-Snapshot (Lyrics + Audio-Pfad + Style + einige Editor-Settings)
    /// in die aktuelle Projekt-Mappe, falls vorhanden, andernfalls fragt ein Save-Dialog.
    private func saveProjectNow(filename: String = "karaoke_project.fkm") {
        // 0) Sicherstellen, dass der Editor-Text aktuell ist (wie bisher)
        if let tv = NSApp?.keyWindow?.firstResponder as? NSTextView {
            rawLyrics = tv.string
            selectedRange = tv.selectedRange()
        } else if let tv = NSApp?.mainWindow?.firstResponder as? NSTextView {
            rawLyrics = tv.string
            selectedRange = tv.selectedRange()
        }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        NSApp?.mainWindow?.makeFirstResponder(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        // 1) Baue einen Snapshot
        struct ProjectSnapshot: Codable {
            struct AudioRef: Codable { var url: String? }
            var version: Int
            var timestamp: String
            var rawLyrics: String
            var style: KaraokeStyle
            var editor: EditorState
            var audio: AudioRef
            struct EditorState: Codable {
                var maxVisibleCharsPerLine: Int
                var startModeEnabled: Bool
            }
        }
        let snapshot = ProjectSnapshot(
            version: 1,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            rawLyrics: rawLyrics,
            style: KaraokeStyleStore.shared.selectedStyle,
            editor: .init(maxVisibleCharsPerLine: maxVisibleCharsPerLine,
                          startModeEnabled: startModeEnabled),
            audio: .init(url: (audio.currentURL?.absoluteString))
        )

        // 2) JSON encodieren (lesbar formatiert)
        let encoder = JSONEncoder()
        if #available(macOS 12.0, *) {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.prettyPrinted]
        }
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Projekt konnte nicht kodiert werden"
            alert.runModal()
            return
        }

        // 3) In bestehendes Projektverzeichnis schreiben, falls möglich
        if let doc = NSDocumentController.shared.currentDocument, let fileURL = doc.fileURL {
            let dir = fileURL.deletingLastPathComponent()
            let target = dir.appendingPathComponent(filename)
            do {
                try data.write(to: target, options: .atomic)
                let alert = NSAlert()
                alert.messageText = "Projekt gespeichert"
                alert.informativeText = "Gespeichert in: \(target.path)"
                alert.runModal()
                return
            } catch {
                // Fallback auf Dialog
            }
        }

        // 4) Kein Projekt offen oder Schreiben fehlgeschlagen → nach Ziel fragen
        let panel = NSSavePanel()
        panel.title = "Projekt speichern"
        panel.message = "Wähle wohin der Projekt-Snapshot (JSON) gespeichert werden soll."
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [UTType(filenameExtension: "fkm")!]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                let alert = NSAlert()
                alert.messageText = "Projekt gespeichert"
                alert.informativeText = "Gespeichert in: \(url.path)"
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Persist/Restore Editor Configuration
    private func saveEditorConfiguration() {
        lastEditorText = rawLyrics
        lastEditorCaret = selectedRange.location
    }

    private func restoreEditorConfiguration() {
        // Restore the last saved editor text if available (persisted across relaunches).
        guard !lastEditorText.isEmpty else { return }
        rawLyrics = lastEditorText
        // restore caret safely
        let loc = max(0, min(lastEditorCaret, (lastEditorText as NSString).length))
        selectedRange = NSRange(location: loc, length: 0)
    }

    // MARK: - Per-line reflow based on caret line
    private func reflowCurrentLine(minGap: TimeInterval = 0.02) {
        guard let lineInfo = currentLineInfo() else { return }
        let (lineRange, headerTime, tokens, nextLineStart) = lineInfo
        guard !tokens.isEmpty else { return }

        // Determine end of line window
        let startT = tokens.first?.time ?? headerTime
        let fallbackEnd = (tokens.last?.time ?? startT) + 0.5
        let endT = max(startT + minGap, (nextLineStart ?? fallbackEnd))

        // Enforce non-decreasing with minGap
        var toks = tokens
        for j in 1..<toks.count {
            let prev = toks[j-1].time
            if toks[j].time < prev + minGap {
                toks[j].time = prev + minGap
            }
        }

        // Compress to window if last spills over
        if let first = toks.first?.time, let last = toks.last?.time, last > endT {
            let span = max(minGap, last - first)
            let target = max(minGap, endT - first)
            let scale = target / span
            for i in 0..<toks.count {
                let dt = toks[i].time - first
                toks[i].time = first + dt * scale
            }
        }

        // Rebuild line string: [header] then <time>text with single spaces
        var rebuilt = ""
        if headerTime >= 0 { rebuilt += formatLineTag(headerTime) }
        var parts: [String] = []
        for tok in toks {
            parts.append("\(formatTag(tok.time))\(tok.text)")
        }
        let body = parts.joined(separator: " ")
        if headerTime >= 0 { rebuilt += body.isEmpty ? "" : body } else { rebuilt = body }

        // Replace in rawLyrics
        if let range = Range(lineRange, in: rawLyrics) {
            rawLyrics.replaceSubrange(range, with: rebuilt)
            // keep caret within the line (approximate to line start)
            selectedRange = NSRange(location: lineRange.location, length: 0)
        }
    }

    private struct LineToken { var time: TimeInterval; var text: String }

    private func currentLineInfo() -> (lineRange: NSRange, headerTime: TimeInterval, tokens: [LineToken], nextLineStart: TimeInterval?)? {
        let text = rawLyrics as NSString
        let fullLen = text.length
        let loc = max(0, min(selectedRange.location, fullLen))

        let lineStart = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: loc)).location
        let startIdx = (lineStart == NSNotFound) ? 0 : lineStart + 1

        let lineEndSearchStart = startIdx
        let nextNewlineRange = text.range(of: "\n", options: [], range: NSRange(location: lineEndSearchStart, length: fullLen - lineEndSearchStart))
        let endIdx = (nextNewlineRange.location == NSNotFound) ? fullLen : nextNewlineRange.location

        let lineRange = NSRange(location: startIdx, length: endIdx - startIdx)
        let lineStr = text.substring(with: lineRange)

        // Parse header [mm:ss.xx] if present
        let headerRegex = try? NSRegularExpression(pattern: "^\\[(\\d{2}):(\\d{2}\\.?\\d*)\\]", options: [])
        var cursor = lineStr
        var headerTime: TimeInterval = -1
        if let m = headerRegex?.firstMatch(in: lineStr, options: [], range: NSRange(location: 0, length: (lineStr as NSString).length)) {
            let mm = (lineStr as NSString).substring(with: m.range(at: 1))
            let ss = (lineStr as NSString).substring(with: m.range(at: 2))
            headerTime = parseTime(mm, ss)
            let cut = Range(m.range, in: lineStr)!
            cursor = String(lineStr[cut.upperBound...])
        }

        // Parse tokens: <mm:ss.xx>text (text until next '<' or EOL)
        var tokens: [LineToken] = []
        var scan = cursor
        while let lt = scan.range(of: "<"), let gt = scan[lt.upperBound...].firstIndex(of: ">") {
            let timeStamp = scan[lt.upperBound..<gt].trimmingCharacters(in: .whitespaces)
            let comps = timeStamp.split(separator: ":")
            guard comps.count == 2 else { break }
            let t = parseTime(String(comps[0]), String(comps[1]))
            let rest = scan[gt...]
            let nextLT = rest.dropFirst().firstIndex(of: "<") ?? scan.endIndex
            let textSeg = String(scan[gt...].dropFirst().prefix(upTo: nextLT)).trimmingCharacters(in: .whitespaces)
            if !textSeg.isEmpty { tokens.append(LineToken(time: t, text: textSeg)) }
            scan = String(scan[nextLT...])
        }

        // Determine next line start time (from next line header or first token)
        var nextStart: TimeInterval? = nil
        if nextNewlineRange.location != NSNotFound {
            let nextLineStart = nextNewlineRange.location + 1
            if nextLineStart < fullLen {
                let nextLineRange = text.lineRange(for: NSRange(location: nextLineStart, length: 0))
                let nextLineStr = text.substring(with: NSRange(location: nextLineStart, length: nextLineRange.length - (nextLineStart - nextLineRange.location)))
                nextStart = extractFirstTime(from: nextLineStr)
            }
        }

        return (lineRange, headerTime, tokens, nextStart)
    }

    private func parseTime(_ mm: String, _ ss: String) -> TimeInterval {
        let minutes = Double(mm) ?? 0
        let seconds = Double(ss.replacingOccurrences(of: ",", with: ".")) ?? 0
        return minutes * 60 + seconds
    }

    private func extractFirstTime(from line: String) -> TimeInterval? {
        // Prefer first token time, else header time
        if let m = line.range(of: #"<\s*(\d{2}):(\d{2}\.?\d*)\s*>"#, options: .regularExpression) {
            let tag = String(line[m]).trimmingCharacters(in: CharacterSet(charactersIn: "< >"))
            let comps = tag.split(separator: ":")
            if comps.count == 2 { return parseTime(String(comps[0]), String(comps[1])) }
        }
        if let m = line.range(of: #"^\[(\d{2}):(\d{2}\.?\d*)\]"#, options: [.regularExpression]) {
            let tag = String(line[m]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let comps = tag.split(separator: ":")
            if comps.count == 2 { return parseTime(String(comps[0]), String(comps[1])) }
        }
        return nil
    }
}

extension String.Index {
    func samePosition(in utf16: String.UTF16View) -> String.UTF16View.Index? {
        return String.UTF16View.Index(self, within: utf16)
    }
}

extension String {
    func index(_ i: Index, offsetByUTF16 n: Int) -> Index {
        let utf16View = self.utf16
        let startUTF16 = i.samePosition(in: utf16View) ?? utf16View.startIndex
        let targetUTF16 = self.utf16.index(startUTF16, offsetBy: n)
        return Index(targetUTF16, within: self) ?? endIndex
    }

    func index(startIndex: Index, offsetByUTF16 n: Int) -> Index {
        return index(startIndex, offsetByUTF16: n)
    }

}

final class SeekingTextView: NSTextView {
    var onSeekLine: ((TimeInterval) -> Void)?
    var currentTimeProvider: (() -> TimeInterval)?
    weak var timeEditFieldRef: NSTextField?

    var startModeEnabled: Bool = false
    var startModeHasStarted: Bool = false

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let ns = self.string as NSString
        let caret = self.selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let lineStr = ns.substring(with: lineRange)
        let local = caret - lineRange.location

        if event.clickCount == 2 {
            // Double-click: edit time mark under cursor (header or token)
            editTimeTagAtCaret(absLineRange: lineRange, lineText: lineStr, localIndex: local)
            return
        }

        // Single click: only seek if the click was on the line header [mm:ss.xx]
        if let (t, hdrRange) = Self.extractHeaderTimeAndRange(from: lineStr) {
            if NSLocationInRange(local, hdrRange) {
                onSeekLine?(t)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = (event.keyCode == 36) || (event.characters == "\r") || (event.characters == "\n")
        guard startModeEnabled, isReturn else {
            super.keyDown(with: event)
            return
        }

        let t = currentTimeProvider?() ?? 0
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        let tag = String(format: "[%02d:%02d.%02d] ", mm, ss, cs)

        let ns = self.string as NSString
        let caret = max(0, min(self.selectedRange().location, ns.length))
        let currentLineRange = ns.lineRange(for: NSRange(location: caret, length: 0))

        func insert(_ s: String, at loc: Int) {
            let r = NSRange(location: loc, length: 0)
            if self.shouldChangeText(in: r, replacementString: s) {
                self.textStorage?.beginEditing()
                self.textStorage?.replaceCharacters(in: r, with: s)
                self.textStorage?.endEditing()
                self.didChangeText()
                self.setSelectedRange(NSRange(location: loc + s.utf16.count, length: 0))
                self.scrollRangeToVisible(NSRange(location: loc, length: s.utf16.count))
            }
        }

        if !startModeHasStarted {
            startModeHasStarted = true
            insert(tag, at: currentLineRange.location)
            return
        }

        var insertionLoc: Int
        if currentLineRange.upperBound < ns.length {
            insertionLoc = currentLineRange.upperBound
        } else {
            insert("\n", at: ns.length)
            insertionLoc = (self.string as NSString).length
        }

        insert(tag, at: insertionLoc)
    }

    private static func extractHeaderTimeAndRange(from line: String) -> (TimeInterval, NSRange)? {
        // Header time [mm:ss.xx] at the start of the line
        let pattern = #"^\[(\d{2}):(\d{2}\.??\d*)\]"#
        if let m = line.range(of: pattern, options: .regularExpression) {
            let tag = String(line[m]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let comps = tag.split(separator: ":")
            if comps.count == 2 {
                let mm = Double(comps[0]) ?? 0
                let ss = Double(comps[1].replacingOccurrences(of: ",", with: ".")) ?? 0
                let t = mm * 60 + ss
                let nsRange = NSRange(m, in: line)
                return (t, nsRange)
            }
        }
        return nil
    }

    // MARK: - Time editing helpers
    @objc func takeCurrentTimeForTimeEdit(_ sender: Any?) {
        guard let field = timeEditFieldRef else { return }
        let t = currentTimeProvider?() ?? 0
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        let formatted = String(format: "%02d:%02d.%02d", mm, ss, cs)
        field.stringValue = formatted
    }

    private func editTimeTagAtCaret(absLineRange: NSRange, lineText: String, localIndex: Int) {
        // 1) Header at start of line
        if let (t, hdrRange) = Self.extractHeaderTimeAndRange(from: lineText), NSLocationInRange(localIndex, hdrRange) {
            let absRange = NSRange(location: absLineRange.location + hdrRange.location, length: hdrRange.length)
            presentTimeEdit(initial: t, isHeader: true) { newT in
                let replacement = Self.formatHeaderTag(newT)
                self.replaceRange(absRange, with: replacement)
            }
            return
        }
        // 2) Token <mm:ss.xx> enclosing caret
        if let tokenRange = Self.findTokenRange(in: lineText, around: localIndex) {
            let absRange = NSRange(location: absLineRange.location + tokenRange.location, length: tokenRange.length)
            let tokText = (lineText as NSString).substring(with: tokenRange)
            let initial = Self.parseTime(fromTagText: tokText)
            presentTimeEdit(initial: initial ?? 0, isHeader: false) { newT in
                let replacement = Self.formatTokenTag(newT)
                self.replaceRange(absRange, with: replacement)
            }
        }
    }

    private func replaceRange(_ r: NSRange, with str: String) {
        guard let storage = self.textStorage else { return }
        // Ensure delegate notifications & undo work
        if self.shouldChangeText(in: r, replacementString: str) {
            storage.beginEditing()
            storage.replaceCharacters(in: r, with: str)
            storage.endEditing()
            self.didChangeText()
            // Move caret to end of replaced tag
            self.setSelectedRange(NSRange(location: r.location + str.utf16.count, length: 0))
            self.scrollRangeToVisible(NSRange(location: r.location, length: str.utf16.count))
        }
    }

    private static func findTokenRange(in line: String, around localIndex: Int) -> NSRange? {
        let ns = line as NSString
        let len = ns.length
        let pos = max(0, min(localIndex, len))
        // search left for '<'
        let left = ns.range(of: "<", options: .backwards, range: NSRange(location: 0, length: pos))
        if left.location == NSNotFound { return nil }
        // search right for '>'
        let rightStart = left.location + 1
        if rightStart > len { return nil }
        let right = ns.range(of: ">", options: [], range: NSRange(location: rightStart, length: len - rightStart))
        if right.location == NSNotFound { return nil }
        // quick validation
        let mid = NSRange(location: left.location + 1, length: max(0, right.location - left.location - 1))
        let hasColon = (ns.range(of: ":", options: [], range: mid).location != NSNotFound)
        if !hasColon { return nil }
        return NSRange(location: left.location, length: right.location - left.location + 1)
    }

    private static func parseTime(fromTagText text: String) -> TimeInterval? {
        // Accept both header and token tag text
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]<>"))
        let comps = trimmed.split(separator: ":")
        guard comps.count == 2 else { return nil }
        let mm = Double(comps[0]) ?? 0
        let ss = Double(comps[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        return mm * 60 + ss
    }

    private static func formatHeaderTag(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        return String(format: "[%02d:%02d.%02d]", mm, ss, cs)
    }

    private static func formatTokenTag(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        return String(format: "<%02d:%02d.%02d>", mm, ss, cs)
    }

    private func presentTimeEdit(initial: TimeInterval, isHeader: Bool, apply: @escaping (TimeInterval) -> Void) {
        // Build prefilled text mm:ss.cc
        let mm = Int(initial) / 60
        let ss = Int(initial) % 60
        let cs = Int((initial - floor(initial)) * 100)
        let prefill = String(format: "%02d:%02d.%02d", mm, ss, cs)

        let alert = NSAlert()
        alert.messageText = isHeader ? "Zeilen-Zeitstempel bearbeiten" : "Wort-Zeitstempel bearbeiten"
        alert.informativeText = "Format: mm:ss.cc"
        let field = NSTextField(string: prefill)
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        self.timeEditFieldRef = field

        let takeBtn = NSButton(title: "Aktuelle Zeit übernehmen", target: self, action: #selector(takeCurrentTimeForTimeEdit(_:)))

        let stack = NSStackView(views: [field, takeBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        container.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true

        alert.accessoryView = container
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")

        if let window = self.window {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn {
                    let input = field.stringValue
                    if let t = Self.parseTimeString(input) {
                        apply(t)
                    }
                }
            }
        } else {
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                if let t = Self.parseTimeString(field.stringValue) { apply(t) }
            }
        }
    }

    private static func parseTimeString(_ s: String) -> TimeInterval? {
        // Normalize "mm:ss.cc" (allow comma or dot)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let mm = Double(parts[0]) ?? 0
        let sec = parts[1].replacingOccurrences(of: ",", with: ".")
        let ss = Double(sec) ?? 0
        return mm * 60 + ss
    }
}

// MARK: - NSColor helpers for high-contrast selection
extension NSColor {
    /// Return the color converted to sRGB and its RGBA components if possible
    func srgbComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        let c = self.usingColorSpace(.sRGB)
        guard let c else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// Relative luminance per WCAG 2.0
    var relativeLuminance: CGFloat {
        guard let (r, g, b, _) = srgbComponents() else { return 0.5 }
        func toLinear(_ u: CGFloat) -> CGFloat { return (u <= 0.03928) ? (u/12.92) : pow((u + 0.055)/1.055, 2.4) }
        let R = toLinear(r), G = toLinear(g), B = toLinear(b)
        return 0.2126*R + 0.7152*G + 0.0722*B
    }
}

private func contrastingTextColor(for background: NSColor) -> NSColor {
    // Choose black/white for best contrast vs background
    let bg = background.usingColorSpace(.sRGB) ?? background
    return (bg.relativeLuminance > 0.5) ? NSColor.black : NSColor.white
}

struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var highlightRange: NSRange
    @Binding var tokenHighlightRange: NSRange
    var maxChars: Int = 60
    var onSeek: ((TimeInterval) -> Void)? = nil
    var currentTime: (() -> TimeInterval)? = nil
    var startMode: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder

        let textView = SeekingTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.delegate = context.coordinator
        // Seek on click directly from the text view
        textView.onSeekLine = { t in
            self.onSeek?(t)
        }
        textView.currentTimeProvider = self.currentTime
        textView.startModeEnabled = self.startMode
        textView.startModeHasStarted = false

        context.coordinator.textView = textView
        context.coordinator.prevHighlight = NSRange(location: NSNotFound, length: 0)
        textView.drawsBackground = true

        // Observe editor commands
        context.coordinator.insertObserver = NotificationCenter.default.addObserver(forName: .editorInsertSnippet, object: nil, queue: .main) { note in
            if let s = note.userInfo?["snippet"] as? String {
                context.coordinator.insertSnippet(s)
            }
        }
        // Observe focus notification
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(forName: .editorFocusTextView, object: nil, queue: .main) { _ in
            textView.window?.makeFirstResponder(textView)
        }
        // Observe force editor refresh
        context.coordinator.refreshObserver = NotificationCenter.default.addObserver(forName: .forceEditorRefresh, object: nil, queue: .main) { _ in
            print("[MacTextView] ForceEditorRefresh empfangen – Editor neu geladen.")
            textView.string = ""
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.needsDisplay = true
        }

        scroll.documentView = textView
        textView.string = text
        textView.setSelectedRange(selectedRange)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.startModeEnabled != self.startMode {
            textView.startModeEnabled = self.startMode
            if self.startMode == false {
                textView.startModeHasStarted = false
            }
        }
        if textView.string != text {
            // Erlaube leeren Text nur, wenn der aktuelle Text auch leer ist (z. B. bei neuem Projekt)
            if !text.isEmpty || textView.string.isEmpty {
                textView.string = text
            }
        }
        if textView.selectedRange() != selectedRange {
            textView.setSelectedRange(selectedRange)
            textView.scrollRangeToVisible(selectedRange)
        }
        if let tv = context.coordinator.textView, let lm = tv.layoutManager {
            // Clear previous highlight
            let prev = context.coordinator.prevHighlight
            if prev.location != NSNotFound && prev.length > 0 {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: prev)
            }
            // Apply new highlight
            let hr = highlightRange
            if hr.location != NSNotFound && hr.length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), forCharacterRange: hr)
            }
            context.coordinator.prevHighlight = hr
            // Clear previous token highlight
            let prevTok = context.coordinator.prevTokenHighlight
            if prevTok.location != NSNotFound && prevTok.length > 0 {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: prevTok)
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: prevTok)
                lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: prevTok)
            }
            // Apply new token highlight
            let thr = tokenHighlightRange
            if thr.location != NSNotFound && thr.length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor(calibratedRed: 0/255, green: 33/255, blue: 96/255, alpha: 1.0), forCharacterRange: thr)
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.systemYellow, forCharacterRange: thr)
            }
            context.coordinator.prevTokenHighlight = thr

            // ---- Overflow (too long line) highlighting ----
            // Remove previous overflow highlights
            let prevOver = context.coordinator.prevOverflowRanges
            if !prevOver.isEmpty {
                for r in prevOver {
                    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
                }
            }

            // Recompute and apply new overflow highlights
            var newOver: [NSRange] = []
            let nsAll = tv.string as NSString
            var cursor = 0
            let maxChars = self.maxChars
            while cursor < nsAll.length {
                let lr = nsAll.lineRange(for: NSRange(location: cursor, length: 0))
                let lineStr = nsAll.substring(with: lr)
                if context.coordinator.visibleTextLength(of: lineStr) > maxChars {
                    newOver.append(lr)
                    lm.addTemporaryAttribute(.backgroundColor,
                                             value: NSColor.systemRed.withAlphaComponent(0.28),
                                             forCharacterRange: lr)
                }
                cursor = lr.upperBound
            }
            context.coordinator.prevOverflowRanges = newOver

        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextView
        weak var textView: SeekingTextView?
        var prevHighlight: NSRange = NSRange(location: NSNotFound, length: 0)
        var prevTokenHighlight: NSRange = NSRange(location: NSNotFound, length: 0)
        var isAdjustingSelection: Bool = false
        var prevOverflowRanges: [NSRange] = []
        var insertObserver: Any?
        var reflowObserver: Any?
        var focusObserver: Any?
        var refreshObserver: Any?
        init(_ parent: MacTextView) { self.parent = parent }
        deinit {
            if let o = insertObserver { NotificationCenter.default.removeObserver(o) }
            if let o = focusObserver { NotificationCenter.default.removeObserver(o) }
            if let o = refreshObserver { NotificationCenter.default.removeObserver(o) }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.selectedRange = tv.selectedRange()
            if let lrcEditor = Mirror(reflecting: parent).children.first(where: { $0.label == "text" }) {
                // Markiere, dass der User editiert hat (sicher, ohne direkte Referenz)
                (parent as? AnyObject)?.setValue(true, forKey: "hasUserEditedText")
            }
        }
        func visibleTextLength(of line: String) -> Int {
            // Remove header [mm:ss.xx]
            var s = line.replacingOccurrences(
                of: #"^\[(\d{2}):(\d{2}\.??\d*)\]\s*"#,
                with: "",
                options: .regularExpression
            )
            // Remove all token tags <mm:ss.xx>
            s = s.replacingOccurrences(
                of: #"<\s*\d{2}:\d{2}\.??\d*\s*>"#,
                with: "",
                options: .regularExpression
            )
            // Collapse whitespace
            s = s.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            return s.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        private func extractFirstTime(from line: String) -> TimeInterval? {
            if let m = line.range(of: #"<\s*(\d{2}):(\d{2}\.?\d*)\s*>"#, options: .regularExpression) {
                let tag = String(line[m]).trimmingCharacters(in: CharacterSet(charactersIn: "< >"))
                let comps = tag.split(separator: ":")
                if comps.count == 2 { return (Double(comps[0]) ?? 0) * 60 + (Double(comps[1].replacingOccurrences(of: ",", with: ".")) ?? 0) }
            }
            if let m = line.range(of: #"^\[(\d{2}):(\d{2}\.?\d*)\]"#, options: .regularExpression) {
                let tag = String(line[m]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let comps = tag.split(separator: ":")
                if comps.count == 2 { return (Double(comps[0]) ?? 0) * 60 + (Double(comps[1].replacingOccurrences(of: ",", with: ".")) ?? 0) }
            }
            return nil
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            // Avoid infinite loop while we programmatically change the selection
            if isAdjustingSelection { return }

            var sel = tv.selectedRange()
            parent.selectedRange = sel

            // Only adjust when it's a caret (no existing selection)
            if sel.length != 0 {
                return
            }

            let ns = tv.string as NSString
            let fullLen = ns.length
            if fullLen == 0 {
                return
            }

            // Clamp caret
            let caret = max(0, min(sel.location, fullLen))

            // Find nearest '<' backwards from caret (inclusive of caret-1)
            let leftSearchEnd = max(0, caret)
            let left = ns.range(of: "<", options: .backwards, range: NSRange(location: 0, length: leftSearchEnd))
            if left.location == NSNotFound {
                return
            }

            // Find next '>' forward from the '<'
            let rightSearchStart = left.location + 1
            if rightSearchStart > fullLen {
                return
            }
            let right = ns.range(of: ">", options: [], range: NSRange(location: rightSearchStart, length: fullLen - rightSearchStart))
            if right.location == NSNotFound {
                return
            }

            // Ensure caret lies between '<' and '>'
            if caret < left.location || caret > right.location {
                return
            }

            // Quick validation: must contain ':' between left and right to look like a time tag
            let midRange = NSRange(location: left.location + 1, length: max(0, right.location - left.location - 1))
            let hasColon = (ns.range(of: ":", options: [], range: midRange).location != NSNotFound)
            if !hasColon {
                return
            }

            // Looks like a token. Select the whole tag including angle brackets.
            let tagRange = NSRange(location: left.location, length: right.location - left.location + 1)

            // Apply selection without triggering recursion
            isAdjustingSelection = true
            tv.setSelectedRange(tagRange)
            parent.selectedRange = tagRange
            isAdjustingSelection = false
        }

        // MARK: - Editor Command Handlers (undo-capable)
        func insertSnippet(_ snippet: String) {
            guard let tv = textView, tv.isEditable else { return }
            let sel = tv.selectedRange()
            if tv.shouldChangeText(in: sel, replacementString: snippet) {
                tv.textStorage?.beginEditing()
                tv.textStorage?.replaceCharacters(in: sel, with: snippet)
                tv.textStorage?.endEditing()
                tv.didChangeText()
                // Move caret to end of inserted snippet
                tv.setSelectedRange(NSRange(location: sel.location + snippet.utf16.count, length: 0))
            }
            parent.text = tv.string
            parent.selectedRange = tv.selectedRange()
        }

    }
}


// MARK: - Automatically timestamp each word in timed lines
extension LRCEditorView {
    func autoTimestampWords() {
        // Split the text into lines
        let lines = self.rawLyrics.components(separatedBy: .newlines)
        var resultLines: [String] = []
        // Prepare regex for header timecode
        let headerRegex = try? NSRegularExpression(pattern: #"^\[(\d{2}):(\d{2}\.?\d*)\]"#, options: [])
        // Gather all header timecodes and their line indices
        var lineTimecodes: [(idx: Int, time: TimeInterval)] = []
        for (i, line) in lines.enumerated() {
            if let m = headerRegex?.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) {
                let mm = (line as NSString).substring(with: m.range(at: 1))
                let ss = (line as NSString).substring(with: m.range(at: 2))
                let t = parseTime(mm, ss)
                lineTimecodes.append((i, t))
            }
        }
        // For each line, process if it has header timecode
        for (i, line) in lines.enumerated() {
            if let m = headerRegex?.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) {
                let mm = (line as NSString).substring(with: m.range(at: 1))
                let ss = (line as NSString).substring(with: m.range(at: 2))
                let t1 = parseTime(mm, ss)
                let headerEnd = m.range.length
                // Find next header timecode after this line
                var t2: TimeInterval = t1 + 10.0 // default 10s if no next
                for (idx, tc) in lineTimecodes {
                    if idx > i {
                        t2 = tc
                        break
                    }
                }
                // Extract rest of line after header
                let rest = (line as NSString).substring(from: headerEnd).trimmingCharacters(in: .whitespaces)
                // Split into words (preserve spaces before punctuation)
                // We'll split by whitespace, but preserve punctuation with word
                // This is a simple split, not a linguistic tokenizer
                let words = rest.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
                let n = words.count
                var rebuilt = ""
                rebuilt += formatLineTag(t1)
                if n == 0 {
                    // No words, just header
                    resultLines.append(rebuilt)
                    continue
                }
                // Compute time for each word: equally spaced between t1 and t2, never over t2
                let step = (t2 - t1) / Double(n)
                for j in 0..<n {
                    let wordTime = t1 + step * Double(j)
                    let tag = formatTag(wordTime)
                    rebuilt += tag + words[j]
                    if j != n-1 { rebuilt += " " }
                }
                resultLines.append(rebuilt)
            } else {
                // No header timecode: leave line as is
                resultLines.append(line)
            }
        }
        // Join lines and replace editor text
        self.rawLyrics = resultLines.joined(separator: "\n")

        // --- Prompt for removing empty time tags ---
        let alert = NSAlert()
        alert.messageText = "Leere Zeitmarken entfernen?"
        alert.addButton(withTitle: "Ja")
        alert.addButton(withTitle: "Nein")
        // Try to present sheet if possible, else modal
        let removeEmptyTags: () -> Void = {
            // Split rawLyrics into lines
            var lines = self.rawLyrics.components(separatedBy: .newlines)
            // Neue Filter-Logik: Entferne nur den Timecode, aber behalte die Zeile selbst erhalten.
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Wenn die Zeile nur ein Timecode ist → entferne ihn, behalte die leere Zeile
                if trimmed.matches(pattern: #"^\[\d{2}:\d{2}\.\d{2}\]$"#) {
                    return ""
                } else {
                    return line
                }
            }
            self.rawLyrics = lines.joined(separator: "\n")
            // Optionally update lyrics model in-place:
            self.lyrics = LRCParser.parse(self.rawLyrics)
        }
        if let keyWindow = NSApp?.keyWindow {
            alert.beginSheetModal(for: keyWindow) { resp in
                if resp == .alertFirstButtonReturn {
                    removeEmptyTags()
                }
            }
        } else {
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                removeEmptyTags()
            }
        }
    }
}

// MARK: - String Regex Helper
extension String {
    func matches(pattern: String) -> Bool {
        return self.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - WaveformView
struct WaveformView: View {
    let peaks: [Float]              // normalized 0...1
    let duration: Double            // seconds
    @Binding var currentTime: Double
    @Binding var zoom: CGFloat      // 1...N
    @Binding var offset: CGFloat    // 0...1 (relative start)

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let width = size.width
                let height = size.height
                let zoomClamped = max(1, zoom)
                let visibleFraction = 1.0 / zoomClamped
                let maxOffset = max(0, 1 - visibleFraction)
                let startF = max(0, min(maxOffset, offset))
                let endF = startF + visibleFraction

                let startIndex = Int(CGFloat(peaks.count) * CGFloat(startF))
                let endIndex = min(peaks.count - 1, Int(CGFloat(peaks.count) * CGFloat(endF)))
                if endIndex <= startIndex { return }
                let count = endIndex - startIndex
                let dx = width / CGFloat(count)

                var path = Path()
                for i in 0..<count {
                    let v = CGFloat(peaks[startIndex + i])
                    let x = CGFloat(i) * dx
                    let h = v * (height - 4)
                    path.move(to: CGPoint(x: x, y: height/2 - h/2))
                    path.addLine(to: CGPoint(x: x, y: height/2 + h/2))
                }
                ctx.stroke(path, with: .color(.primary.opacity(0.85)), lineWidth: 1)

                // Playhead
                let rel = currentTime / max(duration, 0.0001)
                if rel >= startF && rel <= endF {
                    let local = (rel - startF) / visibleFraction
                    let x = CGFloat(local) * width
                    var ph = Path()
                    ph.move(to: CGPoint(x: x, y: 0))
                    ph.addLine(to: CGPoint(x: x, y: height))
                    ctx.stroke(ph, with: .color(.red), lineWidth: 2)
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let x = max(0, min(g.location.x, geo.size.width))
                    let frac = x / max(1, geo.size.width)
                    let zoomClamped = max(1, zoom)
                    let visibleFraction = 1.0 / zoomClamped
                    let startF = max(0, min(1 - visibleFraction, offset))
                    let global = startF + frac * visibleFraction
                    currentTime = Double(global) * max(0, duration)
                })
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            HStack(spacing: 8) {
                Text("Zoom")
                Slider(value: $zoom, in: 1...20, step: 0.5)
                    .frame(width: 140)
                Text("Scroll")
                Slider(value: $offset, in: 0...max(0, 1 - 1/max(zoom, 1)))
            }
            .padding(6), alignment: .bottom
        )
    }
}

// MARK: - String Range Search Helper (find all occurrences)
extension String {
    /// Returns all ranges of `searchString` in the receiver (non-overlapping).
    func ranges(of searchString: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex,
              let range = self.range(of: searchString, options: [.caseInsensitive], range: start..<endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}
