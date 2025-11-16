import SwiftUI


var lastOpenedProjectURL: URL?

// Liefert die URL zur RecentProjects.plist im Application Support-Ordner
func recentProjectsFileURL() -> URL {
    let fileManager = FileManager.default
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport.appendingPathComponent("LRC_Extended_Editor", isDirectory: true)
    if !fileManager.fileExists(atPath: dir.path) {
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }
    return dir.appendingPathComponent("RecentProjects.plist")
}

// Lädt die Liste der zuletzt geöffneten Projekte dauerhaft aus der Datei
func loadRecentProjects() -> [String] {
    let url = recentProjectsFileURL()
    guard let data = try? Data(contentsOf: url) else { return [] }
    if let arr = try? PropertyListDecoder().decode([String].self, from: data) {
        return arr
    }
    return []
}

// Speichert die Liste der zuletzt geöffneten Projekte dauerhaft in die Datei
func saveRecentProjects(_ projects: [String]) {
    let url = recentProjectsFileURL()
    if let data = try? PropertyListEncoder().encode(projects) {
        try? data.write(to: url)
    }
}

// Hilfsfunktion zum Aktualisieren der Recent Projects Liste (nun über Datei)
func updateRecentProjects(with path: String) {
    var recent = loadRecentProjects()
    // Entferne den Pfad, falls schon vorhanden
    recent.removeAll { $0 == path }
    // Füge neuen Pfad oben ein
    recent.insert(path, at: 0)
    // Maximal 5 Einträge behalten
    if recent.count > 5 {
        recent = Array(recent.prefix(5))
    }
    saveRecentProjects(recent)
    print("[AppDebug] Recent Projects dauerhaft (max 5) gespeichert: \(recent)")
}

private var currentProjectURL: URL? = nil

struct ProjectData: Codable {
    var name: String
    var timestamp: Date
    var rawLyrics: String
    var styleID: UUID?
    var audioPath: String?
}

struct ProjectManagerView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Projektverwaltung")
                .font(.largeTitle)
                .padding(.top, 20)
            Text("Hier kannst du deine gespeicherten Projekte anzeigen, öffnen oder löschen.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(minWidth: 900, minHeight: 600)
        .padding()
    }
}

struct ProjectFileMenu: Commands {
    @Binding var currentProjectName: String

    // Lade die RecentProjects-Liste beim Start
    @State private var recentProjects: [String] = loadRecentProjects()

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("Datei") {
                // MARK: Neues Projekt
                Button("Neues Projekt …") {
                    #if os(macOS)
                    currentProjectName = "Unbenannt"
                    currentProjectURL = nil
                    lastOpenedProjectURL = nil
                    UserDefaults.standard.removeObject(forKey: "LastOpenedProjectPath")
                    print("[AppDebug] Neues Projekt gestartet – Editor wird geleert.")
                    NotificationCenter.default.post(
                        name: Notification.Name("AppClearEditor"),
                        object: nil,
                        userInfo: ["force": true]
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: Notification.Name("AppForceEditorRefresh"), object: nil)
                        print("[AppDebug] Editor-Refresh nach Neuem Projekt ausgelöst.")
                    }
                    #endif
                }
                .keyboardShortcut("n", modifiers: .command)

                // MARK: Projekt öffnen
                Button("Projekt öffnen …") {
                    #if os(macOS)
                    let panel = NSOpenPanel()
                    panel.allowedFileTypes = ["fkmproj"]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canCreateDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            let data = try Data(contentsOf: url)
                            let decoder = JSONDecoder()
                            let project = try decoder.decode(ProjectData.self, from: data)
                            currentProjectName = project.name
                            currentProjectURL = url
                            lastOpenedProjectURL = url
                            print("[AppDebug] currentProjectURL gesetzt auf: \(url.path)")
                            print("[AppDebug] lastOpenedProjectURL gespeichert: \(url.path)")
                            UserDefaults.standard.set(url.path, forKey: "LastOpenedProjectPath")
                            // RecentProjects-Handling erfolgt nun über Datei
                            print("[AppDebug] LastOpenedProjectPath dauerhaft gespeichert.")
                            do {
                                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                                UserDefaults.standard.set(bookmark, forKey: "LastProjectBookmark")
                                print("[AppDebug] Security-Scoped Bookmark gespeichert.")
                            } catch {
                                print("[AppDebug] Fehler beim Erstellen des Bookmarks: \(error)")
                            }
                            if let id = project.styleID {
                                KaraokeStyleStore.shared.selectedID = id
                            }
                            NotificationCenter.default.post(
                                name: Notification.Name("AppDidOpenProject"),
                                object: project.rawLyrics
                            )
                            // AudioPath laden und an AudioPlayer senden, falls vorhanden (verzögert, damit Editor bereit ist)
                            if let audioPath = project.audioPath {
                                let audioURL = URL(fileURLWithPath: audioPath)
                                if FileManager.default.fileExists(atPath: audioURL.path) {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        NotificationCenter.default.post(
                                            name: Notification.Name("AppLoadAudioPath"),
                                            object: audioURL.path
                                        )
                                        print("[AppDebug] Audio-Datei beim Öffnen geladen (verzögert): \(audioURL.path)")
                                    }
                                } else {
                                    print("[AppDebug] Gespeicherter Audio-Pfad nicht gefunden: \(audioURL.path)")
                                }
                            }
                            if let audioPath = project.audioPath {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    NotificationCenter.default.post(
                                        name: Notification.Name("AppLoadAudioPath"),
                                        object: audioPath
                                    )
                                    print("[AppDebug] Audio-Datei direkt über Notification an Player gesendet: \(audioPath)")
                                }
                            }
                            print("Projekt geöffnet: \(url.lastPathComponent)")
                            updateRecentProjects(with: url.path)
                            recentProjects = loadRecentProjects()
                            NotificationCenter.default.post(name: Notification.Name("AppRecentProjectsUpdated"), object: nil)
                        } catch {
                            print("Fehler beim Öffnen des Projekts: \(error)")
                        }
                    }
                    #endif
                }
                .keyboardShortcut("o", modifiers: .command)

                // MARK: Projekt speichern
                Button("Projekt speichern") {
                    #if os(macOS)
                    // Stelle sicher, dass lastOpenedProjectURL korrekt aus UserDefaults geladen ist
                    if let savedPath = UserDefaults.standard.string(forKey: "LastOpenedProjectPath") {
                        lastOpenedProjectURL = URL(fileURLWithPath: savedPath)
                        print("[AppDebug] lastOpenedProjectURL geladen beim Speichern: \(savedPath)")
                    } else {
                        print("[AppDebug] Kein gespeicherter Pfad in UserDefaults gefunden.")
                    }
                    var currentLyrics: String = ""
                    var currentAudioPath: String? = nil

                    let lyricsSemaphore = DispatchSemaphore(value: 0)
                    let audioSemaphore = DispatchSemaphore(value: 0)

                    NotificationCenter.default.post(
                        name: Notification.Name("AppRequestEditorContent"),
                        object: nil,
                        userInfo: ["completion": { (lyrics: String) in
                            currentLyrics = lyrics
                            lyricsSemaphore.signal()
                        }]
                    )

                    NotificationCenter.default.post(
                        name: Notification.Name("AppRequestAudioURL"),
                        object: nil,
                        userInfo: ["completion": { (path: String?) in
                            currentAudioPath = path
                            audioSemaphore.signal()
                        }]
                    )

                    _ = lyricsSemaphore.wait(timeout: .now() + 1.0)
                    _ = audioSemaphore.wait(timeout: .now() + 1.0)

                    do {
                        // Wiederherstellung der zuletzt geöffneten Projekt-URL aus UserDefaults, falls nötig
                        if lastOpenedProjectURL == nil,
                           let savedPath = UserDefaults.standard.string(forKey: "LastOpenedProjectPath") {
                            lastOpenedProjectURL = URL(fileURLWithPath: savedPath)
                            print("[AppDebug] lastOpenedProjectURL wiederhergestellt aus UserDefaults: \(savedPath)")
                        }
                        let url: URL
                        if let existingURL = lastOpenedProjectURL {
                            url = existingURL
                            print("[AppDebug] Speichere in zuletzt geöffnetem Projekt: \(url.path)")
                        } else {
                            print("[AppDebug] Kein lastOpenedProjectURL gefunden, speichere neu.")
                            let fileName = "fkm-\(currentProjectName).fkmproj"
                            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent(fileName)
                            lastOpenedProjectURL = url
                        }
                        print("[AppDebug] AudioPath beim Speichern unter: \(currentAudioPath ?? "Keiner gefunden")")
                        let project = ProjectData(
                            name: currentProjectName,
                            timestamp: Date(),
                            rawLyrics: currentLyrics,
                            styleID: KaraokeStyleStore.shared.selectedID,
                            audioPath: currentAudioPath
                        )
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = .prettyPrinted
                        let data = try encoder.encode(project)
                        if let bookmarkData = UserDefaults.standard.data(forKey: "LastProjectBookmark") {
                            var isStale = false
                            if let securedURL = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                                print("[AppDebug] Security-Scoped Bookmark verwendet für: \(securedURL.path)")
                                if securedURL.startAccessingSecurityScopedResource() {
                                    defer { securedURL.stopAccessingSecurityScopedResource() }
                                    try data.write(to: securedURL)
                                    print("[AppDebug] Projekt über Bookmark gespeichert: \(securedURL.path)")
                                    print("[AppDebug] Projektdatei gespeichert mit AudioPath: \(currentAudioPath ?? "leer")")
                                    if let path = lastOpenedProjectURL?.path {
                                        updateRecentProjects(with: path)
                                    }
                                    return
                                } else {
                                    print("[AppDebug] Konnte Security-Scoped Resource nicht öffnen, speichere fallback...")
                                }
                            }
                        }
                        try data.write(to: url)
                        print("[AppDebug] Projektdatei gespeichert mit AudioPath: \(currentAudioPath ?? "leer")")
                        if let path = lastOpenedProjectURL?.path {
                            updateRecentProjects(with: path)
                            recentProjects = loadRecentProjects()
                        }
                        print("Projekt gespeichert: \(currentProjectName)")
                        print("Pfad: \(url.path)")
                    } catch {
                        print("Fehler beim Speichern des Projekts: \(error)")
                    }
                    #endif
                }
                .keyboardShortcut("s", modifiers: .command)

                // MARK: Projekt speichern unter …
                Button("Projekt speichern unter …") {
                    #if os(macOS)
                    var currentLyrics: String = ""
                    var currentAudioPath: String? = nil

                    let lyricsSemaphore = DispatchSemaphore(value: 0)
                    let audioSemaphore = DispatchSemaphore(value: 0)

                    NotificationCenter.default.post(
                        name: Notification.Name("AppRequestEditorContent"),
                        object: nil,
                        userInfo: ["completion": { (lyrics: String) in
                            currentLyrics = lyrics
                            lyricsSemaphore.signal()
                        }]
                    )

                    NotificationCenter.default.post(
                        name: Notification.Name("AppRequestAudioURL"),
                        object: nil,
                        userInfo: ["completion": { (path: String?) in
                            currentAudioPath = path
                            audioSemaphore.signal()
                        }]
                    )

                    _ = lyricsSemaphore.wait(timeout: .now() + 1.0)
                    _ = audioSemaphore.wait(timeout: .now() + 1.0)

                    let panel = NSSavePanel()
                    panel.allowedFileTypes = ["fkmproj"]
                    panel.nameFieldStringValue = "fkm-\(currentProjectName).fkmproj"
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            var name = url.deletingPathExtension().lastPathComponent
                            if name.hasPrefix("fkm-") {
                                name = String(name.dropFirst(4))
                            }
                            print("[AppDebug] AudioPath beim Speichern unter: \(currentAudioPath ?? "Keiner gefunden")")
                            let project = ProjectData(
                                name: name,
                                timestamp: Date(),
                                rawLyrics: currentLyrics,
                                styleID: KaraokeStyleStore.shared.selectedID,
                                audioPath: currentAudioPath
                            )
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = .prettyPrinted
                            let data = try encoder.encode(project)
                            try data.write(to: url)
                            print("[AppDebug] Projektdatei gespeichert mit AudioPath: \(currentAudioPath ?? "leer")")
                            updateRecentProjects(with: url.path)
                            recentProjects = loadRecentProjects()
                            print("Projekt gespeichert: \(currentProjectName)")
                            print("Pfad: \(url.path)")
                            currentProjectName = name
                        } catch {
                            print("Fehler beim Speichern des Projekts unter: \(error)")
                        }
                    }
                    #endif
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()
                // MARK: Zuletzt geöffnete Projekte (Recent)
                Menu("Zuletzt geöffnet") {
                    let recent = recentProjects
                    if recent.isEmpty {
                        Text("Keine letzten Projekte")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(recent.prefix(5), id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                #if os(macOS)
                                let url = URL(fileURLWithPath: path)
                                do {
                                    let data = try Data(contentsOf: url)
                                    let decoder = JSONDecoder()
                                    let project = try decoder.decode(ProjectData.self, from: data)
                                    currentProjectName = project.name
                                    currentProjectURL = url
                                    lastOpenedProjectURL = url
                                    print("[AppDebug] currentProjectURL gesetzt auf: \(url.path)")
                                    print("[AppDebug] lastOpenedProjectURL gespeichert: \(url.path)")
                                    UserDefaults.standard.set(url.path, forKey: "LastOpenedProjectPath")
                                    print("[AppDebug] LastOpenedProjectPath dauerhaft gespeichert.")
                                    do {
                                        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                                        UserDefaults.standard.set(bookmark, forKey: "LastProjectBookmark")
                                        print("[AppDebug] Security-Scoped Bookmark gespeichert.")
                                    } catch {
                                        print("[AppDebug] Fehler beim Erstellen des Bookmarks: \(error)")
                                    }
                                    if let id = project.styleID {
                                        KaraokeStyleStore.shared.selectedID = id
                                    }
                                    NotificationCenter.default.post(
                                        name: Notification.Name("AppDidOpenProject"),
                                        object: project.rawLyrics
                                    )
                                    // AudioPath laden und an AudioPlayer senden, falls vorhanden
                                    if let audioPath = project.audioPath {
                                        let audioURL = URL(fileURLWithPath: audioPath)
                                        if FileManager.default.fileExists(atPath: audioURL.path) {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                NotificationCenter.default.post(
                                                    name: Notification.Name("AppLoadAudioPath"),
                                                    object: audioURL.path
                                                )
                                                print("[AppDebug] Audio-Datei beim Öffnen geladen (verzögert): \(audioURL.path)")
                                            }
                                        } else {
                                            print("[AppDebug] Gespeicherter Audio-Pfad nicht gefunden: \(audioURL.path)")
                                        }
                                    }
                                    if let audioPath = project.audioPath {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                            NotificationCenter.default.post(
                                                name: Notification.Name("AppLoadAudioPath"),
                                                object: audioPath
                                            )
                                            print("[AppDebug] Audio-Datei direkt über Notification an Player gesendet: \(audioPath)")
                                        }
                                    }
                                    print("Projekt geöffnet: \(url.lastPathComponent)")
                                } catch {
                                    print("Fehler beim Öffnen des Projekts: \(error)")
                                }
                                // Nach Öffnen eines Projekts RecentProjects-Liste aktualisieren
                                updateRecentProjects(with: path)
                                recentProjects = loadRecentProjects()
                                #endif
                            }
                        }
                    }
                }
            }
        }
    }
}
