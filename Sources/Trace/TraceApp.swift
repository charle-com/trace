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

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}
