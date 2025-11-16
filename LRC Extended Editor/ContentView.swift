// Weihnachten mit Dir – macOS Karaoke / Lyrics Highlighter
// SwiftUI macOS app that loads an audio file and a timed-lyrics (.lrc-like) text
// with absolute timestamps and per-word timestamps like <mm:ss.xx>
//
// Drop this into a new Xcode project (App template, SwiftUI, macOS) as ContentView.swift
// Xcode 15+ / macOS 14+ recommended



import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers
import QuartzCore
import Foundation
import VideoToolbox





#if DEBUG
@inline(__always) func debugTitle(_ message: @autoclosure () -> String) {
    print("[TitleDebug] \(message())")
}

import AppKit

/// Setzt den Fenstertitel des Hauptfensters
func setMainWindowTitle(_ title: String) {
    if let window = NSApplication.shared.windows.first {
        window.title = title
    }
}
#else
@inline(__always) func debugTitle(_ message: @autoclosure () -> String) {}

#endif



// MARK: - Models
struct LyricToken: Identifiable, Hashable {
    let id: UUID
    let time: TimeInterval // absolute seconds from 0.0
    let text: String

    init(id: UUID = UUID(), time: TimeInterval, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let startTime: TimeInterval // first timestamp in the line (optional)
    let tokens: [LyricToken]
    let label: String? // e.g. "[Chorus]"
}

struct LyricsDocument: Hashable {
    let title: String?
    let artist: String?
    let album: String?
    let by: String?
    let lines: [LyricLine]
}

// MARK: - Parser for the provided format
final class LRCParser {
    static func parse(_ text: String) -> LyricsDocument {
        var title: String?
        var artist: String?
        var album: String?
        var by: String?
        var lines: [LyricLine] = []
        var lastTime: TimeInterval = 0

        // Vereinheitliche Zeilenenden
        let linesRaw = text.replacingOccurrences(of: "\r\n", with: "\n")
                           .replacingOccurrences(of: "\r", with: "\n")
                           .components(separatedBy: "\n")

        let timePattern = #"\[(\d{2}):(\d{2}(?:\.\d{1,2})?)\]"#
        let timeRegex = try! NSRegularExpression(pattern: timePattern)
        let wordPattern = #"<(\d{2}):(\d{2}(?:\.\d{1,2})?)>"#
        let wordRegex = try! NSRegularExpression(pattern: wordPattern)

        func parseTime(_ mm: String, _ ss: String) -> TimeInterval {
            let m = Double(mm) ?? 0
            let s = Double(ss.replacingOccurrences(of: ",", with: ".")) ?? 0
            return m * 60 + s
        }

        for rawLine in linesRaw {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Kopfzeilen wie [ti:], [ar:], [al:], [by:]
            if line.hasPrefix("[ti:") || line.hasPrefix("[ar:") ||
               line.hasPrefix("[al:") || line.hasPrefix("[by:]") {
                let key = line.dropFirst(1).prefix(2).lowercased()
                let value = line.replacingOccurrences(of: "[\(key):", with: "")
                                .replacingOccurrences(of: "]", with: "")
                                .trimmingCharacters(in: .whitespaces)
                switch key {
                case "ti": title = value
                case "ar": artist = value
                case "al": album = value
                case "by": by = value
                default: break
                }
                continue
            }

            // Finde Zeilenzeit (z. B. [01:15.34])
            guard let timeMatch = timeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let mm = (line as NSString).substring(with: timeMatch.range(at: 1))
            let ss = (line as NSString).substring(with: timeMatch.range(at: 2))
            let lineTime = parseTime(mm, ss)
            lastTime = lineTime

            // Entferne Zeilenzeit aus Text
            let afterTimeIndex = Range(timeMatch.range, in: line)!.upperBound
            let content = line[afterTimeIndex...].trimmingCharacters(in: .whitespaces)

            // Enthält Wort-Timings?
            let wordMatches = wordRegex.matches(in: String(content), range: NSRange(content.startIndex..., in: content))
            if wordMatches.isEmpty {
                // Ganze Zeile mit einem Token
                let token = LyricToken(time: lineTime, text: content)
                lines.append(LyricLine(startTime: lineTime, tokens: [token], label: nil))
            } else {
                var tokens: [LyricToken] = []
                var lastEnd = content.startIndex
                for match in wordMatches {
                    let mm = (content as NSString).substring(with: match.range(at: 1))
                    let ss = (content as NSString).substring(with: match.range(at: 2))
                    let tokTime = parseTime(mm, ss)
                    let end = content.index(content.startIndex, offsetBy: match.range.location + match.range.length)
                    let nextStart = end < content.endIndex ? end : content.endIndex
                    let wordText = content[nextStart...].split(separator: "<", maxSplits: 1).first ?? ""
                    let textPart = wordText.trimmingCharacters(in: .whitespaces)
                    if !textPart.isEmpty {
                        tokens.append(LyricToken(time: tokTime, text: textPart))
                    }
                    lastEnd = nextStart
                }
                lines.append(LyricLine(startTime: lineTime, tokens: tokens, label: nil))
            }
        }

        return LyricsDocument(title: title, artist: artist, album: album, by: by, lines: lines)
    }

    static func reflow(_ doc: LyricsDocument, minGap: TimeInterval = 0.02) -> LyricsDocument {
        guard !doc.lines.isEmpty else { return doc }
        var newLines: [LyricLine] = []

        for i in 0..<doc.lines.count {
            let line = doc.lines[i]
            guard !line.tokens.isEmpty else { newLines.append(line); continue }

            let start = line.tokens.first!.time
            let nextStart: TimeInterval? = i + 1 < doc.lines.count ? doc.lines[i + 1].tokens.first?.time : nil
            let end = nextStart ?? (line.tokens.last!.time + 0.5)
            var toks = line.tokens

            for j in 1..<toks.count {
                if toks[j].time <= toks[j-1].time {
                    toks[j] = LyricToken(id: toks[j].id, time: toks[j-1].time + minGap, text: toks[j].text)
                }
            }

            if toks.last!.time > end {
                let first = toks.first!.time
                let scale = (end - first) / (toks.last!.time - first)
                toks = toks.map { tok in
                    let newT = first + (tok.time - first) * scale
                    return LyricToken(id: tok.id, time: newT, text: tok.text)
                }
            }

            newLines.append(LyricLine(startTime: start, tokens: toks, label: line.label))
        }

        return LyricsDocument(title: doc.title, artist: doc.artist, album: doc.album, by: doc.by, lines: newLines)
    }
}

// MARK: - Audio Player
final class AudioPlayer: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0
    var currentURL: URL?

    private var player: AVAudioPlayer?
#if os(macOS)
    private var timer: Timer?
#else
    private var displayLink: CADisplayLink?
#endif

    func load(url: URL) throws {
        stop()
        self.currentURL = url
        self.player = try AVAudioPlayer(contentsOf: url)
        self.player?.prepareToPlay()
        self.duration = self.player?.duration ?? 0
        startDisplayLink()
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        isPlaying = false
        currentTime = 0
        duration = player?.duration ?? 0
        stopDisplayLink()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    private func startDisplayLink() {
#if os(macOS)
        stopDisplayLink()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
#else
        stopDisplayLink()
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
#endif
    }

    private func stopDisplayLink() {
#if os(macOS)
        timer?.invalidate()
        timer = nil
#else
        displayLink?.invalidate()
        displayLink = nil
#endif
    }

    @objc private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying { isPlaying = false }
    }
}

// MARK: - Karaoke Token View
struct TokenHighlightView: View {
    let token: LyricToken
    let nextTokenTime: TimeInterval
    let currentTime: TimeInterval

    private var progress: CGFloat {
        if currentTime <= token.time { return 0 }
        if currentTime >= nextTokenTime { return 1 }
        let span = max(0.01, nextTokenTime - token.time)
        return CGFloat((currentTime - token.time) / span)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(token.text)
                .font(.title2)
                .opacity(0.25)
            GeometryReader { geo in
                let width = geo.size.width * progress
                Text(token.text)
                    .font(.title2)
                    .mask(
                        Rectangle()
                            .frame(width: width)
                            .alignmentGuide(.leading) { d in d[.leading] }
                    )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(.linear(duration: 0.05), value: progress)
    }
}

// MARK: - Line View
struct KaraokeLineView: View {
    let line: LyricLine
    let currentTime: TimeInterval

    var body: some View {
        if let label = line.label { // Section header
            Text(label)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else {
            HStack(spacing: 8) {
                ForEach(0..<line.tokens.count) { idx in
                    let tok = line.tokens[idx]
                    let nextT = idx < line.tokens.count - 1 ? line.tokens[idx+1].time : tok.time + 0.35
                    TokenHighlightView(token: tok, nextTokenTime: nextT, currentTime: currentTime)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - File Helpers
struct FileButtons: View {
    @Binding var lyrics: LyricsDocument?
    @ObservedObject var audio: AudioPlayer
    @State private var lyricsError: String?
    @State private var audioError: String?
    var onLoadRaw: (String) -> Void = { _ in }
    var onAudioPicked: (URL) -> Void = { _ in }
    var onLyricsPicked: (URL) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            Button("Audio laden…") {
                pickFile(allowed: ["mp3", "m4a", "wav", "aiff"]) { url in
                    do { try audio.load(url: url); onAudioPicked(url) } catch { audioError = error.localizedDescription }
                }
            }
            Button("Lyrics laden…") {
                pickFile(allowed: ["lrc", "txt"]) { url in
                    if let str = try? String(contentsOf: url, encoding: .utf8) {
                        onLoadRaw(str)
                        lyrics = LRCParser.reflow(LRCParser.parse(str))
                        onLyricsPicked(url)
                    } else {
                        lyricsError = "Konnte Datei nicht lesen."
                    }
                }
            }
            if let te = audioError { Text(te).foregroundStyle(.red) }
            if let le = lyricsError { Text(le).foregroundStyle(.red) }
            Spacer()
        }
    }

    private func pickFile(allowed: [String], onPick: @escaping (URL)->Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) }
        panel.begin { resp in
            if resp == .OK, let url = panel.url { onPick(url) }
        }
    }
}

// MARK: - Transport & Timeline
struct TransportBar: View {
    @ObservedObject var audio: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { audio.isPlaying ? audio.pause() : audio.play() }) {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
            }
            Button(action: { audio.seek(to: max(0, audio.currentTime - 5)) }) {
                Image(systemName: "gobackward.5")
            }
            Button(action: { audio.seek(to: min(audio.duration, audio.currentTime + 5)) }) {
                Image(systemName: "goforward.5")
            }
            Slider(value: Binding(get: { audio.currentTime }, set: { audio.seek(to: $0) }), in: 0...(audio.duration > 0 ? audio.duration : 1))
            Text(timeString(audio.currentTime)).monospacedDigit()
            Text("/")
            Text(timeString(audio.duration)).monospacedDigit()
        }
        .buttonStyle(.bordered)
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "00:00" }
        let mm = Int(t) / 60
        let ss = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        return String(format: "%02d:%02d.%02d", mm, ss, cs)
    }
}

// MARK: - Keyboard Helper (macOS)
#if os(macOS)
import AppKit

struct KeyCatcher: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onKeyDown: onKeyDown) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.start()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class Coordinator {
        var onKeyDown: (NSEvent) -> Void
        var monitor: Any?
        init(onKeyDown: @escaping (NSEvent) -> Void) { self.onKeyDown = onKeyDown }
        func start() {
            stop()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                self?.onKeyDown(e)
                return e
            }
        }
        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
        deinit { stop() }
    }
}
#endif

// MARK: - Main View
struct ContentView: View {
    @State private var editorMode: Int = 0 // 0 = Editor, 2 = Karaoke, 3 = Einstellungen
    @State private var rawLyrics: String = ""
    @State private var lyrics: LyricsDocument? = nil
    @StateObject private var audio = AudioPlayer()
    @State private var includeAudio: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Modus", selection: $editorMode) {
                Text("Editor").tag(0)
                Text("Karaoke").tag(2)
                Text("Video Creator").tag(4)
                Text("Einstellungen").tag(3)
            }
            .pickerStyle(.segmented)

            if editorMode == 0 {
                LRCEditorView(
                    rawLyrics: $rawLyrics,
                    lyrics: $lyrics,
                    audio: audio,
                    onApply: {
                        lyrics = LRCParser.reflow(LRCParser.parse(rawLyrics))
                    },
                    onSave: { saveRawLyrics() }
                )
            }

            if editorMode == 2 {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lyrics?.title ?? "Keine Lyrics geladen")
                            .font(.largeTitle).bold()
                        if let a = lyrics?.artist { Text(a).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }

                TransportBar(audio: audio)
                KaraokePlayerView(lyrics: $lyrics, audio: audio, initialLinesToShow: 5)
            }
            if editorMode == 4 {
                VideoCreatorView(audio: audio, lyrics: lyrics)
            }
            if editorMode == 3 {
                SettingsView()
            }
#if os(macOS)
            KeyCatcher(onKeyDown: { e in handleKey(e) })
                .frame(width: 0, height: 0)
#endif
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppLoadAudioPath"))) { note in
            if let path = note.object as? String {
                print("[AppDebug] ContentView empfängt AppLoadAudioPath mit Pfad: \(path)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let url = URL(fileURLWithPath: path)
                    do {
                        try audio.load(url: url)
                        print("[AppDebug] Audio-Datei im Player geladen: \(url.lastPathComponent)")
                    } catch {
                        print("[AppDebug] Fehler beim Laden der Audio-Datei in ContentView: \(error)")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppRequestAudioURL"))) { note in
            if let completion = note.userInfo?["completion"] as? (String?) -> Void {
                let path = audio.currentURL?.path
                print("[AppDebug] AppRequestAudioURL empfangen – sende Pfad: \(path ?? "nil")")
                completion(path)
            } else {
                print("[AppDebug] AppRequestAudioURL empfangen – aber kein completion Handler vorhanden.")
            }
        }
        .onAppear {
            print("[StartupDebug] Resetting all editor states — fresh start")
            lyrics = nil
            rawLyrics = ""
            // Entferne alle gespeicherten UserDefaults und Bookmarks komplett
            let defaults = UserDefaults.standard
            if let appDomain = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: appDomain)
            }
            defaults.synchronize()

            // Lösche ggf. gespeicherte Dateien im Application Support
            let fileManager = FileManager.default
            if let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? fileManager.removeItem(at: supportDir)
            }
            print("[StartupDebug] Vollständiger Reset: UserDefaults & gespeicherte Dateien gelöscht.")

            audio.stop()
            audio.currentTime = 0
            // Update window title from current rawLyrics
            do {
                let lines = rawLyrics.replacingOccurrences(of: "\r\n", with: "\n")
                                      .replacingOccurrences(of: "\r", with: "\n")
                                      .components(separatedBy: "\n")
                if let raw = lines.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("[ti:") }) {
                    let ti = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
                    NotificationCenter.default.post(name: Notification.Name("AppSetWindowTitle"), object: rawLyrics)
                    debugTitle("ContentView.onAppear parsed title='\(ti)'")
                    setMainWindowTitle("LRC Extended Editor \(ti)")
                } else {
                    NotificationCenter.default.post(name: Notification.Name("AppSetWindowTitle"), object: rawLyrics)
                    debugTitle("ContentView.onAppear no [ti:] found; posted AppSetWindowTitle len=\(rawLyrics.count)")
                }
            }
        }
        .onChange(of: rawLyrics) { oldValue, newValue in
            // live-update model so Karaoke reflect editor changes immediately
            lyrics = LRCParser.reflow(LRCParser.parse(newValue))
            do {
                let lines = newValue.replacingOccurrences(of: "\r\n", with: "\n")
                                     .replacingOccurrences(of: "\r", with: "\n")
                                     .components(separatedBy: "\n")
                if let raw = lines.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("[ti:") }) {
                    let ti = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
                    NotificationCenter.default.post(name: Notification.Name("AppSetWindowTitle"), object: newValue)
                    debugTitle("ContentView.onChange parsed title='\(ti)'")
                    setMainWindowTitle("LRC Extended Editor \(ti)")
                } else {
                    NotificationCenter.default.post(name: Notification.Name("AppSetWindowTitle"), object: newValue)
                    debugTitle("ContentView.onChange no [ti:] found; posted AppSetWindowTitle len=\(newValue.count)")
                }
            }
        }
    }

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
        rawLyrics.append(formatTag(audio.currentTime))
    }

    private func insertLineTimestamp() {
        let tag = formatLineTag(audio.currentTime)
        if rawLyrics.last == "\n" || rawLyrics.isEmpty {
            rawLyrics.append(tag)
        } else {
            rawLyrics.append("\n" + tag)
        }
    }

    private func saveRawLyrics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc")!, UTType.plainText]
        panel.nameFieldStringValue = (lyrics?.title ?? "lyrics") + ".lrc"
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try rawLyrics.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    // Optional: handle error UI
                }
            }
        }
    }

    // MARK: - Video Export
    @MainActor
    private func startVideoExport() {
        guard let lyrics = lyrics else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.movie]
        panel.nameFieldStringValue = "karaoke.mov"

        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                let videoCreator = VideoCreator.shared
                let settings = VideoRenderSettings(
                    resolution: "1080p (1920x1080)",
                    framerate: "30 fps",
                    format: "MOV (.mov)",
                    includeAudio: includeAudio
                )

                videoCreator.createVideo(
                    lyrics: lyrics,
                    audio: audio,
                    audioURL: includeAudio ? audio.currentURL : nil,
                    style: KaraokeStyleStore.shared.selectedStyle,
                    settings: settings,
                    outputURL: url,
                    progressUpdate: { progress, message in
                        print("[VideoCreator] \(Int(progress * 100))% – \(message)")
                    },
                    completion: { result in
                        switch result {
                        case .success(let finalURL):
                            print("✅ Video export completed: \(finalURL)")
                        case .failure(let error):
                            print("❌ Video export failed: \(error)")
                        }
                    }
                )
            }
        }
    }

#if os(macOS)
    private func handleKey(_ e: NSEvent) {
        // Kein Reset des Editors mehr – nur Tasteneingaben auswerten
        let isSpace = (e.keyCode == 49) || (e.charactersIgnoringModifiers == " ")
        let isCmdS = (e.modifierFlags.contains(.command) && (e.charactersIgnoringModifiers?.lowercased() == "s"))
        if isSpace {
            if editorMode == 0 {
                insertWordTimestamp()
            } else {
                audio.isPlaying ? audio.pause() : audio.play()
            }
        } else if isCmdS {
            saveRawLyrics()
        }
    }
#endif
}

