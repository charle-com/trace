import SwiftUI
import UniformTypeIdentifiers
import TraceCore

extension UTType {
    /// Type GPX déclaré dans Info.plist (importé), identifiant standard de Topografix.
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// Document = un fichier GPX. Si le GPX contient notre bloc `<trace:project>`, les ancres restent éditables ;
/// sinon la trace est importée telle quelle.
@MainActor
final class TraceDocument: @preconcurrency ReferenceFileDocument {
    /// Registre des documents ouverts (QA et scripts).
    nonisolated(unsafe) static var all: [WeakBox] = []

    typealias Snapshot = RouteProject

    static var readableContentTypes: [UTType] { [.gpx] }
    static var writableContentTypes: [UTType] { [.gpx] }

    @Published var project: RouteProject
    /// Tronçons dont le calcul est en cours (affichés en pointillé).
    @Published var pendingLegIDs: Set<UUID> = []
    @Published var lastError: String?
    @Published private(set) var stats: TrackStats = .empty
    @Published private(set) var profile: [ProfileSample] = []
    @Published var selectedAnchorID: UUID?
    @Published var selectedWaypointID: UUID?
    /// Index du point survolé (profil altimétrique ou carte).
    @Published var hoverIndex: Int?

    var routing: RoutingService = RoutingHub()
    var elevation: ElevationService = ElevationHub()
    weak var undoManager: UndoManager?
    /// Fenêtre qui affiche le document (posée par la carte) : donne accès au NSDocument sous-jacent.
    weak var window: NSWindow? {
        didSet { if undoManager == nil { undoManager = window?.undoManager } }
    }
    var nsDocument: NSDocument? { window?.windowController?.document as? NSDocument }

    /// Vrai pour un GPX ouvert qui ne vient pas de Tracé : on ne réécrit JAMAIS ce fichier en place,
    /// le premier enregistrement crée une copie « (Tracé) » dans le dossier des tracés.
    private(set) var openedForeignFile = false
    private var isCreatingFile = false
    private var autosaveTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    /// Résultats de routage arrivés pour un tronçon disparu (Annuler pendant le calcul) : réappliqués si Rétablir le ramène.
    private var orphanLegResults: [UUID: (points: [TrackPoint], fallback: Bool)] = [:]

    init() {
        project = RouteProject()
        Self.all.append(WeakBox(self))
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let gpx = try GPXReader.read(data)
        let name = configuration.file.filename.map { ($0 as NSString).deletingPathExtension } ?? "Tracé"
        project = RouteProject.fromGPX(gpx, fallbackName: name)
        openedForeignFile = gpx.projectJSON == nil
        Self.all.append(WeakBox(self))
        recomputeStats()
        // Altitudes manquantes complétées en tâche de fond, tronçons sauvés en plein calcul relancés.
        Task {
            await self.fillMissingElevations()
            for leg in self.project.legs where leg.fallback && leg.profile.isRouted { self.computeLeg(id: leg.id) }
        }
    }

    func snapshot(contentType: UTType) throws -> RouteProject {
        // Un tronçon encore en calcul est enregistré comme repli (pointillé rouge) : il sera relancé à la réouverture.
        var s = project
        for i in s.legs.indices where pendingLegIDs.contains(s.legs[i].id) { s.legs[i].fallback = true }
        return s
    }

    func fileWrapper(snapshot: RouteProject, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = GPXWriter.write(snapshot.toGPX(embedProject: true), options: GPXWriteOptions(includeElevation: true, includeTime: true, includeWaypoints: true, embedProject: true))
        return FileWrapper(regularFileWithContents: data)
    }

    // MARK: - Dérivés

    var trackPoints: [TrackPoint] { project.trackPoints }
    var canEditAnchors: Bool { project.importedTracks.isEmpty || !project.anchors.isEmpty }

    func recomputeStats() {
        let pts = project.trackPoints
        statsTask?.cancel()
        statsTask = Task.detached(priority: .userInitiated) { [pts] in
            let s = Stats.compute(pts)
            let p = Stats.profile(pts)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.stats = s
                self?.profile = p
            }
        }
    }

    // MARK: - Undo

    /// Points orientés de l'ancre i vers l'ancre i+1, ou nil s'ils ne correspondent pas aux ancres (calcul périmé).
    private static func oriented(_ pts: [TrackPoint], legAt i: Int, in p: RouteProject) -> [TrackPoint]? {
        guard p.anchors.indices.contains(i + 1), let f = pts.first, let l = pts.last else { return nil }
        let a = p.anchors[i].point, b = p.anchors[i + 1].point
        if Geo.distance(f, a) < 0.5, Geo.distance(l, b) < 0.5 { return pts }
        if Geo.distance(f, b) < 0.5, Geo.distance(l, a) < 0.5 { return Array(pts.reversed()) }
        return nil
    }

    /// Applique un nouvel état et enregistre l'inverse dans l'UndoManager.
    private func commit(_ new: RouteProject, actionName: String) {
        let old = project
        var new = new
        // Résultats orphelins (Annuler pendant un calcul, puis Rétablir) réappliqués.
        for i in new.legs.indices {
            if let r = orphanLegResults.removeValue(forKey: new.legs[i].id), let pts = Self.oriented(r.points, legAt: i, in: new) {
                new.legs[i].points = pts
                new.legs[i].fallback = r.fallback
            }
        }
        project = new
        pendingLegIDs = pendingLegIDs.filter { id in new.legs.contains { $0.id == id } }
        if let s = selectedAnchorID, !new.anchors.contains(where: { $0.id == s }) { selectedAnchorID = nil }
        if let s = selectedWaypointID, !new.waypoints.contains(where: { $0.id == s }) { selectedWaypointID = nil }
        recomputeStats()
        scheduleAutosave()
        if undoManager == nil { undoManager = window?.undoManager }
        guard let um = undoManager else { return }
        // Un groupe par action : sans événement souris (scripts, QA), le groupe automatique de NSUndoManager ne se
        // ferme jamais et toutes les actions fusionneraient en un seul « Annuler ».
        let opened = um.groupingLevel == 0
        if opened { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.commit(old, actionName: actionName) }
        }
        um.setActionName(actionName)
        if opened { um.endUndoGrouping() }
    }

    /// Variante publique de `commit` pour les extensions.
    func commitPublic(_ new: RouteProject, actionName: String) { commit(new, actionName: actionName) }
    func computeLegPublic(id: UUID) { computeLeg(id: id) }

    // MARK: - Ancres

    /// Ajoute une ancre en fin de tracé et calcule le tronçon depuis la précédente.
    func appendAnchor(lat: Double, lon: Double, profile: RoutingProfile? = nil) {
        let prof = profile ?? project.defaultProfile
        var p = project
        if !p.importedTracks.isEmpty && p.anchors.isEmpty {
            // Le tracé importé devient la base : on repart de sa fin.
            convertImportedToEditable(&p)
        }
        let anchor = Anchor(lat: lat, lon: lon)
        p.anchors.append(anchor)
        if p.anchors.count >= 2 {
            let prev = p.anchors[p.anchors.count - 2]
            let leg = Leg(profile: prof, points: Geo.straightLine(from: prev.point, to: anchor.point))
            p.legs.append(leg)
            commit(p, actionName: "Ajouter un point")
            selectedAnchorID = anchor.id
            selectedWaypointID = nil
            computeLeg(id: leg.id)
        } else {
            commit(p, actionName: "Placer le départ")
            selectedAnchorID = anchor.id
            selectedWaypointID = nil
        }
    }

    /// Insère une ancre au milieu d'un tronçon (clic sur la ligne). Tronçon routé : les deux moitiés sont recalculées ;
    /// tronçon en ligne droite ou trace importée : la polyligne existante est coupée au point cliqué, rien n'est perdu.
    func insertAnchor(lat: Double, lon: Double, inLeg legIndex: Int) {
        guard project.legs.indices.contains(legIndex) else { return }
        var p = project
        let old = p.legs[legIndex]
        let a = Anchor(lat: lat, lon: lon)
        p.anchors.insert(a, at: legIndex + 1)
        if old.profile == .straight, let n = Geo.nearestPoint(on: old.points, to: a.point) {
            let cut = TrackPoint(lat: lat, lon: lon, ele: n.point.ele)
            let leftPts = Array(old.points[...n.segment]) + [cut]
            let rightPts = [cut] + Array(old.points[(n.segment + 1)...])
            p.legs.replaceSubrange(legIndex...legIndex, with: [Leg(profile: .straight, points: leftPts), Leg(profile: .straight, points: rightPts)])
            commit(p, actionName: "Insérer un point")
            selectedAnchorID = a.id
            selectedWaypointID = nil
            return
        }
        let left = Leg(profile: old.profile, points: Geo.straightLine(from: p.anchors[legIndex].point, to: a.point))
        let right = Leg(profile: old.profile, points: Geo.straightLine(from: a.point, to: p.anchors[legIndex + 2].point))
        p.legs.replaceSubrange(legIndex...legIndex, with: [left, right])
        commit(p, actionName: "Insérer un point")
        selectedAnchorID = a.id
        selectedWaypointID = nil
        computeLeg(id: left.id)
        computeLeg(id: right.id)
    }

    /// Déplace une ancre et recalcule les tronçons adjacents. Un tronçon en ligne droite à géométrie importée garde
    /// ses points, seule l'extrémité suit l'ancre.
    func moveAnchor(id: UUID, lat: Double, lon: Double) {
        guard let i = project.anchors.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        p.anchors[i].lat = lat
        p.anchors[i].lon = lon
        var toCompute: [UUID] = []
        func rebuilt(_ leg: Leg, from a: TraceCore.Anchor, to b: TraceCore.Anchor, movedEnd: Bool) -> Leg {
            if leg.profile == .straight && leg.points.count > 2 {
                var pts = leg.points
                if movedEnd { pts[pts.count - 1] = TrackPoint(lat: b.lat, lon: b.lon, ele: pts.last?.ele) }
                else { pts[0] = TrackPoint(lat: a.lat, lon: a.lon, ele: pts.first?.ele) }
                return Leg(id: UUID(), profile: .straight, points: pts)
            }
            let l = Leg(id: UUID(), profile: leg.profile, points: Geo.straightLine(from: a.point, to: b.point))
            toCompute.append(l.id)
            return l
        }
        if i > 0 { p.legs[i - 1] = rebuilt(p.legs[i - 1], from: p.anchors[i - 1], to: p.anchors[i], movedEnd: true) }
        if i < p.anchors.count - 1 { p.legs[i] = rebuilt(p.legs[i], from: p.anchors[i], to: p.anchors[i + 1], movedEnd: false) }
        commit(p, actionName: "Déplacer un point")
        toCompute.forEach { computeLeg(id: $0) }
    }

    func removeAnchor(id: UUID) {
        guard let i = project.anchors.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        p.anchors.remove(at: i)
        var toCompute: [UUID] = []
        if p.anchors.isEmpty {
            p.legs = []
        } else if i == 0 {
            p.legs.removeFirst()
        } else if i == p.anchors.count {
            p.legs.removeLast()
        } else {
            // Fusion des deux tronçons autour de l'ancre supprimée.
            let left = p.legs[i - 1], right = p.legs[i]
            if left.profile == .straight && right.profile == .straight {
                p.legs.replaceSubrange((i - 1)...i, with: [Leg(profile: .straight, points: left.points + right.points.dropFirst())])
            } else {
                let leg = Leg(profile: left.profile, points: Geo.straightLine(from: p.anchors[i - 1].point, to: p.anchors[i].point))
                p.legs.replaceSubrange((i - 1)...i, with: [leg])
                toCompute.append(leg.id)
            }
        }
        commit(p, actionName: "Supprimer un point")
        toCompute.forEach { computeLeg(id: $0) }
    }

    func removeLastAnchor() {
        guard let last = project.anchors.last else { return }
        removeAnchor(id: last.id)
    }

    /// Revient au départ (ajoute une ancre sur le premier point).
    func closeLoop(profile: RoutingProfile? = nil) {
        guard let first = project.anchors.first, project.anchors.count >= 2 else { return }
        appendAnchor(lat: first.lat, lon: first.lon, profile: profile)
    }

    func reverse() {
        var p = project
        guard !p.anchors.isEmpty || !p.importedTracks.isEmpty else { return }
        p.anchors.reverse()
        p.legs = p.legs.reversed().map { Leg(id: $0.id, profile: $0.profile, points: $0.points.reversed(), fallback: $0.fallback) }
        p.importedTracks = p.importedTracks.reversed().map { $0.reversed() }
        commit(p, actionName: "Inverser le sens")
    }

    /// Aller-retour : on repasse par tous les points en sens inverse. Les tronçons encore en calcul sont recalculés.
    func outAndBack() {
        guard project.anchors.count >= 2 else { return }
        var p = project
        let back = p.anchors.dropLast().reversed().map { Anchor(lat: $0.lat, lon: $0.lon) }
        let backLegs = p.legs.reversed().map { Leg(profile: $0.profile, points: $0.points.reversed(), fallback: $0.fallback) }
        let toCompute = zip(p.legs.reversed(), backLegs).filter { pendingLegIDs.contains($0.0.id) }.map { $0.1.id }
        p.anchors.append(contentsOf: back)
        p.legs.append(contentsOf: backLegs)
        commit(p, actionName: "Aller-retour")
        toCompute.forEach { computeLeg(id: $0) }
    }

    func clearAll() {
        var p = project
        p.anchors = []
        p.legs = []
        p.importedTracks = []
        commit(p, actionName: "Effacer le tracé")
    }

    /// Change le mode d'un tronçon et le recalcule.
    func setProfile(_ profile: RoutingProfile, forLegAt index: Int) {
        guard project.legs.indices.contains(index) else { return }
        var p = project
        let leg = Leg(id: UUID(), profile: profile, points: Geo.straightLine(from: p.anchors[index].point, to: p.anchors[index + 1].point))
        p.legs[index] = leg
        commit(p, actionName: "Changer le mode du tronçon")
        computeLeg(id: leg.id)
    }

    /// Recalcule tous les tronçons avec le profil donné (ou leur profil propre). Les tronçons en ligne droite qui portent
    /// une géométrie importée (trace GPX rendue éditable) sont conservés tels quels.
    func recomputeAllLegs(with profile: RoutingProfile? = nil, actionName: String = "Recalculer le tracé") {
        var p = project
        var ids: [UUID] = []
        for i in p.legs.indices {
            let old = p.legs[i]
            if old.profile == .straight && old.points.count > 2 { continue }
            let prof = profile ?? old.profile
            let leg = Leg(id: UUID(), profile: prof, points: Geo.straightLine(from: p.anchors[i].point, to: p.anchors[i + 1].point))
            p.legs[i] = leg
            ids.append(leg.id)
        }
        if let profile { p.defaultProfile = profile }
        commit(p, actionName: actionName)
        ids.forEach { computeLeg(id: $0) }
    }

    /// Changer le mode (barre d'outils, menu, ⌘⌥1 à 7) recalcule tout le tracé avec ce mode.
    func setDefaultProfile(_ profile: RoutingProfile) {
        guard project.defaultProfile != profile else { return }
        recomputeAllLegs(with: profile, actionName: "Passer en \(profile.title.lowercased())")
    }

    func rename(_ name: String) {
        guard name != project.name else { return }
        var p = project
        p.name = name
        commit(p, actionName: "Renommer")
    }

    func setNotes(_ notes: String) {
        guard notes != project.notes else { return }
        var p = project
        p.notes = notes
        commit(p, actionName: "Modifier les notes")
    }

    /// Transforme une trace importée en tracé éditable : ancres = trace simplifiée, tronçons = morceaux d'origine.
    func makeImportedEditable() {
        guard !project.importedTracks.isEmpty, project.anchors.isEmpty else { return }
        var p = project
        convertImportedToEditable(&p)
        commit(p, actionName: "Rendre la trace éditable")
    }

    private func convertImportedToEditable(_ p: inout RouteProject) {
        let pts = p.importedTracks.flatMap { $0 }
        guard pts.count >= 2 else { p.importedTracks = []; return }
        // Ancres aux inflexions (Douglas-Peucker large), tronçons en ligne « importée » figée.
        let simplified = Geo.simplify(pts, tolerance: 60)
        var anchorIdx: [Int] = []
        var j = 0
        for s in simplified {
            while j < pts.count && !(pts[j].lat == s.lat && pts[j].lon == s.lon) { j += 1 }
            if j < pts.count { anchorIdx.append(j) }
        }
        if anchorIdx.first != 0 { anchorIdx.insert(0, at: 0) }
        if anchorIdx.last != pts.count - 1 { anchorIdx.append(pts.count - 1) }
        p.anchors = anchorIdx.map { Anchor(lat: pts[$0].lat, lon: pts[$0].lon) }
        p.legs = []
        for k in 0..<(anchorIdx.count - 1) {
            let slice = Array(pts[anchorIdx[k]...anchorIdx[k + 1]])
            p.legs.append(Leg(profile: .straight, points: slice))
        }
        p.importedTracks = []
    }

    // MARK: - Points d'intérêt

    func addWaypoint(lat: Double, lon: Double, name: String = "Point d'intérêt") {
        var p = project
        let w = Waypoint(lat: lat, lon: lon, name: name)
        p.waypoints.append(w)
        commit(p, actionName: "Ajouter un point d'intérêt")
        selectedWaypointID = w.id
        selectedAnchorID = nil
        Task { [weak self] in
            guard let self, let e = try? await self.elevation.elevations(for: [TrackPoint(lat: lat, lon: lon)]).first else { return }
            await MainActor.run {
                guard let i = self.project.waypoints.firstIndex(where: { $0.id == w.id }) else { return }
                self.project.waypoints[i].ele = e
            }
        }
    }

    func updateWaypoint(_ w: Waypoint) {
        guard let i = project.waypoints.firstIndex(where: { $0.id == w.id }), project.waypoints[i] != w else { return }
        var p = project
        p.waypoints[i] = w
        commit(p, actionName: "Modifier le point d'intérêt")
    }

    func moveWaypoint(id: UUID, lat: Double, lon: Double) {
        guard var w = project.waypoints.first(where: { $0.id == id }) else { return }
        w.lat = lat
        w.lon = lon
        updateWaypoint(w)
    }

    func removeWaypoint(id: UUID) {
        var p = project
        p.waypoints.removeAll { $0.id == id }
        commit(p, actionName: "Supprimer le point d'intérêt")
    }

    // MARK: - Calcul des tronçons

    private func computeLeg(id: UUID) {
        guard let i = project.legs.firstIndex(where: { $0.id == id }) else { return }
        let leg = project.legs[i]
        let from = project.anchors[i].point, to = project.anchors[i + 1].point
        let routing = self.routing, elevation = self.elevation
        pendingLegIDs.insert(id)
        if !leg.profile.isRouted {
            // Ligne droite : juste l'altitude.
            Task { [weak self] in
                let pts = Geo.straightLine(from: from, to: to)
                let withEle = await Self.addElevations(pts, service: elevation)
                await self?.applyLegResult(id: id, points: withEle, fallback: false)
            }
            return
        }
        Task { [weak self] in
            do {
                var pts = try await routing.route(from: from, to: to, profile: leg.profile)
                if pts.count < 2 { throw ServiceError.noRoute }
                // On force les extrémités sur les ancres exactes pour un tracé continu.
                pts[0] = TrackPoint(lat: from.lat, lon: from.lon, ele: pts[0].ele)
                pts[pts.count - 1] = TrackPoint(lat: to.lat, lon: to.lon, ele: pts[pts.count - 1].ele)
                if pts.contains(where: { $0.ele == nil }) {
                    pts = await Self.addElevations(pts, service: elevation)
                }
                await self?.applyLegResult(id: id, points: pts, fallback: false)
            } catch {
                let pts = await Self.addElevations(Geo.straightLine(from: from, to: to), service: elevation)
                await self?.applyLegResult(id: id, points: pts, fallback: true, error: error)
            }
        }
    }

    private static func addElevations(_ pts: [TrackPoint], service: ElevationService) async -> [TrackPoint] {
        guard let eles = try? await service.elevations(for: pts), eles.count == pts.count else { return pts }
        var out = pts
        for i in out.indices { out[i].ele = eles[i] }
        return out
    }

    private func applyLegResult(id: UUID, points: [TrackPoint], fallback: Bool, error: Error? = nil) {
        pendingLegIDs.remove(id)
        guard let i = project.legs.firstIndex(where: { $0.id == id }) else {
            // Le tronçon a disparu (Annuler) pendant le calcul : le résultat reviendra si Rétablir le ramène.
            orphanLegResults[id] = (points, fallback)
            return
        }
        guard let pts = Self.oriented(points, legAt: i, in: project) else { return }
        project.legs[i].points = pts
        project.legs[i].fallback = fallback
        if let error, fallback { lastError = "Itinéraire impossible, ligne droite utilisée. \(error.localizedDescription)" }
        recomputeStats()
        // Le résultat du routage arrive hors undo : on marque le document modifié pour qu'il soit bien réenregistré.
        nsDocument?.updateChangeCount(.changeDone)
        scheduleAutosave()
        // Altimétrie indisponible à l'instant T : nouvel essai dans 5 s.
        if pts.contains(where: { $0.ele == nil }) { retryElevation(legID: id, delay: 5) }
    }

    private func retryElevation(legID: UUID, delay: Double) {
        let elevation = self.elevation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, let i = self.project.legs.firstIndex(where: { $0.id == legID }) else { return }
            let pts = self.project.legs[i].points
            guard pts.contains(where: { $0.ele == nil }) else { return }
            let withEle = await Self.addElevations(pts, service: elevation)
            guard let j = self.project.legs.firstIndex(where: { $0.id == legID }), self.project.legs[j].points.count == withEle.count else { return }
            self.project.legs[j].points = withEle
            self.recomputeStats()
            self.nsDocument?.updateChangeCount(.changeDone)
            self.scheduleAutosave()
            if withEle.contains(where: { $0.ele == nil }) && delay < 60 { self.retryElevation(legID: legID, delay: delay * 2) }
        }
    }

    /// Complète les altitudes manquantes (trace importée sans `<ele>`).
    func fillMissingElevations() async {
        let tracks = project.importedTracks
        guard !tracks.isEmpty, tracks.contains(where: { $0.contains { $0.ele == nil } }) else { return }
        var out: [[TrackPoint]] = []
        for t in tracks {
            out.append(await Self.addElevations(t, service: elevation))
        }
        project.importedTracks = out
        recomputeStats()
    }

    // MARK: - Export

    func exportGPX(options: GPXWriteOptions) -> Data {
        GPXWriter.write(project.toGPX(embedProject: false), options: options)
    }

    // MARK: - Enregistrement automatique

    /// Enregistrement automatique après chaque modification (réglage `autosave`, actif par défaut) :
    /// un document déjà nommé est réécrit en silence ; un document sans titre reçoit un fichier dans le dossier
    /// des tracés (`~/Documents/Tracés/` ou le dossier choisi dans les Réglages). Un GPX étranger n'est jamais
    /// réécrit en place : sa copie de travail « nom (Tracé).gpx » est créée dans ce même dossier.
    static var autosaveEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "autosave") == nil ? true : d.bool(forKey: "autosave")
    }

    static var autosaveFolder: URL {
        if let s = UserDefaults.standard.string(forKey: "autosaveFolder"), !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Tracés", isDirectory: true)
    }

    func scheduleAutosave(delay: Double = 1.2) {
        guard Self.autosaveEnabled else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.performAutosave()
        }
    }

    func performAutosave() {
        guard Self.autosaveEnabled, let nsdoc = nsDocument else { return }
        // Rien à enregistrer tant que le tracé est vide (évite de créer un fichier pour une fenêtre vierge).
        guard !project.isEmpty || !project.waypoints.isEmpty else { return }
        if let url = nsdoc.fileURL, !openedForeignFile {
            guard nsdoc.isDocumentEdited else { return }
            nsdoc.save(to: url, ofType: nsdoc.fileType ?? "com.topografix.gpx", for: .saveOperation) { error in
                if let error { NSLog("Tracé : enregistrement automatique impossible : \(error.localizedDescription)") }
            }
        } else {
            guard !isCreatingFile else { scheduleAutosave(); return }
            isCreatingFile = true
            let folder = Self.autosaveFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = openedForeignFile
                ? (nsdoc.fileURL?.deletingPathExtension().lastPathComponent ?? "Tracé") + " (Tracé)"
                : Self.defaultFileName()
            let url = Self.uniqueURL(in: folder, base: base)
            let name = url.deletingPathExtension().lastPathComponent
            if project.name == "Nouveau tracé" || project.name.isEmpty { project.name = name }
            nsdoc.save(to: url, ofType: "com.topografix.gpx", for: .saveAsOperation) { [weak self] error in
                Task { @MainActor in
                    self?.isCreatingFile = false
                    if let error { NSLog("Tracé : création du fichier automatique impossible : \(error.localizedDescription)") }
                    else { self?.openedForeignFile = false }
                }
            }
        }
    }

    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        return "Tracé \(f.string(from: Date()))"
    }

    static func uniqueURL(in folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension("gpx")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension("gpx")
            n += 1
        }
        return url
    }
}

final class WeakBox {
    weak var doc: TraceDocument?
    init(_ d: TraceDocument) { doc = d }
}
