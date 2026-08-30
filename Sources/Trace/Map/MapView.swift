import SwiftUI
import MapKit
import TraceCore

// MARK: - Annotations et overlays typés

final class AnchorAnnotation: MKPointAnnotation {
    let anchorID: UUID
    var index: Int
    var isLast: Bool
    init(anchor: TraceCore.Anchor, index: Int, isLast: Bool) {
        anchorID = anchor.id
        self.index = index
        self.isLast = isLast
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: anchor.lat, longitude: anchor.lon)
    }
}

final class WaypointAnnotation: MKPointAnnotation {
    let waypointID: UUID
    init(w: Waypoint) {
        waypointID = w.id
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: w.lat, longitude: w.lon)
        title = w.name
    }
}

final class HoverAnnotation: MKPointAnnotation {}
final class UserDotAnnotation: MKPointAnnotation {}

final class KmAnnotation: MKPointAnnotation {
    let km: Int
    init(km: Int, c: CLLocationCoordinate2D) { self.km = km; super.init(); coordinate = c }
}

final class LegPolyline: MKPolyline {
    var legID: UUID = UUID()
    var profile: RoutingProfile = .hiking
    var pending = false
    var fallback = false
    var isCasing = false
    var isImported = false
}

// MARK: - MKMapView avec menu contextuel et survol

final class TraceMapView: MKMapView {
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?
    var mouseMoved: ((NSPoint) -> Void)?
    var movedToWindow: ((NSWindow?) -> Void)?
    private var tracking: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        movedToWindow?(window)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return contextMenuProvider?(p)
    }

    var mouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        mouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseExited?()
    }
}

// MARK: - Représentation SwiftUI

struct MapView: NSViewRepresentable {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var settings: MapSettings
    @ObservedObject var controller: MapController

    func makeNSView(context: Context) -> TraceMapView {
        let map = TraceMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.showsZoomControls = false
        map.showsPitchControl = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .includingAll
        map.mapType = .standard
        controller.mapView = map

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        click.numberOfClicksRequired = 1
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)

        map.contextMenuProvider = { [weak coord = context.coordinator] p in coord?.contextMenu(at: p) }
        map.mouseMoved = { [weak coord = context.coordinator] p in coord?.mouseMoved(at: p) }
        map.mouseExited = { [weak coord = context.coordinator] in coord?.mouseExited() }
        map.movedToWindow = { [weak coord = context.coordinator] w in
            // La fenêtre donne l'UndoManager et le NSDocument (enregistrement automatique).
            if let w { coord?.doc.window = w }
        }

        // Région initiale : dernière région vue, sinon la France.
        if let d = UserDefaults.standard.dictionary(forKey: "lastRegion"),
           let lat = d["lat"] as? Double, let lon = d["lon"] as? Double, let dlat = d["dlat"] as? Double, let dlon = d["dlon"] as? Double {
            map.region = MKCoordinateRegion(center: .init(latitude: lat, longitude: lon), span: .init(latitudeDelta: dlat, longitudeDelta: dlon))
        } else {
            map.region = MKCoordinateRegion(center: .init(latitude: 46.8, longitude: 2.4), span: .init(latitudeDelta: 9, longitudeDelta: 9))
        }
        context.coordinator.map = map
        context.coordinator.syncLayers()
        context.coordinator.syncRoute(force: true)
        context.coordinator.syncAnnotations()
        DispatchQueue.main.async {
            let pts = doc.trackPoints
            if pts.count >= 2 { controller.zoomToFit(pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }, animated: false) }
        }
        return map
    }

    func updateNSView(_ map: TraceMapView, context: Context) {
        let c = context.coordinator
        c.doc = doc
        c.settings = settings
        c.syncLayers()
        c.syncRoute(force: false)
        c.syncAnnotations()
        c.syncHover()
        c.syncUserDot()
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc, settings: settings, controller: controller) }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var doc: TraceDocument
        var settings: MapSettings
        let controller: MapController
        weak var map: TraceMapView?

        private var baseOverlay: LayerTileOverlay?
        private var overlayTiles: [String: LayerTileOverlay] = [:]
        private var routeSignature: Int = 0
        private var legPolylines: [LegPolyline] = []
        private var anchorAnnotations: [UUID: AnchorAnnotation] = [:]
        private var waypointAnnotations: [UUID: WaypointAnnotation] = [:]
        private var kmAnnotations: [KmAnnotation] = []
        private var hoverAnnotation: HoverAnnotation?
        private var userDot: UserDotAnnotation?
        private var draggingID: UUID?
        private var pendingClick: DispatchWorkItem?
        private var lastMouseLegHit: Int?
        private var hoverFromMap = false
        private var overlaysRetina: Bool?

        init(doc: TraceDocument, settings: MapSettings, controller: MapController) {
            self.doc = doc
            self.settings = settings
            self.controller = controller
        }

        // MARK: Couches

        func syncLayers() {
            guard let map else { return }
            let base = settings.baseLayer
            switch base.kind {
            case .apple(let type):
                if let b = baseOverlay { map.removeOverlay(b); baseOverlay = nil }
                if map.mapType != type { map.mapType = type }
                map.pointOfInterestFilter = .includingAll
            case .tiles:
                if map.mapType != .standard { map.mapType = .standard }
                map.pointOfInterestFilter = .excludingAll
                if baseOverlay?.layer != base || baseOverlay.map({ $0.tileSize.width == 512 }) != settings.retina {
                    if let b = baseOverlay { map.removeOverlay(b) }
                    let o = LayerTileOverlay(layer: base, retina: settings.retina)
                    baseOverlay = o
                    map.insertOverlay(o, at: 0, level: .aboveLabels)
                }
            }
            // Surcouches (reconstruites si le réglage Retina change)
            let wanted = settings.overlays
            if overlaysRetina != settings.retina {
                for (_, o) in overlayTiles { map.removeOverlay(o) }
                overlayTiles = [:]
                overlaysRetina = settings.retina
            }
            for (id, o) in overlayTiles where !wanted.contains(where: { $0.id == id }) {
                map.removeOverlay(o)
                overlayTiles[id] = nil
            }
            for l in wanted where overlayTiles[l.id] == nil {
                let o = LayerTileOverlay(layer: l, retina: settings.retina)
                overlayTiles[l.id] = o
                let idx = (baseOverlay == nil ? 0 : 1) + overlayTiles.count - 1
                map.insertOverlay(o, at: min(idx, map.overlays.count), level: .aboveLabels)
            }
        }

        // MARK: Tracé

        private func signature() -> Int {
            var h = Hasher()
            for l in doc.project.legs { h.combine(l.id); h.combine(l.points.count); h.combine(l.fallback); h.combine(l.profile) }
            h.combine(doc.pendingLegIDs)
            h.combine(doc.project.importedTracks.count)
            for t in doc.project.importedTracks { h.combine(t.count); h.combine(t.first?.lat ?? 0); h.combine(t.last?.lat ?? 0) }
            h.combine(settings.showKilometerMarkers)
            return h.finalize()
        }

        func syncRoute(force: Bool) {
            guard let map else { return }
            let sig = signature()
            guard force || sig != routeSignature else { return }
            routeSignature = sig
            map.removeOverlays(legPolylines)
            legPolylines = []
            var new: [LegPolyline] = []
            func add(_ pts: [TrackPoint], profile: RoutingProfile, id: UUID, pending: Bool, fallback: Bool, imported: Bool) {
                guard pts.count >= 2 else { return }
                let coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let casing = LegPolyline(coordinates: coords, count: coords.count)
                casing.isCasing = true; casing.legID = id; casing.profile = profile; casing.pending = pending; casing.isImported = imported
                let line = LegPolyline(coordinates: coords, count: coords.count)
                line.legID = id; line.profile = profile; line.pending = pending; line.fallback = fallback; line.isImported = imported
                new.append(casing); new.append(line)
            }
            for t in doc.project.importedTracks { add(t, profile: .straight, id: UUID(), pending: false, fallback: false, imported: true) }
            for leg in doc.project.legs { add(leg.points, profile: leg.profile, id: leg.id, pending: doc.pendingLegIDs.contains(leg.id), fallback: leg.fallback, imported: false) }
            // Les casings d'abord, puis les lignes, pour que la bordure blanche reste dessous.
            let ordered = new.filter { $0.isCasing } + new.filter { !$0.isCasing }
            map.addOverlays(ordered, level: .aboveLabels)
            legPolylines = ordered
            syncKilometerMarkers()
        }

        private func syncKilometerMarkers() {
            guard let map else { return }
            map.removeAnnotations(kmAnnotations)
            kmAnnotations = []
            guard settings.showKilometerMarkers else { return }
            let pts = doc.trackPoints
            guard pts.count >= 2 else { return }
            let cum = Geo.cumulativeDistances(pts)
            let total = cum.last ?? 0
            let step: Double = total > 60_000 ? 5000 : (total > 25_000 ? 2000 : 1000)
            var next = step
            var i = 1
            while next < total && i < pts.count {
                if cum[i] >= next {
                    let t = (next - cum[i - 1]) / max(1e-6, cum[i] - cum[i - 1])
                    let p = Geo.interpolate(pts[i - 1], pts[i], fraction: t)
                    kmAnnotations.append(KmAnnotation(km: Int(next / 1000), c: .init(latitude: p.lat, longitude: p.lon)))
                    next += step
                } else {
                    i += 1
                }
            }
            map.addAnnotations(kmAnnotations)
        }

        // MARK: Annotations

        func syncAnnotations() {
            guard let map else { return }
            // Ancres
            let anchors = doc.project.anchors
            let ids = Set(anchors.map { $0.id })
            for (id, a) in anchorAnnotations where !ids.contains(id) {
                map.removeAnnotation(a)
                anchorAnnotations[id] = nil
            }
            for (i, a) in anchors.enumerated() {
                let isLast = i == anchors.count - 1
                if let ann = anchorAnnotations[a.id] {
                    let changedRole = ann.index != i || ann.isLast != isLast
                    ann.index = i
                    ann.isLast = isLast
                    if draggingID != a.id, abs(ann.coordinate.latitude - a.lat) > 1e-9 || abs(ann.coordinate.longitude - a.lon) > 1e-9 {
                        ann.coordinate = .init(latitude: a.lat, longitude: a.lon)
                    }
                    if changedRole, let v = map.view(for: ann) { configure(anchorView: v, ann: ann) }
                } else if settings.showAnchors {
                    let ann = AnchorAnnotation(anchor: a, index: i, isLast: isLast)
                    anchorAnnotations[a.id] = ann
                    map.addAnnotation(ann)
                }
            }
            if !settings.showAnchors {
                map.removeAnnotations(Array(anchorAnnotations.values))
                anchorAnnotations = [:]
            }
            // Points d'intérêt
            let wps = doc.project.waypoints
            let wids = Set(wps.map { $0.id })
            for (id, w) in waypointAnnotations where !wids.contains(id) {
                map.removeAnnotation(w)
                waypointAnnotations[id] = nil
            }
            for w in wps {
                if let ann = waypointAnnotations[w.id] {
                    if ann.title != w.name { ann.title = w.name }
                    if draggingID != w.id, abs(ann.coordinate.latitude - w.lat) > 1e-9 || abs(ann.coordinate.longitude - w.lon) > 1e-9 {
                        ann.coordinate = .init(latitude: w.lat, longitude: w.lon)
                    }
                } else {
                    let ann = WaypointAnnotation(w: w)
                    waypointAnnotations[w.id] = ann
                    map.addAnnotation(ann)
                }
            }
            // Sélection
            if let sel = doc.selectedAnchorID, let ann = anchorAnnotations[sel], !(map.selectedAnnotations.first === ann) {
                map.selectAnnotation(ann, animated: false)
            }
        }

        func syncHover() {
            guard let map else { return }
            let pts = doc.trackPoints
            if let i = doc.hoverIndex, pts.indices.contains(i) {
                let c = CLLocationCoordinate2D(latitude: pts[i].lat, longitude: pts[i].lon)
                if let h = hoverAnnotation { h.coordinate = c } else {
                    let h = HoverAnnotation()
                    h.coordinate = c
                    hoverAnnotation = h
                    map.addAnnotation(h)
                }
            } else if let h = hoverAnnotation {
                map.removeAnnotation(h)
                hoverAnnotation = nil
            }
        }

        func syncUserDot() {
            guard let map else { return }
            if let c = controller.userCoordinate {
                if let d = userDot { d.coordinate = c } else {
                    let d = UserDotAnnotation()
                    d.coordinate = c
                    userDot = d
                    map.addAnnotation(d)
                }
            } else if let d = userDot {
                map.removeAnnotation(d)
                userDot = nil
            }
        }

        // MARK: Délégué MapKit

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: t)
            }
            if let l = overlay as? LegPolyline {
                let r = MKPolylineRenderer(polyline: l)
                r.lineCap = .round
                r.lineJoin = .round
                if l.isCasing {
                    r.strokeColor = NSColor.white.withAlphaComponent(0.9)
                    r.lineWidth = 7
                } else {
                    r.strokeColor = l.isImported ? NSColor.systemOrange : (l.fallback ? NSColor.systemRed : l.profile.color)
                    r.lineWidth = 4
                    if l.pending { r.lineDashPattern = [6, 6]; r.strokeColor = NSColor.systemGray }
                    if l.fallback { r.lineDashPattern = [10, 6] }
                }
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if let a = annotation as? AnchorAnnotation {
                let id = "anchor"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
                v.annotation = a
                v.isDraggable = true
                v.canShowCallout = false
                configure(anchorView: v, ann: a)
                return v
            }
            if let w = annotation as? WaypointAnnotation {
                let id = "wpt"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView) ?? MKMarkerAnnotationView(annotation: w, reuseIdentifier: id)
                v.annotation = w
                v.isDraggable = true
                v.canShowCallout = true
                v.markerTintColor = NSColor.systemIndigo
                v.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
                v.titleVisibility = .adaptive
                v.displayPriority = .required
                return v
            }
            if annotation is UserDotAnnotation {
                let id = "userdot"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.image = Self.userDotImage()
                v.isEnabled = false
                v.displayPriority = .required
                v.zPriority = .max
                return v
            }
            if annotation is HoverAnnotation {
                let id = "hover"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.image = Self.dotImage(diameter: 14, fill: .systemYellow, stroke: .black, strokeWidth: 2)
                v.isEnabled = false
                v.displayPriority = .required
                return v
            }
            if let k = annotation as? KmAnnotation {
                let id = "km"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: k, reuseIdentifier: id)
                v.annotation = k
                v.image = Self.kmImage(km: k.km)
                v.isEnabled = false
                v.displayPriority = .defaultLow
                v.collisionMode = .circle
                return v
            }
            return nil
        }

        func configure(anchorView v: MKAnnotationView, ann: AnchorAnnotation) {
            let isStart = ann.index == 0
            let fill: NSColor = isStart ? .systemGreen : (ann.isLast ? .systemRed : .white)
            let stroke: NSColor = isStart || ann.isLast ? .white : .systemBlue
            let d: CGFloat = isStart || ann.isLast ? 16 : 12
            v.image = Self.dotImage(diameter: d, fill: fill, stroke: stroke, strokeWidth: isStart || ann.isLast ? 2.5 : 2)
            v.displayPriority = .required
            v.zPriority = .max
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            switch newState {
            case .starting:
                if let a = view.annotation as? AnchorAnnotation { draggingID = a.anchorID }
                if let w = view.annotation as? WaypointAnnotation { draggingID = w.waypointID }
                view.dragState = .dragging
            case .ending, .canceling:
                defer { draggingID = nil; view.dragState = .none }
                if let a = view.annotation as? AnchorAnnotation {
                    doc.moveAnchor(id: a.anchorID, lat: a.coordinate.latitude, lon: a.coordinate.longitude)
                } else if let w = view.annotation as? WaypointAnnotation {
                    doc.moveWaypoint(id: w.waypointID, lat: w.coordinate.latitude, lon: w.coordinate.longitude)
                }
            default: break
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let a = view.annotation as? AnchorAnnotation { doc.selectedAnchorID = a.anchorID; doc.selectedWaypointID = nil }
            if let w = view.annotation as? WaypointAnnotation { doc.selectedWaypointID = w.waypointID; doc.selectedAnchorID = nil }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if let a = view.annotation as? AnchorAnnotation, doc.selectedAnchorID == a.anchorID { doc.selectedAnchorID = nil }
            if let w = view.annotation as? WaypointAnnotation, doc.selectedWaypointID == w.waypointID { doc.selectedWaypointID = nil }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            controller.zoomLevel = MapController.zoomLevel(for: mapView)
            controller.centerCoordinate = mapView.centerCoordinate
            let r = mapView.region
            UserDefaults.standard.set(["lat": r.center.latitude, "lon": r.center.longitude, "dlat": r.span.latitudeDelta, "dlon": r.span.longitudeDelta], forKey: "lastRegion")
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            if mapView.userTrackingMode == .follow, let loc = userLocation.location {
                mapView.setUserTrackingMode(.none, animated: false)
                controller.center(on: loc.coordinate, zoom: 14)
            }
        }

        // MARK: Gestes

        func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard let map else { return false }
            let p = map.convert(event.locationInWindow, from: nil)
            // Un clic sur une annotation ou un contrôle (boussole, échelle) est laissé à MapKit.
            if let hit = map.hitTest(p), hit !== map, !(hit is MKAnnotationView) || hit is MKAnnotationView {
                if hit is MKAnnotationView { return false }
                var v: NSView? = hit
                while let cur = v, cur !== map {
                    if cur is MKAnnotationView { return false }
                    if String(describing: type(of: cur)).contains("Compass") || String(describing: type(of: cur)).contains("Scale") { return false }
                    v = cur.superview
                }
            }
            return true
        }

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let map, g.state == .ended else { return }
            let p = g.location(in: map)
            // Double-clic = zoom MapKit : on attend l'intervalle de double-clic avant de poser le point.
            pendingClick?.cancel()
            if let e = NSApp.currentEvent, e.clickCount >= 2 { return }
            let work = DispatchWorkItem { [weak self] in self?.performClick(at: p) }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval * 0.8, execute: work)
        }

        /// Point d'entrée QA : même chemin que le clic souris, sans le délai de double-clic.
        func performClickForQA(at p: NSPoint) { performClick(at: p) }

        private func performClick(at p: NSPoint) {
            guard let map else { return }
            let c = map.convert(p, toCoordinateFrom: map)
            if let hit = hitLeg(at: p), doc.canEditAnchors, !doc.project.anchors.isEmpty {
                doc.insertAnchor(lat: hit.point.lat, lon: hit.point.lon, inLeg: hit.leg)
                return
            }
            if !doc.project.importedTracks.isEmpty && doc.project.anchors.isEmpty {
                // Trace importée : on la rend éditable puis on prolonge.
                doc.makeImportedEditable()
            }
            // ⌥-clic = ligne droite quel que soit le mode courant.
            let straight = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
            doc.appendAnchor(lat: c.latitude, lon: c.longitude, profile: straight ? .straight : nil)
        }

        /// Tronçon sous le curseur (distance écran < 7 pt).
        private func hitLeg(at p: NSPoint) -> (leg: Int, point: TrackPoint)? {
            guard let map, !doc.project.legs.isEmpty else { return nil }
            let c = map.convert(p, toCoordinateFrom: map)
            let target = TrackPoint(lat: c.latitude, lon: c.longitude)
            var best: (Int, TrackPoint, CGFloat)?
            for (i, leg) in doc.project.legs.enumerated() {
                guard let n = Geo.nearestPoint(on: leg.points, to: target) else { continue }
                let sp = map.convert(CLLocationCoordinate2D(latitude: n.point.lat, longitude: n.point.lon), toPointTo: map)
                let d = hypot(sp.x - p.x, sp.y - p.y)
                if d < 7, best == nil || d < best!.2 { best = (i, n.point, d) }
            }
            return best.map { ($0.0, $0.1) }
        }

        func mouseExited() {
            controller.mouseCoordinate = nil
            if lastMouseLegHit != nil { NSCursor.arrow.set(); lastMouseLegHit = nil }
            if hoverFromMap { doc.hoverIndex = nil; hoverFromMap = false }
        }

        func mouseMoved(at p: NSPoint) {
            guard let map else { return }
            let c = map.convert(p, toCoordinateFrom: map)
            controller.mouseCoordinate = c
            let hit = hitLeg(at: p)?.leg
            if hit != lastMouseLegHit {
                lastMouseLegHit = hit
                if hit != nil { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
            // Survol du tracé : le profil altimétrique suit la souris.
            if hit != nil {
                let pts = doc.trackPoints
                if let n = Geo.nearestPoint(on: pts, to: TrackPoint(lat: c.latitude, lon: c.longitude)) {
                    let idx = n.fraction < 0.5 ? n.segment : n.segment + 1
                    if doc.hoverIndex != idx { doc.hoverIndex = idx }
                }
            } else if doc.hoverIndex != nil && hoverFromMap {
                doc.hoverIndex = nil
            }
            hoverFromMap = hit != nil
        }

        // MARK: Menu contextuel

        func contextMenu(at p: NSPoint) -> NSMenu? {
            guard let map else { return nil }
            let c = map.convert(p, toCoordinateFrom: map)
            let menu = NSMenu()
            menu.autoenablesItems = false

            // Sur une ancre ?
            if let hit = map.hitTest(p) as? MKAnnotationView ?? map.hitTest(p)?.superview as? MKAnnotationView {
                if let a = hit.annotation as? AnchorAnnotation {
                    let i = a.index
                    menu.addItem(item("Supprimer ce point", key: "") { [weak self] in self?.doc.removeAnchor(id: a.anchorID) })
                    if i > 0 {
                        menu.addItem(profileSubmenu(title: "Tronçon précédent", legIndex: i - 1))
                    }
                    if i < doc.project.anchors.count - 1 {
                        menu.addItem(profileSubmenu(title: "Tronçon suivant", legIndex: i))
                    }
                    menu.addItem(.separator())
                    menu.addItem(item("Ajouter un point d'intérêt ici") { [weak self] in self?.doc.addWaypoint(lat: a.coordinate.latitude, lon: a.coordinate.longitude) })
                    return menu
                }
                if let w = hit.annotation as? WaypointAnnotation {
                    menu.addItem(item("Modifier le point d'intérêt…") { [weak self] in self?.doc.selectedWaypointID = w.waypointID; self?.doc.selectedAnchorID = nil })
                    menu.addItem(item("Supprimer le point d'intérêt") { [weak self] in self?.doc.removeWaypoint(id: w.waypointID) })
                    return menu
                }
            }

            let hasAnchors = !doc.project.anchors.isEmpty
            let current = doc.project.defaultProfile
            if hasAnchors {
                let main = item("Tracer jusqu'ici (\(current.title.lowercased()))", key: "") { [weak self] in
                    self?.doc.appendAnchor(lat: c.latitude, lon: c.longitude)
                }
                main.image = NSImage(systemSymbolName: current.symbolName, accessibilityDescription: nil)
                menu.addItem(main)
                if current != .shortest {
                    let s = item("Tracer jusqu'ici au plus court") { [weak self] in self?.doc.appendAnchor(lat: c.latitude, lon: c.longitude, profile: .shortest) }
                    s.image = NSImage(systemSymbolName: RoutingProfile.shortest.symbolName, accessibilityDescription: nil)
                    menu.addItem(s)
                }
                let straight = item("Tracer jusqu'ici en ligne droite") { [weak self] in self?.doc.appendAnchor(lat: c.latitude, lon: c.longitude, profile: .straight) }
                straight.image = NSImage(systemSymbolName: RoutingProfile.straight.symbolName, accessibilityDescription: nil)
                menu.addItem(straight)
                let others = NSMenuItem(title: "Tracer jusqu'ici en…", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for prof in RoutingProfile.allCases where prof != current && prof != .shortest && prof != .straight {
                    let it = item(prof.title) { [weak self] in self?.doc.appendAnchor(lat: c.latitude, lon: c.longitude, profile: prof) }
                    it.image = NSImage(systemSymbolName: prof.symbolName, accessibilityDescription: nil)
                    sub.addItem(it)
                }
                others.submenu = sub
                menu.addItem(others)
                if let hit = hitLeg(at: p) {
                    menu.addItem(.separator())
                    menu.addItem(item("Insérer un point sur le tracé ici") { [weak self] in self?.doc.insertAnchor(lat: hit.point.lat, lon: hit.point.lon, inLeg: hit.leg) })
                    menu.addItem(profileSubmenu(title: "Mode de ce tronçon", legIndex: hit.leg))
                }
            } else {
                let start = item(doc.project.importedTracks.isEmpty ? "Commencer le tracé ici" : "Prolonger la trace jusqu'ici") { [weak self] in
                    guard let self else { return }
                    if !self.doc.project.importedTracks.isEmpty { self.doc.makeImportedEditable() }
                    self.doc.appendAnchor(lat: c.latitude, lon: c.longitude)
                }
                start.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
                menu.addItem(start)
            }
            menu.addItem(.separator())
            menu.addItem(item("Ajouter un point d'intérêt ici") { [weak self] in self?.doc.addWaypoint(lat: c.latitude, lon: c.longitude) })
            if doc.project.anchors.count >= 2 {
                menu.addItem(.separator())
                menu.addItem(item("Revenir au départ (boucle)") { [weak self] in self?.doc.closeLoop() })
                menu.addItem(item("Supprimer le dernier point") { [weak self] in self?.doc.removeLastAnchor() })
            }
            menu.addItem(.separator())
            menu.addItem(item("Centrer la carte ici") { [weak self] in self?.controller.center(on: c) })
            menu.addItem(item("Copier les coordonnées") {
                let s = String(format: "%.6f, %.6f", c.latitude, c.longitude)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            })
            return menu
        }

        private func profileSubmenu(title: String, legIndex: Int) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let cur = doc.project.legs.indices.contains(legIndex) ? doc.project.legs[legIndex].profile : nil
            for prof in RoutingProfile.allCases {
                let m = item(prof.title) { [weak self] in self?.doc.setProfile(prof, forLegAt: legIndex) }
                m.image = NSImage(systemSymbolName: prof.symbolName, accessibilityDescription: nil)
                m.state = prof == cur ? .on : .off
                sub.addItem(m)
            }
            it.submenu = sub
            return it
        }

        private func item(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
            let it = MenuItem(title: title, action: #selector(MenuItem.fire), keyEquivalent: key)
            it.handler = action
            it.target = it
            return it
        }

        // MARK: Images

        static func dotImage(diameter: CGFloat, fill: NSColor, stroke: NSColor, strokeWidth: CGFloat) -> NSImage {
            let size = diameter + strokeWidth * 2 + 4
            let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let r = rect.insetBy(dx: (size - diameter) / 2, dy: (size - diameter) / 2)
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.set()
                fill.setFill()
                NSBezierPath(ovalIn: r).fill()
                NSShadow().set()
                stroke.setStroke()
                let p = NSBezierPath(ovalIn: r)
                p.lineWidth = strokeWidth
                p.stroke()
                return true
            }
            return img
        }

        /// Point bleu « Ma position » : halo translucide, disque bleu cerclé de blanc.
        static func userDotImage() -> NSImage {
            let size: CGFloat = 40
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSColor.systemBlue.withAlphaComponent(0.18).setFill()
                NSBezierPath(ovalIn: rect).fill()
                let r = rect.insetBy(dx: 12, dy: 12)
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.set()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: r).fill()
                NSShadow().set()
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5)).fill()
                return true
            }
        }

        static func kmImage(km: Int) -> NSImage {
            let text = "\(km)" as NSString
            let font = NSFont.systemFont(ofSize: 9, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let ts = text.size(withAttributes: attrs)
            let d = max(16, ts.width + 8)
            return NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                NSColor.white.setStroke()
                let p = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                p.lineWidth = 1.5
                p.stroke()
                text.draw(at: NSPoint(x: (d - ts.width) / 2, y: (d - ts.height) / 2), withAttributes: attrs)
                return true
            }
        }
    }
}

final class MenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

extension RoutingProfile {
    var color: NSColor {
        switch self {
        case .hiking: return .systemBlue
        case .roadBike: return .systemPurple
        case .gravel: return .systemTeal
        case .mtb: return .systemBrown
        case .shortest: return .systemIndigo
        case .car: return .systemGray
        case .straight: return .systemPink
        }
    }
}
