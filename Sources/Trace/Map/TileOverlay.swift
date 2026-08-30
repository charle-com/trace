import Foundation
import MapKit

/// Description d'un fond de carte ou d'une surcouche raster.
struct MapLayer: Identifiable, Hashable {
    enum Kind { case apple(MKMapType), tiles }
    enum Group: String, CaseIterable { case ign = "IGN", osm = "OpenStreetMap", world = "Monde", apple = "Apple" }

    let id: String
    let title: String
    let subtitle: String
    let group: Group
    let kind: Kind
    /// Gabarit avec {x} {y} {z} et éventuellement {s} (sous-domaine).
    let template: String
    let subdomains: [String]
    let minZoom: Int
    let maxZoom: Int
    /// Le serveur propose-t-il des tuiles 512 px / @2x ? Sinon on assemble 4 tuiles du niveau suivant.
    let retinaTemplate: String?
    let attribution: String
    let isOverlay: Bool
    let symbol: String

    init(id: String, title: String, subtitle: String = "", group: Group, kind: Kind = .tiles, template: String = "", subdomains: [String] = [], minZoom: Int = 0, maxZoom: Int = 19, retinaTemplate: String? = nil, attribution: String = "", isOverlay: Bool = false, symbol: String = "map") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.kind = kind
        self.template = template
        self.subdomains = subdomains
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.retinaTemplate = retinaTemplate
        self.attribution = attribution
        self.isOverlay = isOverlay
        self.symbol = symbol
    }

    static func == (a: MapLayer, b: MapLayer) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func url(x: Int, y: Int, z: Int, retina: Bool) -> URL? {
        var t = (retina ? retinaTemplate : nil) ?? template
        t = t.replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
            .replacingOccurrences(of: "{z}", with: String(z))
        if !subdomains.isEmpty {
            let s = subdomains[abs(x + y) % subdomains.count]
            t = t.replacingOccurrences(of: "{s}", with: s)
        }
        return URL(string: t)
    }
}

/// Tuiles raster avec cache disque et rendu net sur écran Retina : si le serveur n'a pas de tuiles 512 px,
/// on assemble les 4 tuiles du niveau de zoom suivant dans une tuile 512 px (technique gpx.studio / Leaflet detectRetina).
final class LayerTileOverlay: MKTileOverlay {
    let layer: MapLayer
    private let retina: Bool
    static let diskCache: URLCache = {
        let dir = Network.cacheDirectory.appendingPathComponent("tiles")
        return URLCache(memoryCapacity: 128 << 20, diskCapacity: 2 << 30, directory: dir)
    }()
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": Network.userAgent, "Referer": "https://charlesneveu.fr/trace"]
        cfg.urlCache = diskCache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()
    /// Compteurs pour la QA.
    nonisolated(unsafe) static var loaded = 0
    nonisolated(unsafe) static var failed = 0

    init(layer: MapLayer, retina: Bool) {
        self.layer = layer
        self.retina = retina
        super.init(urlTemplate: nil)
        self.canReplaceMapContent = !layer.isOverlay
        self.minimumZ = layer.minZoom
        // Avec l'assemblage 2x on demande le niveau z+1 au serveur : on plafonne donc à maxZoom-1 en assemblage.
        let stitch = retina && layer.retinaTemplate == nil
        self.maximumZ = stitch ? layer.maxZoom - 1 : layer.maxZoom
        self.tileSize = retina ? CGSize(width: 512, height: 512) : CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        layer.url(x: path.x, y: path.y, z: path.z, retina: retina && layer.retinaTemplate != nil) ?? URL(string: "about:blank")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let stitch = retina && layer.retinaTemplate == nil
        if !stitch {
            fetch(url(forTilePath: path)) { data in
                if data != nil { Self.loaded += 1 } else { Self.failed += 1 }
                result(data, data == nil ? URLError(.cannotLoadFromNetwork) : nil)
            }
            return
        }
        // Assemblage 2x2 des tuiles z+1.
        let z = path.z + 1
        let group = DispatchGroup()
        var parts = [Data?](repeating: nil, count: 4)
        for i in 0..<4 {
            let dx = i % 2, dy = i / 2
            guard let u = layer.url(x: path.x * 2 + dx, y: path.y * 2 + dy, z: z, retina: false) else { continue }
            group.enter()
            fetch(u) { data in parts[i] = data; group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            let images = parts.map { $0.flatMap { NSImage(data: $0) } }
            if images.allSatisfy({ $0 == nil }) {
                Self.failed += 1
                result(nil, URLError(.cannotLoadFromNetwork))
                return
            }
            let out = NSImage(size: NSSize(width: 512, height: 512))
            out.lockFocus()
            for i in 0..<4 {
                guard let img = images[i] else { continue }
                let dx = CGFloat(i % 2) * 256, dy = CGFloat(1 - i / 2) * 256
                img.draw(in: NSRect(x: dx, y: dy, width: 256, height: 256), from: .zero, operation: .sourceOver, fraction: 1)
            }
            out.unlockFocus()
            guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                Self.failed += 1
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            Self.loaded += 1
            result(png, nil)
        }
    }

    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad
        Self.session.dataTask(with: req) { data, resp, _ in
            guard let data, let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 0 else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }
}
