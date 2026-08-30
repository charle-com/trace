import SwiftUI
import TraceCore

struct TraceCommands: Commands {
    @FocusedValue(\.scene) private var scene

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Exporter en GPX…") { scene?.showExport = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(scene == nil)
        }
        CommandMenu("Tracé") {
            Button("Revenir au départ (boucle)") { scene?.doc.closeLoop() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Aller-retour") { scene?.doc.outAndBack() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Inverser le sens") { scene?.doc.reverse() }
                .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("Supprimer le dernier point") { scene?.doc.removeLastAnchor() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
            Button("Recalculer tout avec le mode courant") { scene?.doc.recomputeAllLegs(with: scene?.doc.project.defaultProfile) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Tout effacer…") { scene?.confirmClear() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Menu("Mode de tracé") {
                ForEach(Array(RoutingProfile.allCases.enumerated()), id: \.element) { i, p in
                    Button {
                        scene?.doc.setDefaultProfile(p)
                    } label: {
                        if scene?.doc.project.defaultProfile == p { Text("✓ \(p.title)") } else { Text(p.title) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
            }
        }
        CommandMenu("Carte") {
            Menu("Fond de carte") {
                ForEach(Array(LayerCatalog.base.enumerated()), id: \.element.id) { i, l in
                    if i < 9 {
                        Button(l.title) { scene?.settings.baseLayerID = l.id }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    } else {
                        Button(l.title) { scene?.settings.baseLayerID = l.id }
                    }
                }
            }
            Menu("Surcouches") {
                ForEach(LayerCatalog.overlays) { l in
                    Button(l.title) {
                        guard let s = scene else { return }
                        if s.settings.overlayIDs.contains(l.id) { s.settings.overlayIDs.remove(l.id) } else { s.settings.overlayIDs.insert(l.id) }
                    }
                }
            }
            Divider()
            Button("Ajuster au tracé") {
                guard let s = scene else { return }
                s.controller.zoomToFit(s.doc.trackPoints.map { .init(latitude: $0.lat, longitude: $0.lon) })
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button("Ma position") { scene?.controller.showUserLocation() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Zoom avant") { scene?.controller.zoom(by: 2) }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom arrière") { scene?.controller.zoom(by: 0.5) }.keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Marqueurs kilométriques") { scene?.settings.showKilometerMarkers.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Profil altimétrique") { scene?.showProfile.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Inspecteur") { scene?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(after: .windowList) {
            Button("Bienvenue dans Tracé") { WelcomeController.shared.show() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Aide Tracé") { NSWorkspace.shared.open(URL(string: "https://charlesneveu.fr")!) }
        }
    }
}

extension SceneContext {
    func confirmClear() {
        let a = NSAlert()
        a.messageText = "Effacer tout le tracé ?"
        a.informativeText = "Les points d'ancrage et les tronçons seront supprimés. Vous pourrez annuler avec ⌘Z."
        a.addButton(withTitle: "Effacer")
        a.addButton(withTitle: "Annuler")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { doc.clearAll() }
    }
}

