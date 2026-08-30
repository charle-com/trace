import Foundation
import MapKit

/// Catalogue des fonds et surcouches. Toutes les URL ont été vérifiées le 30/08/2026 (voir README).
enum LayerCatalog {
    static let defaultBaseID = "ign.plan"

    private static let geopf = "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&STYLE=normal&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}"
    private static var geopfPrivate: String {
        "https://data.geopf.fr/private/wmts?apikey=\(ignKey)&SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&STYLE=normal&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}"
    }

    /// Clé Géoplateforme pour les couches SCAN (endpoint privé). Vide = couches SCAN absentes du catalogue.
    static var ignKey: String { UserDefaults.standard.string(forKey: "ignKey") ?? "" }
    static var thunderforestKey: String { UserDefaults.standard.string(forKey: "thunderforestKey") ?? "" }

    static var base: [MapLayer] {
        var l: [MapLayer] = [
            MapLayer(id: "ign.plan", title: "Plan IGN", subtitle: "Plan IGN v2, toute échelle", group: .ign,
                     template: geopf + "&FORMAT=image/png&LAYER=GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2", maxZoom: 19,
                     attribution: "© IGN", symbol: "map"),
        ]
        if !ignKey.isEmpty {
            l += [
                MapLayer(id: "ign.scan25", title: "Carte topo IGN", subtitle: "SCAN 25 (rando), du 1:100 000 au 1:25 000", group: .ign,
                         template: geopfPrivate + "&FORMAT=image/jpeg&LAYER=GEOGRAPHICALGRIDSYSTEMS.MAPS", maxZoom: 18,
                         attribution: "© IGN", symbol: "mountain.2"),
                MapLayer(id: "ign.scan25tour", title: "TOP 25 touristique", subtitle: "SCAN 25 Touristique, zoom 12 à 16", group: .ign,
                         template: geopfPrivate + "&FORMAT=image/jpeg&LAYER=GEOGRAPHICALGRIDSYSTEMS.MAPS.SCAN25TOUR", minZoom: 6, maxZoom: 16,
                         attribution: "© IGN", symbol: "figure.hiking"),
            ]
        }
        l += [
            MapLayer(id: "ign.ortho", title: "Photos aériennes IGN", subtitle: "Orthophotos, jusqu'à 20 cm", group: .ign,
                     template: geopf + "&FORMAT=image/jpeg&LAYER=ORTHOIMAGERY.ORTHOPHOTOS", maxZoom: 19,
                     attribution: "© IGN", symbol: "photo"),
            MapLayer(id: "osm.standard", title: "OpenStreetMap", subtitle: "Rendu standard", group: .osm,
                     template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png", maxZoom: 19,
                     attribution: "© OpenStreetMap contributors", symbol: "globe.europe.africa"),
            MapLayer(id: "osm.topo", title: "OpenTopoMap", subtitle: "Topographique, courbes de niveau", group: .osm,
                     template: "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png", subdomains: ["a", "b", "c"], maxZoom: 17,
                     attribution: "© OpenStreetMap contributors, SRTM. Rendu © OpenTopoMap (CC-BY-SA)", symbol: "mountain.2.fill"),
            MapLayer(id: "osm.cyclosm", title: "CyclOSM", subtitle: "Vélo : pistes, voies vertes, relief", group: .osm,
                     template: "https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png", subdomains: ["a", "b", "c"], maxZoom: 17,
                     attribution: "© OpenStreetMap contributors, style CyclOSM", symbol: "bicycle"),
            MapLayer(id: "osm.fr", title: "OSM France", subtitle: "Toponymie française détaillée", group: .osm,
                     template: "https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png", subdomains: ["a", "b", "c"], maxZoom: 19,
                     attribution: "© OpenStreetMap contributors, rendu OSM France", symbol: "map.fill"),
        ]
        if !thunderforestKey.isEmpty {
            for (id, title, sub, style) in [("tf.outdoors", "Thunderforest Outdoors", "Rando, refuges, sentiers", "outdoors"),
                                            ("tf.cycle", "OpenCycleMap", "Réseau cyclable, relief", "cycle"),
                                            ("tf.landscape", "Thunderforest Landscape", "Relief et paysage", "landscape")] {
                l.append(MapLayer(id: id, title: title, subtitle: sub, group: .world,
                                  template: "https://tile.thunderforest.com/\(style)/{z}/{x}/{y}.png?apikey=\(thunderforestKey)", maxZoom: 20,
                                  retinaTemplate: "https://tile.thunderforest.com/\(style)/{z}/{x}/{y}@2x.png?apikey=\(thunderforestKey)",
                                  attribution: "Maps © Thunderforest, Data © OpenStreetMap contributors", symbol: "leaf"))
            }
        }
        l += [
            MapLayer(id: "esri.imagery", title: "Satellite Esri", subtitle: "Imagerie mondiale (hors France)", group: .world,
                     template: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", maxZoom: 19,
                     attribution: "Source : Esri, Vantor, Earthstar Geographics, GIS User Community", symbol: "globe"),
            MapLayer(id: "apple.standard", title: "Plans Apple", subtitle: "Carte Apple native", group: .apple, kind: .apple(.standard), symbol: "apple.logo"),
            MapLayer(id: "apple.satellite", title: "Satellite Apple", subtitle: "Imagerie Apple", group: .apple, kind: .apple(.satellite), symbol: "globe.americas"),
            MapLayer(id: "apple.hybrid", title: "Hybride Apple", subtitle: "Imagerie et noms", group: .apple, kind: .apple(.hybrid), symbol: "globe.americas.fill"),
        ]
        return l
    }

    static var overlays: [MapLayer] {
        [
            MapLayer(id: "wmt.hiking", title: "Sentiers balisés", subtitle: "GR, PR, itinéraires de rando (Waymarked Trails)", group: .osm,
                     template: "https://tile.waymarkedtrails.org/hiking/{z}/{x}/{y}.png", maxZoom: 18,
                     attribution: "itinéraires © waymarkedtrails.org (CC-BY-SA)", isOverlay: true, symbol: "signpost.right"),
            MapLayer(id: "wmt.cycling", title: "Itinéraires vélo", subtitle: "Véloroutes, EuroVelo (Waymarked Trails)", group: .osm,
                     template: "https://tile.waymarkedtrails.org/cycling/{z}/{x}/{y}.png", maxZoom: 18,
                     attribution: "itinéraires © waymarkedtrails.org (CC-BY-SA)", isOverlay: true, symbol: "bicycle"),
            MapLayer(id: "wmt.mtb", title: "Itinéraires VTT", subtitle: "Circuits VTT balisés (Waymarked Trails)", group: .osm,
                     template: "https://tile.waymarkedtrails.org/mtb/{z}/{x}/{y}.png", maxZoom: 18,
                     attribution: "itinéraires © waymarkedtrails.org (CC-BY-SA)", isOverlay: true, symbol: "figure.outdoor.cycle"),
            MapLayer(id: "ign.contours", title: "Courbes de niveau IGN", subtitle: "Relief en courbes", group: .ign,
                     template: geopf + "&FORMAT=image/png&LAYER=ELEVATION.CONTOUR.LINE", minZoom: 6, maxZoom: 18,
                     attribution: "© IGN", isOverlay: true, symbol: "circle.circle"),
            MapLayer(id: "ign.shadow", title: "Estompage IGN", subtitle: "Ombrage du relief (LiDAR HD)", group: .ign,
                     template: geopf + "&FORMAT=image/png&LAYER=IGNF_LIDAR-HD_MNT_ELEVATION.ELEVATIONGRIDCOVERAGE.SHADOW", maxZoom: 18,
                     attribution: "© IGN", isOverlay: true, symbol: "sun.max"),
            MapLayer(id: "ign.slopes", title: "Pentes IGN", subtitle: "Pentes > 30° (ski de rando)", group: .ign,
                     template: geopf + "&FORMAT=image/png&LAYER=GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN", maxZoom: 17,
                     attribution: "© IGN", isOverlay: true, symbol: "triangle"),
            MapLayer(id: "ign.cadastre", title: "Cadastre", subtitle: "Parcelles (à partir du zoom 16)", group: .ign,
                     template: geopf + "&FORMAT=image/png&LAYER=CADASTRALPARCELS.PARCELLAIRE_EXPRESS", maxZoom: 19,
                     attribution: "© IGN, DGFiP", isOverlay: true, symbol: "square.grid.3x3"),
        ]
    }

    static func layer(id: String) -> MapLayer? {
        (base + overlays).first { $0.id == id }
    }
}
