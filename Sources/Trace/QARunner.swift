import AppKit
import SwiftUI
import TraceCore
import MapKit

/// Mode de test automatisé : `Trace --qa <dossier>` (+ options) exécute un scénario, capture la fenêtre et écrit un JSON.
/// Options : `--scenario route|open|empty`, `--open <fichier.gpx>`, `--layer <id>`, `--overlay <id>`, `--wait <s>`, `--profile <raw>`.
@MainActor
enum QARunner {
    static var args: [String: String] = [:]
    static var enabled = false

    static func startIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--qa"), i + 1 < a.count else { return }
        enabled = true
        var j = i
        while j + 1 < a.count {
            let k = a[j]
            if k.hasPrefix("--") { args[String(k.dropFirst(2))] = a[j + 1]; j += 2 } else { j += 1 }
        }
        let outDir = URL(fileURLWithPath: a[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { await run(outDir: outDir) }
    }

    static func run(outDir: URL) async {
        var log: [String] = []
        func note(_ s: String) { log.append(s); FileHandle.standardError.write(Data("[QA] \(s)\n".utf8)) }
        note("démarrage, args \(args)")

        if let path = args["open"] {
            note("ouverture \(path)")
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, err in
                if let err { note("erreur ouverture : \(err.localizedDescription)") }
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var tries = 0
        while TraceDocument.all.compactMap({ $0.doc }).isEmpty && tries < 20 {
            if tries == 2 && args["open"] == nil {
                note("pas de document après 1,5 s : newDocument")
                NSDocumentController.shared.newDocument(nil)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            tries += 1
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        note("fenêtres \(NSApp.windows.count), documents \(NSDocumentController.shared.documents.count), TraceDocument \(TraceDocument.all.compactMap { $0.doc }.count), scènes \(SceneContext.all.compactMap { $0.scene }.count)")
        // On travaille sur la scène la plus récente : son document est celui affiché dans sa fenêtre.
        var sceneOpt = SceneContext.all.compactMap { $0.scene }.last
        if let wanted = args["open"] {
            // Plusieurs fenêtres : retenir celle dont le document porte le nom du fichier ouvert.
            let name = (wanted as NSString).lastPathComponent.replacingOccurrences(of: ".gpx", with: "")
            sceneOpt = SceneContext.all.compactMap { $0.scene }.first { $0.doc.project.name == name || !$0.doc.project.importedTracks.isEmpty } ?? sceneOpt
        }
        guard let scene = sceneOpt, let window = scene.controller.mapView?.window else {
            note("aucune scène ou fenêtre")
            finish(outDir: outDir, log: log, ok: false)
            return
        }
        let doc = scene.doc
        if doc.undoManager == nil { doc.undoManager = window.undoManager; note("undoManager depuis la fenêtre : \(window.undoManager != nil)") }
        note("doc \(ObjectIdentifier(doc)) « \(doc.project.name) », fenêtre \(window.windowNumber) « \(window.title) »")
        window.setFrame(NSRect(x: 80, y: 80, width: 1400, height: 900), display: true)

        if let layer = args["layer"] { scene.settings.baseLayerID = layer; note("layer \(layer)") }
        if let ov = args["overlay"] { scene.settings.overlayIDs = Set(ov.split(separator: ",").map(String.init)) }
        if let p = args["profile"], let prof = RoutingProfile(rawValue: p) { doc.setDefaultProfile(prof) }

        let scenario = args["scenario"] ?? "route"
        var gestureLog: [String: Any] = [:]
        switch scenario {
        case "route":
            // Vitré : centre, puis 3 points autour, puis boucle.
            scene.controller.center(on: .init(latitude: 48.1180, longitude: -1.2050), zoom: 14, animated: false)
            try? await Task.sleep(nanoseconds: 500_000_000)
            doc.appendAnchor(lat: 48.1247, lon: -1.2099)
            doc.appendAnchor(lat: 48.1300, lon: -1.1900)
            doc.appendAnchor(lat: 48.1150, lon: -1.1850)
            doc.addWaypoint(lat: 48.1300, lon: -1.1900, name: "Château")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            doc.closeLoop()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            note("ancres \(doc.project.anchors.count), tronçons \(doc.project.legs.count), pending \(doc.pendingLegIDs.count)")
        case "open":
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scene.controller.zoomToFit(doc.trackPoints.map { .init(latitude: $0.lat, longitude: $0.lon) }, animated: false)
            if args["edit"] != nil, let last = doc.trackPoints.last {
                // Modification d'un GPX étranger : doit créer une copie « (Tracé) », jamais réécrire l'original.
                doc.appendAnchor(lat: last.lat + 0.004, lon: last.lon + 0.004)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                note("édition : ancres \(doc.project.anchors.count), fichier \(doc.nsDocument?.fileURL?.lastPathComponent ?? "aucun")")
            }
        case "locate":
            scene.controller.showUserLocation()
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            let map = scene.controller.mapView
            note("localisation : statut \(scene.controller.locationStatus), erreur \(scene.controller.locationError ?? "aucune"), showsUserLocation \(map?.showsUserLocation ?? false), position \(map?.userLocation.location.map { "\($0.coordinate.latitude), \($0.coordinate.longitude)" } ?? "nil"), centre \(scene.controller.centerCoordinate.latitude), \(scene.controller.centerCoordinate.longitude)")
        case "gestures":
            gestureLog = await gestures(doc: doc, scene: scene, note: note)
            note("après gestes : ancres \(doc.project.anchors.count)")
        default:
            scene.controller.center(on: .init(latitude: 48.1247, longitude: -1.2099), zoom: 13, animated: false)
        }
        let wait = Double(args["wait"] ?? "6") ?? 6
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

        // Capture : faite par le shell appelant (TCC), on publie le numéro de fenêtre et on attend `--hold` secondes.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        note("fenêtre \(window.windowNumber), visible \(window.occlusionState.contains(.visible)), tuiles \(LayerTileOverlay.loaded)/\(LayerTileOverlay.failed)")
        try? "\(window.windowNumber)".write(to: outDir.appendingPathComponent("window.txt"), atomically: true, encoding: .utf8)
        // Rendu hors écran (fonctionne même fenêtre occultée / écran verrouillé).
        if let cv = window.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: outDir.appendingPathComponent("window-cache.png"))
            }
        }
        let hold = Double(args["hold"] ?? "6") ?? 6
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))

        // Export GPX.
        let gpx = doc.exportGPX(options: GPXWriteOptions(includeElevation: true, includeWaypoints: true, simplifyTolerance: 0, embedProject: false))
        try? gpx.write(to: outDir.appendingPathComponent("export.gpx"))
        let work = GPXWriter.write(doc.project.toGPX(embedProject: true), options: GPXWriteOptions(embedProject: true))
        try? work.write(to: outDir.appendingPathComponent("work.gpx"))

        let s = doc.stats
        let result: [String: Any] = [
            "anchors": doc.project.anchors.count,
            "legs": doc.project.legs.count,
            "legFallbacks": doc.project.legs.filter { $0.fallback }.count,
            "pending": doc.pendingLegIDs.count,
            "points": s.pointCount,
            "distance": s.distance,
            "ascent": s.ascent,
            "descent": s.descent,
            "hasElevation": s.hasElevation,
            "profileSamples": doc.profile.count,
            "waypoints": doc.project.waypoints.count,
            "tilesLoaded": LayerTileOverlay.loaded,
            "tilesFailed": LayerTileOverlay.failed,
            "baseLayer": scene.settings.baseLayerID,
            "docName": doc.project.name,
            "windowTitle": window.title,
            "windowFrame": NSStringFromRect(window.frame),
            "lastError": doc.lastError ?? "",
            "gestures": gestureLog,
            "log": log,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("result.json"))
        }
        finish(outDir: outDir, log: log, ok: true)
    }

    /// Pilote le coordinateur de la carte comme le feraient les gestes souris.
    static func gestures(doc: TraceDocument, scene: SceneContext, note: (String) -> Void) async -> [String: Any] {
        var out: [String: Any] = [:]
        guard let map = scene.controller.mapView as? TraceMapView, let coord = map.delegate as? MapView.Coordinator else {
            note("gestures : pas de carte"); return ["error": "pas de carte"]
        }
        note("coordinator.doc identique : \(coord.doc === doc)")
        scene.controller.center(on: .init(latitude: 48.1180, longitude: -1.2050), zoom: 14, animated: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        func pt(_ lat: Double, _ lon: Double) -> NSPoint { map.convert(CLLocationCoordinate2D(latitude: lat, longitude: lon), toPointTo: map) }
        // 1. Menu contextuel sur carte vide.
        let m0 = coord.contextMenu(at: pt(48.1247, -1.2099))
        out["menuEmpty"] = m0?.items.map { $0.title } ?? []
        // 2. Clic gauche = départ, puis 2 clics = tronçons routés.
        coord.performClickForQA(at: pt(48.1247, -1.2099))
        coord.performClickForQA(at: pt(48.1300, -1.1900))
        coord.performClickForQA(at: pt(48.1150, -1.1850))
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        out["afterClicks"] = ["anchors": doc.project.anchors.count, "legs": doc.project.legs.count, "distance": doc.stats.distance]
        // 3. Menu contextuel avec tracé.
        let m1 = coord.contextMenu(at: pt(48.1100, -1.2000))
        out["menuRoute"] = m1?.items.map { $0.title } ?? []
        // 4. Clic sur la ligne = insertion d'une ancre (on prend le point médian du tronçon 1).
        if let leg = doc.project.legs.first, leg.points.count > 4 {
            let mid = leg.points[leg.points.count / 2]
            let before = doc.project.anchors.count
            coord.performClickForQA(at: pt(mid.lat, mid.lon))
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            out["insertOnLine"] = ["before": before, "after": doc.project.anchors.count, "legs": doc.project.legs.count]
            // 5. Menu contextuel sur la ligne.
            if let leg2 = doc.project.legs.last, leg2.points.count > 4 {
                let m2 = coord.contextMenu(at: pt(leg2.points[leg2.points.count / 2].lat, leg2.points[leg2.points.count / 2].lon))
                out["menuOnLine"] = m2?.items.map { $0.title } ?? []
            }
        }
        // 6. Déplacement d'une ancre (simulation de fin de drag).
        if let a = doc.project.anchors.dropFirst().first {
            let before = doc.stats.distance
            doc.moveAnchor(id: a.id, lat: a.lat + 0.004, lon: a.lon + 0.004)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            out["moveAnchor"] = ["distanceBefore": before, "distanceAfter": doc.stats.distance, "fallbacks": doc.project.legs.filter { $0.fallback }.count]
        }
        // 7. Tracer jusqu'ici au plus court + ligne droite via les actions du menu.
        doc.appendAnchor(lat: 48.1050, lon: -1.2150, profile: .shortest)
        doc.appendAnchor(lat: 48.1000, lon: -1.2250, profile: .straight)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        out["profiles"] = doc.project.legs.map { $0.profile.rawValue }
        // 8. Undo / redo : une action isolée dans son propre cycle, puis annulation.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let n = doc.project.anchors.count
        let um = doc.undoManager
        await tick()   // simule la fin d'un événement : NSUndoManager ferme son groupe automatique
        note("undo groupingLevel avant \(um?.groupingLevel ?? -1)")
        doc.appendAnchor(lat: 48.0950, lon: -1.2300, profile: .straight)
        await tick()
        note("undo groupingLevel après \(um?.groupingLevel ?? -1), canUndo \(um?.canUndo ?? false), action « \(um?.undoActionName ?? "") »")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterAdd = doc.project.anchors.count
        let canUndo = doc.undoManager?.canUndo ?? false
        doc.undoManager?.undo()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterUndo = doc.project.anchors.count
        doc.undoManager?.redo()
        try? await Task.sleep(nanoseconds: 300_000_000)
        out["undo"] = ["before": n, "afterAdd": afterAdd, "afterUndo": afterUndo, "afterRedo": doc.project.anchors.count, "canUndo": canUndo, "hasUndoManager": doc.undoManager != nil]
        // 9. Aller-retour puis inverser.
        doc.reverse()
        out["reverseFirstAnchor"] = [doc.project.anchors.first?.lat ?? 0, doc.project.anchors.first?.lon ?? 0]
        try? await Task.sleep(nanoseconds: 500_000_000)
        return out
    }

    /// Poste un événement applicatif et laisse la boucle le traiter (les groupes d'annulation se ferment à la fin d'un événement).
    static func tick() async {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    static func finish(outDir: URL, log: [String], ok: Bool) {
        if !ok {
            let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "log": log])
            try? data?.write(to: outDir.appendingPathComponent("result.json"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(ok ? 0 : 1) }
    }

    /// Retrouve le SceneContext via la hiérarchie NSHostingView (les objets sont stockés dans l'environnement SwiftUI,
    /// inaccessibles depuis AppKit) : on passe par un registre statique rempli par ContentView.
}

extension SceneContext {
    nonisolated(unsafe) static var all: [SceneBox] = []
    final class SceneBox { weak var scene: SceneContext?; init(_ s: SceneContext) { scene = s } }
    func register() { Self.all.append(SceneBox(self)) }
}
