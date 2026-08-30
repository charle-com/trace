import SwiftUI
import TraceCore

struct SidebarView: View {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var settings: MapSettings
    @ObservedObject var controller: MapController

    var body: some View {
        List(selection: Binding(get: { settings.baseLayerID }, set: { if let v = $0, LayerCatalog.base.contains(where: { $0.id == v }) { settings.baseLayerID = v } })) {
            ForEach(MapLayer.Group.allCases, id: \.self) { group in
                let layers = LayerCatalog.base.filter { $0.group == group }
                if !layers.isEmpty {
                    Section(group.rawValue) {
                        ForEach(layers) { layer in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(layer.title)
                                    if !layer.subtitle.isEmpty {
                                        Text(layer.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            } icon: {
                                Image(systemName: layer.symbol)
                            }
                            .tag(layer.id)
                        }
                    }
                }
            }
            Section("Surcouches") {
                ForEach(LayerCatalog.overlays) { layer in
                    Toggle(isOn: Binding(get: { settings.overlayIDs.contains(layer.id) }, set: { on in
                        if on { settings.overlayIDs.insert(layer.id) } else { settings.overlayIDs.remove(layer.id) }
                    })) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(layer.title)
                                Text(layer.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: { Image(systemName: layer.symbol) }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Section("Points d'intérêt") {
                if doc.project.waypoints.isEmpty {
                    Text("Clic droit sur la carte → « Ajouter un point d'intérêt »")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(doc.project.waypoints) { w in
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.indigo)
                        TextField("Nom", text: Binding(get: { w.name }, set: { var c = w; c.name = $0; doc.updateWaypoint(c) }))
                            .textFieldStyle(.plain)
                        Spacer()
                        Button {
                            controller.center(on: .init(latitude: w.lat, longitude: w.lon))
                        } label: { Image(systemName: "scope") }.buttonStyle(.plain).help("Centrer")
                        Button(role: .destructive) { doc.removeWaypoint(id: w.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).help("Supprimer")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Tracé")
    }
}
