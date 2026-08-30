import Foundation
import MapKit
import os

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
    let retina: Bool
    static let diskCache: URLCache = {
        let dir = Network.cacheDirectory.appendingPathComponent("tiles")
        return URLCache(memoryCapacity: 128 << 20, diskCapacity: 2 << 30, directory: dir)
    }()
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": Network.userAgent, "Referer": "https://charlesneveu.fr/trace"]
        cfg.urlCache = diskCache
        cfg.requestCachePolicy = .useProtocolCachePolicy   // respecte Expires / max-age (OSM : 7 jours et plus)
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()
    /// Compteurs pour la QA (modifiés depuis plusieurs queues).
    private static let counters = OSAllocatedUnfairLock(initialState: (loaded: 0, failed: 0))
    static var loaded: Int { counters.withLock { $0.loaded } }
    static var failed: Int { counters.withLock { $0.failed } }
    private static func count(success: Bool) {
        counters.withLock { if success { $0.loaded += 1 } else { $0.failed += 1 } }
    }

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
                Self.count(success: data != nil)
                result(data, data == nil ? URLError(.cannotLoadFromNetwork) : nil)
            }
            return
        }
        // Assemblage 2x2 des tuiles z+1 dans un bitmap exact de 512 px (pas de lockFocus : sûr hors thread principal).
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
            let images = parts.map { $0.flatMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) } }
            if images.allSatisfy({ $0 == nil }) {
                Self.count(success: false)
                result(nil, URLError(.cannotLoadFromNetwork))
                return
            }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
                Self.count(success: false)
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            let cg = ctx.cgContext
            cg.interpolationQuality = .none
            for i in 0..<4 {
                guard let img = images[i] else { continue }
                let dx = CGFloat(i % 2) * 256, dy = CGFloat(1 - i / 2) * 256
                cg.draw(img, in: CGRect(x: dx, y: dy, width: 256, height: 256))
            }
            guard let png = rep.representation(using: .png, properties: [:]) else {
                Self.count(success: false)
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            Self.count(success: true)
            result(png, nil)
        }
    }

    /// Une tuile n'est acceptée que si c'est une image (portail captif, page « accès bloqué » OSM en 200 : rejetées
    /// et purgées du cache). Hors ligne, la dernière version en cache est resservie, périmée ou non.
    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.cachePolicy = .useProtocolCachePolicy
        Self.session.dataTask(with: req) { data, resp, err in
            if let data, let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 0,
               http.mimeType?.hasPrefix("image/") == true, http.value(forHTTPHeaderField: "x-blocked") == nil {
                completion(data)
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { Self.diskCache.removeCachedResponse(for: req) }
            if err != nil, let cached = Self.diskCache.cachedResponse(for: req), cached.data.count > 0,
               (cached.response as? HTTPURLResponse)?.mimeType?.hasPrefix("image/") == true {
                completion(cached.data)
                return
            }
            completion(nil)
        }.resume()
    }
}
