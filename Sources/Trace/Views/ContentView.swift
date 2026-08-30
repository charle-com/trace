import SwiftUI
import MapKit
import TraceCore

struct ContentView: View {
    @ObservedObject var doc: TraceDocument
    @StateObject private var ctx: SceneContext
    @Environment(\.undoManager) private var undoManager

    init(doc: TraceDocument) {
        self.doc = doc
        _ctx = StateObject(wrappedValue: SceneContext(doc: doc))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(doc: doc, settings: ctx.settings, controller: ctx.controller)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailView(doc: doc, ctx: ctx)
        }
        .inspector(isPresented: $ctx.showInspector) {
            InspectorView(doc: doc, ctx: ctx, settings: ctx.settings)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { TraceToolbar(doc: doc, ctx: ctx) }
        .searchable(text: $ctx.searchText, placement: .toolbar, prompt: "Lieu, adresse…")
        .onSubmit(of: .search) { LocationSearch.search(ctx.searchText, controller: ctx.controller) }
        .focusedSceneObject(ctx)
        .focusedSceneValue(\.scene, ctx)
        .onAppear { doc.undoManager = undoManager; ctx.register() }
        .onChange(of: undoManager) { _, new in doc.undoManager = new }
        .sheet(isPresented: $ctx.showExport) { ExportSheet(doc: doc) }
        .alert("Calcul d'itinéraire", isPresented: Binding(get: { doc.lastError != nil }, set: { if !$0 { doc.lastError = nil } })) {
            Button("OK") { doc.lastError = nil }
        } message: {
            Text(doc.lastError ?? "")
        }
        .onDeleteCommand {
            if let id = doc.selectedWaypointID { doc.removeWaypoint(id: id) }
            else if let id = doc.selectedAnchorID { doc.removeAnchor(id: id) }
            else { doc.removeLastAnchor() }
        }
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let s = doc.stats
        guard s.distance > 0 else { return "Cliquez sur la carte pour commencer le tracé" }
        var parts = [Stats.formatDistance(s.distance)]
        if s.hasElevation { parts.append("D+ \(Stats.formatElevation(s.ascent))") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Carte + surcouches d'interface

struct DetailView: View {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var ctx: SceneContext

    var body: some View {
        VSplitView {
            MapContainer(doc: doc, ctx: ctx)
                .frame(minHeight: 300)
            if ctx.showProfile {
                ElevationProfileView(doc: doc, controller: ctx.controller)
                    .frame(minHeight: 140, idealHeight: 190, maxHeight: 320)
            }
        }
    }
}

struct MapContainer: View {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var ctx: SceneContext

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapView(doc: doc, settings: ctx.settings, controller: ctx.controller)
                .ignoresSafeArea()
            MapControls(doc: doc, ctx: ctx)
                .padding(12)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    StatusPill(controller: ctx.controller)
                    Spacer()
                    AttributionLabel(settings: ctx.settings)
                }
                .padding(8)
            }
            if doc.project.isEmpty {
                EmptyHint()
            }
            if !doc.pendingLegIDs.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Calcul de l'itinéraire…").font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
            }
        }
    }
}

struct MapControls: View {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var ctx: SceneContext

    var body: some View {
        VStack(spacing: 0) {
            control("plus", "Zoom avant") { ctx.controller.zoom(by: 2) }
            Divider().frame(width: 20)
            control("minus", "Zoom arrière") { ctx.controller.zoom(by: 0.5) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        VStack(spacing: 0) {
            control("location", "Ma position") { ctx.controller.showUserLocation() }
            Divider().frame(width: 20)
            control("arrow.up.left.and.arrow.down.right", "Ajuster au tracé") {
                ctx.controller.zoomToFit(doc.trackPoints.map { .init(latitude: $0.lat, longitude: $0.lon) })
            }
            .disabled(doc.trackPoints.count < 2)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(.top, 8)
    }

    private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusPill: View {
    @ObservedObject var controller: MapController
    var body: some View {
        HStack(spacing: 10) {
            if let c = controller.mouseCoordinate {
                Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    .monospacedDigit()
            } else {
                Text(String(format: "%.5f, %.5f", controller.centerCoordinate.latitude, controller.centerCoordinate.longitude))
                    .monospacedDigit()
            }
            Text("z \(Int(controller.zoomLevel.rounded()))").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }
}

struct AttributionLabel: View {
    @ObservedObject var settings: MapSettings
    var body: some View {
        let parts = ([settings.baseLayer.attribution] + settings.overlays.map { $0.attribution }).filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(Array(Set(parts)).sorted().joined(separator: " · "))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.point.up.left").font(.title2)
            Text("Cliquez sur la carte pour poser le départ,\npuis cliquez (ou clic droit → « Tracer jusqu'ici ») pour prolonger.")
                .multilineTextAlignment(.center)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Barre d'outils

struct TraceToolbar: ToolbarContent {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var ctx: SceneContext

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Menu {
                ForEach(RoutingProfile.allCases) { p in
                    Button { doc.setDefaultProfile(p) } label: {
                        Label(p.title, systemImage: p.symbolName)
                    }
                }
            } label: {
                Label(doc.project.defaultProfile.title, systemImage: doc.project.defaultProfile.symbolName)
                    .labelStyle(.titleAndIcon)
            }
            .menuIndicator(.visible)
            .help("Mode de calcul des nouveaux tronçons (⌘⌥1 à ⌘⌥7). ⌥-clic sur la carte = ligne droite.")
        }
        ToolbarItemGroup {
            Button { doc.closeLoop() } label: { Label("Boucle", systemImage: "arrow.triangle.capsulepath") }
                .help("Revenir au départ par le chemin le plus adapté")
                .disabled(doc.project.anchors.count < 2)
            Button { doc.reverse() } label: { Label("Inverser", systemImage: "arrow.left.arrow.right") }
                .help("Inverser le sens du tracé")
                .disabled(doc.trackPoints.count < 2)
            Button { doc.removeLastAnchor() } label: { Label("Dernier point", systemImage: "delete.left") }
                .help("Supprimer le dernier point")
                .disabled(doc.project.anchors.isEmpty)
        }
        ToolbarItemGroup {
            ShareButton(doc: doc)
            Button { ctx.showExport = true } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                .help("Exporter en GPX pour l'Apple Watch")
                .disabled(doc.trackPoints.count < 2)
            Button { ctx.showProfile.toggle() } label: { Label("Profil", systemImage: "chart.xyaxis.line") }
                .help("Afficher le profil altimétrique")
            Button { ctx.showInspector.toggle() } label: { Label("Inspecteur", systemImage: "sidebar.trailing") }
                .help("Afficher l'inspecteur")
        }
    }
}

/// Bouton de partage (AirDrop, Mail, Messages…) : écrit un GPX propre dans un fichier temporaire.
struct ShareButton: View {
    @ObservedObject var doc: TraceDocument
    var body: some View {
        ShareAnchor(doc: doc)
            .frame(width: 28, height: 22)
            .help("Envoyer le GPX (AirDrop vers l'iPhone, Mail…)")
            .disabled(doc.trackPoints.count < 2)
    }
}

struct ShareAnchor: NSViewRepresentable {
    @ObservedObject var doc: TraceDocument
    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: "Partager")!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = "Partager le GPX"
        return b
    }
    func updateNSView(_ v: NSButton, context: Context) { context.coordinator.doc = doc }
    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    @MainActor final class Coordinator: NSObject {
        var doc: TraceDocument
        init(doc: TraceDocument) { self.doc = doc }
        @objc func share(_ sender: NSButton) {
            guard let url = ExportHelper.writeTemporaryGPX(doc: doc) else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

enum ExportHelper {
    @MainActor static func writeTemporaryGPX(doc: TraceDocument, options: GPXWriteOptions? = nil) -> URL? {
        let opts = options ?? GPXWriteOptions(includeElevation: true, includeWaypoints: true, simplifyTolerance: 0, embedProject: false)
        let data = doc.exportGPX(options: opts)
        let name = doc.project.name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Trace-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name.isEmpty ? "Tracé" : name).gpx")
        do { try data.write(to: url); return url } catch { return nil }
    }
}

// MARK: - Recherche de lieu

enum LocationSearch {
    @MainActor static func search(_ text: String, controller: MapController) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        // Coordonnées « lat, lon » saisies directement.
        let comps = q.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if comps.count == 2, abs(comps[0]) <= 90, abs(comps[1]) <= 180 {
            controller.center(on: .init(latitude: comps[0], longitude: comps[1]), zoom: 14)
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let map = controller.mapView { req.region = map.region }
        MKLocalSearch(request: req).start { resp, _ in
            guard let item = resp?.mapItems.first else { return }
            Task { @MainActor in
                let c = item.placemark.coordinate
                controller.center(on: c, zoom: 13)
            }
        }
    }
}
