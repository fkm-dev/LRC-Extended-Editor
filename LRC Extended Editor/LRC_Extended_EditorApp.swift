import Combine
import SwiftUI


final class AppState: ObservableObject {
    @Published var showOpenView: Bool = true
    @Published var currentProjectURL: URL? = nil
}

@main
struct LRC_Extended_EditorApp: App {
    @StateObject private var appState = AppState()
    @State private var currentProjectName = "Unbenannt"
    @State private var viewID = UUID()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(viewID)
                // MARK: - Empfängt Öffnen-Befehl (Projektdatei)
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppRequestOpenProject"))) { notification in
                    if let url = notification.object as? URL {
                        print("[AppDebug] Projekt öffnen empfangen: \(url.path)")
                        print("[AppDebug] Vollständiger Pfad zur Projektdatei: \(url.path)")
                        currentProjectName = url.deletingPathExtension().lastPathComponent
                        print("[AppDebug] currentProjectName gesetzt auf: \(currentProjectName)")
                        appState.currentProjectURL = url
                        print("[AppDebug] currentProjectURL gesetzt auf: \(url.path)")
                        appState.showOpenView = false
                        print("[AppDebug] Neues Projekt gestartet – Editor wird geleert.")
                        NotificationCenter.default.post(name: Notification.Name("AppClearEditor"), object: nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            NotificationCenter.default.post(name: Notification.Name("AppForceEditorRefresh"), object: nil)
                            print("[AppDebug] Editor-Refresh nach Neuem Projekt ausgelöst.")
                        }
                        NotificationCenter.default.post(name: Notification.Name("AppResetFullState"), object: nil)

                        DispatchQueue.global(qos: .userInitiated).async {
                            if let data = try? Data(contentsOf: url),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                DispatchQueue.main.async {
                                    if let rawLyrics = json["rawLyrics"] as? String {
                                        NotificationCenter.default.post(name: Notification.Name("AppDidOpenProject"), object: rawLyrics)
                                    }
                                    if let style = json["style"] as? [String: Any] {
                                        NotificationCenter.default.post(name: Notification.Name("AppDidOpenStyle"), object: style)
                                    }
                                    if let editor = json["editor"] as? [String: Any] {
                                        NotificationCenter.default.post(name: Notification.Name("AppDidOpenEditorConfig"), object: editor)
                                    }
                                    if let audio = json["audio"] as? [String: Any] {
                                        NotificationCenter.default.post(name: Notification.Name("AppDidOpenAudio"), object: audio)
                                    }
                                }
                            } else {
                                print("[AppDebug] Konnte Projektdatei nicht lesen oder parsen: \(url.path)")
                            }
                        }
                    }
                }
        }

        // Menüeinträge (Projekt öffnen / speichern etc.)
        .commands {
            ProjectFileMenu(currentProjectName: $currentProjectName)
        }
    }
}
