import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - VideoCreatorView
struct VideoCreatorView: View {
    @ObservedObject var audio: AudioPlayer
    let lyrics: LyricsDocument?

    @State private var selectedResolution = "1080p (1920x1080)"
    @State private var selectedFramerate = "30 fps"
    @State private var selectedFormat = "MOV (.mov)"
    @State private var includeAudio = true
    @State private var isRendering = false
    @State private var progress: Double = 0.0
    @State private var renderMessage: String = ""

    @ObservedObject private var styleStore = KaraokeStyleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("🎬 Video Creator").font(.largeTitle).bold()

            Toggle("Audio einbetten", isOn: $includeAudio)
                .toggleStyle(.switch)
                .padding(.vertical, 8)

            HStack(spacing: 16) {
                Picker("Videoauflösung", selection: $selectedResolution) {
                    Text("720p (1280x720)").tag("720p (1280x720)")
                    Text("1080p (1920x1080)").tag("1080p (1920x1080)")
                    Text("4K (3840x2160)").tag("4K (3840x2160)")
                }
                .frame(width: 200)

                Picker("Framerate", selection: $selectedFramerate) {
                    Text("24 fps").tag("24 fps")
                    Text("30 fps").tag("30 fps")
                    Text("60 fps").tag("60 fps")
                }
                .frame(width: 150)

                Picker("Format", selection: $selectedFormat) {
                    Text("MOV (.mov)").tag("MOV (.mov)")
                    Text("MP4 (.mp4)").tag("MP4 (.mp4)")
                }
                .frame(width: 150)
            }

            Divider()

            if isRendering {
                VStack(alignment: .leading) {
                    ProgressView(value: progress)
                    Text(renderMessage).font(.caption).foregroundColor(.secondary)
                }
            } else {
                Button(action: startExport) {
                    Label("Video erstellen", systemImage: "film.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(24)
    }

    private func startExport() {
        guard let lyrics = lyrics else {
            renderMessage = "❌ Keine Lyrics geladen."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.movie]
        panel.nameFieldStringValue = "karaoke"

        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                // Immer die gewünschte Endung anhängen
                var finalURL = url.appendingPathExtension(VideoRenderSettings(resolution: selectedResolution, framerate: selectedFramerate, format: selectedFormat, includeAudio: includeAudio).fileExtension)

                // Prüfen, ob Datei bereits existiert
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    let alert = NSAlert()
                    alert.messageText = "Datei existiert bereits"
                    alert.informativeText = "Möchtest du die bestehende Datei überschreiben?"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Überschreiben")
                    alert.addButton(withTitle: "Abbrechen")
                    let response = alert.runModal()
                    if response != .alertFirstButtonReturn {
                        renderMessage = "❌ Abgebrochen – Datei wurde nicht überschrieben."
                        return
                    }
                    try? FileManager.default.removeItem(at: finalURL)
                }
                isRendering = true
                progress = 0
                renderMessage = "Starte Rendering..."

                let settings = VideoRenderSettings(
                    resolution: selectedResolution,
                    framerate: selectedFramerate,
                    format: selectedFormat,
                    includeAudio: includeAudio
                )

                VideoCreator.shared.createVideo(
                    lyrics: lyrics,
                    audio: audio,
                    audioURL: includeAudio ? audio.currentURL : nil,
                    style: styleStore.selectedStyle,
                    settings: settings,
                    outputURL: finalURL
                ) { progressValue, message in
                    DispatchQueue.main.async {
                        progress = progressValue
                        renderMessage = message
                    }
                } completion: { result in
                    DispatchQueue.main.async {
                        isRendering = false
                        switch result {
                        case .success(let finalURL):
                            renderMessage = "✅ Fertiggestellt: \(finalURL.lastPathComponent)"
                        case .failure(let error):
                            renderMessage = "❌ Fehler: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}

// MARK: - VideoRenderSettings
struct VideoRenderSettings {
    let resolution: String
    let framerate: String
    let format: String
    let includeAudio: Bool

    var size: CGSize {
        switch resolution {
        case "720p (1280x720)": return CGSize(width: 1280, height: 720)
        case "4K (3840x2160)": return CGSize(width: 3840, height: 2160)
        default: return CGSize(width: 1920, height: 1080)
        }
    }

    var fps: Int {
        switch framerate {
        case "24 fps": return 24
        case "60 fps": return 60
        default: return 30
        }
    }

    var fileExtension: String {
        format.contains("MP4") ? "mp4" : "mov"
    }
}

// MARK: - VideoCreator
final class VideoCreator {

    // MARK: - KaraokeRenderView (wie KaraokePlayerView)
    struct KaraokeRenderView: View {
        let lyrics: LyricsDocument
        let currentTime: TimeInterval
        let style: KaraokeStyle
        @ObservedObject private var styleStore = KaraokeStyleStore.shared
        private let linesToShow: Int = 3

        private var lines: [LyricLine] { lyrics.lines }

        private func tagValue(_ key: String) -> String? {
            let aliases: [String: [String]] = [
                "ti": ["ti", "title", "song", "name"],
                "ar": ["ar", "artist", "singer"],
                "al": ["al", "album", "record"],
                "by": ["by", "editor", "creator"]
            ]
            let want = Set((aliases[key.lowercased()] ?? [key]).map { $0.lowercased() })
            func matchKey(_ k: String) -> Bool { want.contains(k.lowercased()) }
            func fromDict(_ d: [String: String]) -> String? {
                for (k,v) in d where matchKey(k) { return v }
                return nil
            }
            func fromRaw(_ s: String) -> String? {
                let lines = s.split(whereSeparator: \.isNewline).prefix(24)
                for line in lines {
                    let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard s.hasPrefix("["), s.hasSuffix("]"), let colon = s.firstIndex(of: ":") else { continue }
                    let inner = s.dropFirst().dropLast()
                    let k = inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if matchKey(k) { return String(v) }
                }
                return nil
            }
            var visited = Set<ObjectIdentifier>()
            func fromAny(_ any: Any) -> String? {
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
                        if let label = child.label, matchKey(label), let v = child.value as? String { return v }
                        if let v = fromAny(child.value) { return v }
                    }
                }
                if let arr = any as? [Any] {
                    for item in arr { if let v = fromAny(item) { return v } }
                }
                return nil
            }
            if let v = fromAny(lyrics) { return v }
            let m = Mirror(reflecting: lyrics)
            for name in ["raw", "rawText", "text", "source", "sourceText", "original", "originalText"] {
                if let s = m.children.first(where: { $0.label == name })?.value as? String, let v = fromRaw(s) { return v }
            }
            return nil
        }

        private func timeUntilFirstStart() -> TimeInterval {
            guard let first = lines.first(where: { ($0.tokens.first?.time ?? $0.startTime) > 0 }) else { return 0 }
            let t = (first.tokens.first?.time ?? first.startTime)
            return max(0, t - currentTime)
        }

        private func windowStart() -> Int {
            let idx = activeLineIndex()
            let half = linesToShow / 2
            let maxStart = max(0, lines.count - linesToShow)
            let start = min(max(0, idx - half), maxStart)
            return start
        }

        private func linesToShowCount() -> Int {
            min(linesToShow, lines.count)
        }

        private func visibleLines() -> [LyricLine] {
            let start = windowStart()
            let count = linesToShowCount()
            guard start < lines.count else { return [] }
            return Array(lines[start..<min(start+count, lines.count)])
        }

        private func activeLineIndex() -> Int {
            let idx = lines.lastIndex(where: { ($0.tokens.first?.time ?? $0.startTime) <= currentTime }) ?? 0
            return idx
        }

        private func nextStartAfter(_ line: LyricLine) -> TimeInterval? {
            guard let idx = lines.firstIndex(where: { $0.id == line.id }) else { return nil }
            let next = idx + 1
            guard next < lines.count else { return nil }
            return lines[next].tokens.first?.time ?? lines[next].startTime
        }

        private func fadeForLine(_ idx: Int) -> Double {
            let center = windowStart() + linesToShow / 2
            let dist = abs(idx - center)
            if linesToShow <= 2 { return 1.0 }
            if dist == 0 { return 1.0 }
            if dist == 1 { return 0.8 }
            if dist == 2 { return 0.5 }
            return 0.3
        }

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        style.gradientTop?.color ?? .black,
                        style.gradientBottom?.color ?? .blue
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if timeUntilFirstStart() > 0 {
                    VStack(spacing: 12) {
                        Spacer()
                        if let title = tagValue("ti"), !title.isEmpty {
                            Text(title)
                                .font(.system(size: 64, weight: .bold))
                                .foregroundColor(styleStore.selectedStyle.foreground.color)
                                .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                                              width: styleStore.selectedStyle.outlineWidth,
                                              alpha: Double(styleStore.selectedStyle.outlineAlpha))
                        }
                        if let artist = tagValue("ar"), !artist.isEmpty {
                            Text(artist)
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundColor(styleStore.selectedStyle.foreground.color)
                                .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                                              width: styleStore.selectedStyle.outlineWidth,
                                              alpha: Double(styleStore.selectedStyle.outlineAlpha))
                        }
                        let countdown = Int(ceil(timeUntilFirstStart()))
                        if countdown > 0 && countdown < 5 {
                            Text("\(countdown)")
                                .font(.system(size: 48, weight: .black))
                                .foregroundColor(styleStore.selectedStyle.foreground.color)
                                .outlinedText(color: styleStore.selectedStyle.outlineColor.color,
                                              width: styleStore.selectedStyle.outlineWidth,
                                              alpha: Double(styleStore.selectedStyle.outlineAlpha))
                                .padding(.top, 16)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: style.lineSpacing) {
                            ForEach(Array(visibleLines().enumerated()), id: \.element.id) { (offset, line) in
                                let idx = windowStart() + offset
                                KaraokeRenderLineRow(
                                    line: line,
                                    currentTime: currentTime,
                                    isActive: (line.id == visibleLines()[linesToShow / 2].id),
                                    fade: fadeForLine(idx),
                                    nextLineStart: nextStartAfter(line),
                                    style: styleStore.selectedStyle
                                )
                                .opacity(fadeForLine(idx))
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: activeLineIndex())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 60)
                        .padding(.vertical, (NSScreen.main?.frame.height ?? 1080) * 0.1)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - KaraokeRenderLineRow (Wort-Highlighting)
    struct KaraokeRenderLineRow: View {
        let line: LyricLine
        let currentTime: TimeInterval
        let isActive: Bool
        let fade: Double  // 1.0 = fully visible, 0.0 = fully invisible
        let nextLineStart: TimeInterval?
        let style: KaraokeStyle

        private func fontSize(for geo: GeometryProxy) -> CGFloat {
            let usableWidth = geo.size.width * 0.8
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
                    if let nls = nextLineStart { return max(tok.time, nls) }
                    return tok.time + 0.35
                }()
                let activeTok = isActiveToken(start: tok.time, end: nextT)

                let fillColor: NSColor = (activeTok ? style.highlight.nsColor : style.foreground.nsColor)
                let word = NSMutableAttributedString(string: tok.text)
                word.addAttributes([
                    .strokeColor: style.outlineColor.nsColor,
                    .foregroundColor: fillColor,
                    .strokeWidth: -max(2.0, style.outlineWidth * 2.0),
                    .font: font
                ], range: NSRange(location: 0, length: word.length))
                fullText.append(word)

                if i < line.tokens.count - 1 {
                    let space = NSMutableAttributedString(string: " ")
                    space.addAttributes([
                        .strokeColor: style.outlineColor.nsColor,
                        .foregroundColor: (activeTok ? style.highlight.nsColor : style.foreground.nsColor),
                        .strokeWidth: -max(2.0, style.outlineWidth * 2.0),
                        .font: font
                    ], range: NSRange(location: 0, length: space.length))
                    fullText.append(space)
                }
            }

            return Text(AttributedString(fullText))
        }

        var body: some View {
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
                    .outlinedText(color: style.outlineColor.color,
                                   width: style.outlineWidth,
                                   alpha: (fade >= 1 ? Double(style.outlineAlpha) : 0))
                    .frame(width: max(0, geo.size.width * 0.8), alignment: .center)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

    static let shared = VideoCreator()

    func createVideo(
        lyrics: LyricsDocument,
        audio: AudioPlayer,
        audioURL: URL?,
        style: KaraokeStyle,
        settings: VideoRenderSettings,
        outputURL: URL,
        progressUpdate: @escaping (Double, String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("[VideoDebug] 🎬 createVideo started")
                let size = settings.size
                let fps = settings.fps
                print("[VideoDebug] Resolution: \(size), FPS: \(fps), Format: \(settings.format), Output: \(outputURL.path)")
                if let audioURL = audioURL { print("[VideoDebug] Audio URL: \(audioURL.path)") } else { print("[VideoDebug] No audio file (silent mode)") }

                // Audio- oder LRC-Dauer bestimmen — immer bis zum Ende des letzten Tags!
                let asset = audioURL != nil ? AVURLAsset(url: audioURL!) : nil
                let audioDuration = asset?.duration.seconds ?? 0

                // Berechne die Länge der Lyrics bis zur letzten Zeitmarke
                let lyricDuration = lyrics.lines
                    .compactMap { line in
                        if let last = line.tokens.last?.time { return last }
                        if line.startTime > 0 { return line.startTime }
                        return nil
                    }
                    .max() ?? 10.0

                // Gesamtdauer = immer bis zum Ende der Lyrics, ggf. länger falls Audio > Lyrics
                let totalDuration = max(audioDuration, lyricDuration)
                let totalFrames = Int(totalDuration * Double(fps))

                // Audio pausieren, um Konflikte zu vermeiden
                DispatchQueue.main.sync {
                    audio.pause()
                }

                // Sicherstellen, dass die Datei existiert oder erstellt werden kann
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    print("[VideoDebug] ⚠️ Datei \(outputURL.lastPathComponent) existiert bereits, wird überschrieben")
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    print("[VideoDebug] ✅ Verwende neuen Speicherpfad: \(outputURL.path)")
                }
                // Asset Writer vorbereiten
                let writer = try AVAssetWriter(outputURL: outputURL,
                                               fileType: settings.format.contains("MP4") ? .mp4 : .mov)
                print("[VideoDebug] AVAssetWriter created and started")

                let settingsDict: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: size.width,
                    AVVideoHeightKey: size.height
                ]

                let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settingsDict)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
                                                                   sourcePixelBufferAttributes: nil)
                writer.add(writerInput)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                print("[VideoDebug] Starting frame rendering loop")
                // Frame Rendering Schleife
                for frame in 0..<totalFrames {
                    let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                    if !writerInput.isReadyForMoreMediaData {
                        print("[VideoDebug] ⚠️ Input not ready for more media data at frame \(frame)")
                    }
                    while !writerInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }

                    DispatchQueue.main.sync {
                        let timeInSeconds = Double(frame) / Double(fps)
                        let renderFrame = KaraokeRenderView(lyrics: lyrics, currentTime: timeInSeconds, style: style)
                            .frame(width: size.width, height: size.height)
                        let renderer = ImageRenderer(content: renderFrame)
                        renderer.scale = 1.0

                        if let cgImage = renderer.cgImage,
                           let buffer = self.pixelBuffer(from: cgImage, size: size) {
                            adaptor.append(buffer, withPresentationTime: time)
                        }
                    }

                    if frame % (fps * 10) == 0 { print("[VideoDebug] Frame \(frame)/\(totalFrames)") }

                    // Fortschritt alle 5 Sekunden (bei 30 fps = 150 Frames)
                    if frame % (fps * 5) == 0 {
                        let progressValue = Double(frame) / Double(totalFrames)
                        DispatchQueue.main.async {
                            progressUpdate(progressValue, "Rendering Frame \(frame)/\(totalFrames)")
                        }
                    }
                }
                print("[VideoDebug] Finished frame rendering loop")

                print("[VideoDebug] 🏁 Marking input finished, waiting for writer to complete")
                writerInput.markAsFinished()
                writer.finishWriting {
                    print("[VideoDebug] Writer finished with status: \(writer.status.rawValue)")
                    if let err = writer.error { print("[VideoDebug] ❌ Writer error: \(err.localizedDescription)") }
                    if writer.status == .completed {
                        DispatchQueue.main.async {
                            completion(.success(outputURL))
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(writer.error ?? NSError(domain: "VideoCreator", code: -1)))
                        }
                    }
                }
            } catch {
                print("[VideoDebug] ❌ Exception during createVideo: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32ARGB, attrs, &buffer)
        guard status == kCVReturnSuccess, let pxBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pxBuffer, [])
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pxBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pxBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pxBuffer, [])
        return pxBuffer
    }
}
