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
