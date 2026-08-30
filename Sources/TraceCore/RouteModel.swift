import Foundation

/// Mode de calcul d'un tronçon entre deux points d'ancrage.
public enum RoutingProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case hiking      // Randonnée / marche / trail
    case roadBike    // Vélo route
    case gravel      // Gravel / trekking (petites routes, chemins roulants)
    case mtb         // VTT
    case shortest    // Au plus court, tout chemin confondu
    case car         // Voiture
    case straight    // Ligne droite (vol d'oiseau)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hiking: return "Randonnée"
        case .roadBike: return "Vélo route"
        case .gravel: return "Gravel"
        case .mtb: return "VTT"
        case .shortest: return "Au plus court"
        case .car: return "Voiture"
        case .straight: return "Ligne droite"
        }
    }

    public var symbolName: String {
        switch self {
        case .hiking: return "figure.hiking"
        case .roadBike: return "bicycle"
        case .gravel: return "bicycle.circle"
        case .mtb: return "figure.outdoor.cycle"
        case .shortest: return "point.topleft.down.to.point.bottomright.curvepath"
        case .car: return "car"
        case .straight: return "line.diagonal"
        }
    }

    public var isRouted: Bool { self != .straight }

    /// Vitesse plate de référence (km/h) pour l'estimation de durée.
    public var defaultSpeedKmh: Double {
        switch self {
        case .hiking, .straight, .shortest: return 4.5
        case .roadBike: return 24
        case .gravel: return 18
        case .mtb: return 14
        case .car: return 60
        }
    }
}

/// Point d'ancrage posé par l'utilisateur. Les tronçons relient les ancres consécutives.
public struct Anchor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var lat: Double
    public var lon: Double

    public init(id: UUID = UUID(), lat: Double, lon: Double) {
        self.id = id
        self.lat = lat
        self.lon = lon
    }

    public var point: TrackPoint { TrackPoint(lat: lat, lon: lon) }
}

/// Tronçon calculé entre l'ancre i et l'ancre i+1.
public struct Leg: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var profile: RoutingProfile
    public var points: [TrackPoint]
    /// Vrai si le calcul a échoué et que la ligne droite a été substituée.
    public var fallback: Bool

    public init(id: UUID = UUID(), profile: RoutingProfile, points: [TrackPoint], fallback: Bool = false) {
        self.id = id
        self.profile = profile
        self.points = points
        self.fallback = fallback
    }

    public var distance: Double { Geo.length(points) }
}

/// Projet complet : ancres, tronçons, points d'intérêt. Sérialisé en JSON dans le GPX de travail.
public struct RouteProject: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    public var name: String
    public var notes: String
    public var anchors: [Anchor]
    public var legs: [Leg]
    public var waypoints: [Waypoint]
    public var defaultProfile: RoutingProfile
    /// Trace importée non éditable par ancres (fichier GPX ouvert tel quel). Vide si projet natif.
    public var importedTracks: [[TrackPoint]]

    public init(name: String = "Nouveau tracé", notes: String = "", anchors: [Anchor] = [], legs: [Leg] = [], waypoints: [Waypoint] = [], defaultProfile: RoutingProfile = .hiking, importedTracks: [[TrackPoint]] = []) {
        self.version = Self.formatVersion
        self.name = name
        self.notes = notes
        self.anchors = anchors
        self.legs = legs
        self.waypoints = waypoints
        self.defaultProfile = defaultProfile
        self.importedTracks = importedTracks
    }

    /// Invariant : legs.count == max(0, anchors.count - 1).
    public var isConsistent: Bool { legs.count == max(0, anchors.count - 1) }

    /// Polyligne complète (tronçons enchaînés, jonctions dédoublonnées).
    public var trackPoints: [TrackPoint] {
        if anchors.count <= 1 && !importedTracks.isEmpty { return importedTracks.flatMap { $0 } }
        var out: [TrackPoint] = []
        for leg in legs {
            var pts = leg.points
            if let last = out.last, let first = pts.first, abs(last.lat - first.lat) < 1e-9, abs(last.lon - first.lon) < 1e-9 {
                pts.removeFirst()
            }
            out.append(contentsOf: pts)
        }
        if out.isEmpty, let a = anchors.first { out = [a.point] }
        return out
    }

    public var totalDistance: Double { Geo.length(trackPoints) }
    public var isEmpty: Bool { anchors.isEmpty && importedTracks.isEmpty }

    /// Index du tronçon et distance cumulée au début de chaque tronçon.
    public var legStartDistances: [Double] {
        var out: [Double] = []
        var acc = 0.0
        for leg in legs { out.append(acc); acc += leg.distance }
        return out
    }

    // MARK: - JSON

    public func jsonString() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    public static func fromJSON(_ s: String) throws -> RouteProject {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RouteProject.self, from: Data(s.utf8))
    }

    // MARK: - Conversion GPX

    /// Construit le GPXFile correspondant (une trace unique, waypoints, projet embarqué).
    public func toGPX(embedProject: Bool) -> GPXFile {
        var f = GPXFile(name: name, desc: notes.isEmpty ? nil : notes, creator: "Tracé")
        f.waypoints = waypoints
        let pts = trackPoints
        if pts.count >= 2 {
            f.tracks = [GPXTrack(name: name, segments: [pts])]
        } else if !importedTracks.isEmpty {
            f.tracks = [GPXTrack(name: name, segments: importedTracks)]
        }
        if embedProject { f.projectJSON = try? jsonString() }
        return f
    }

    /// Reconstruit un projet depuis un GPX : projet embarqué si présent, sinon trace importée.
    public static func fromGPX(_ file: GPXFile, fallbackName: String) -> RouteProject {
        if let js = file.projectJSON, let p = try? fromJSON(js), p.isConsistent {
            return p
        }
        var p = RouteProject(name: file.name ?? fallbackName, notes: file.desc ?? "")
        p.waypoints = file.waypoints
        let segs = file.tracks.flatMap { $0.segments }.filter { !$0.isEmpty }
        p.importedTracks = segs
        return p
    }
}
