import SwiftUI
import AppKit
import TraceCore

@main
struct TraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { TraceDocument() }) { file in
            ContentView(doc: file.document)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { TraceCommands() }

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        QARunner.startIfRequested()
        guard !QARunner.enabled else { return }
        // DocumentGroup ouvre un « Sans titre » de lui-même au lancement, sans passer par applicationShouldOpenUntitledFile.
        // On le referme s'il est vide et qu'aucun fichier n'a été ouvert, et on affiche la fenêtre de bienvenue à la place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let show = UserDefaults.standard.object(forKey: "showWelcome") == nil ? true : UserDefaults.standard.bool(forKey: "showWelcome")
            guard show else { return }
            let docs = NSDocumentController.shared.documents
            let untitledEmpty = docs.filter { d in
                d.fileURL == nil && !d.isDocumentEdited && (TraceDocument.all.compactMap { $0.doc }.first { $0.window?.windowController?.document === d }?.project.isEmpty ?? true)
            }
            guard untitledEmpty.count == docs.count else { return }   // un vrai fichier est ouvert : pas de bienvenue
            untitledEmpty.forEach { $0.close() }
            WelcomeController.shared.show()
        }
    }

    /// Au lancement sans document (et au clic sur le Dock sans fenêtre) : fenêtre de bienvenue plutôt qu'un « Sans titre ».
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if QARunner.enabled { return true }
        let show = UserDefaults.standard.object(forKey: "showWelcome") == nil ? true : UserDefaults.standard.bool(forKey: "showWelcome")
        guard show else { return true }
        Task { @MainActor in WelcomeController.shared.show() }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in WelcomeController.shared.show() } ; return false }
        return true
    }
}
