import Foundation

/// Point d'intérêt (waypoint GPX).
public struct Waypoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var name: String
    public var desc: String?
    public var symbol: String?

    public init(id: UUID = UUID(), lat: Double, lon: Double, ele: Double? = nil, name: String, desc: String? = nil, symbol: String? = nil) {
        self.id = id
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.name = name
        self.desc = desc
        self.symbol = symbol
    }
}

public struct GPXTrack: Equatable, Sendable {
    public var name: String?
    public var segments: [[TrackPoint]]
    public init(name: String? = nil, segments: [[TrackPoint]]) {
        self.name = name
        self.segments = segments
    }
    public var allPoints: [TrackPoint] { segments.flatMap { $0 } }
}

/// Contenu d'un fichier GPX tel que lu. Les `<rte>` sont convertis en tracks pour simplifier.
public struct GPXFile: Equatable, Sendable {
    public var name: String?
    public var desc: String?
    public var creator: String?
    public var time: Date?
    public var waypoints: [Waypoint]
    public var tracks: [GPXTrack]
    /// Contenu brut de `<metadata><extensions><trace:project>` si présent (JSON du projet).
    public var projectJSON: String?

    public init(name: String? = nil, desc: String? = nil, creator: String? = nil, time: Date? = nil, waypoints: [Waypoint] = [], tracks: [GPXTrack] = [], projectJSON: String? = nil) {
        self.name = name
        self.desc = desc
        self.creator = creator
        self.time = time
        self.waypoints = waypoints
        self.tracks = tracks
        self.projectJSON = projectJSON
    }

    public var allPoints: [TrackPoint] { tracks.flatMap { $0.allPoints } }
}

public enum GPXError: Error, LocalizedError {
    case parse(String)
    case empty
    public var errorDescription: String? {
        switch self {
        case .parse(let m): return "GPX illisible : \(m)"
        case .empty: return "Le fichier ne contient aucun point."
        }
    }
}

// MARK: - Lecture

public enum GPXReader {
    public static func read(_ data: Data) throws -> GPXFile {
        let d = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw GPXError.parse(parser.parserError?.localizedDescription ?? "erreur XML")
        }
        if let e = d.error { throw e }
        return d.file
    }

    public static func read(url: URL) throws -> GPXFile {
        try read(Data(contentsOf: url))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var file = GPXFile()
        var error: GPXError?

        private var stack: [String] = []
        private var text = ""
        private var currentPoint: TrackPoint?
        private var pointKind: String? // "trkpt" | "rtept" | "wpt"
        private var wptName = "", wptDesc = "", wptSym = ""
        private var currentSegment: [TrackPoint] = []
        private var currentTrack: GPXTrack?
        private var inMetadata = false
        private var projectBuffer = ""
        private var inProject = false

        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let isoNoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        static func parseDate(_ s: String) -> Date? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return iso.date(from: t) ?? isoNoFrac.date(from: t)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let name = localName(elementName)
            stack.append(name)
            text = ""
            switch name {
            case "gpx":
                file.creator = attributes["creator"]
            case "metadata":
                inMetadata = true
            case "trk":
                currentTrack = GPXTrack(name: nil, segments: [])
            case "rte":
                currentTrack = GPXTrack(name: nil, segments: [])
                currentSegment = []
            case "trkseg":
                currentSegment = []
            case "trkpt", "rtept", "wpt":
                if let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) {
                    currentPoint = TrackPoint(lat: la, lon: lo)
                } else {
                    currentPoint = nil
                }
                pointKind = name
                wptName = ""; wptDesc = ""; wptSym = ""
            case "project":
                if stack.contains("extensions") { inProject = true; projectBuffer = "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if inProject { projectBuffer += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            let s = String(data: CDATABlock, encoding: .utf8) ?? ""
            text += s
            if inProject { projectBuffer += s }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = localName(elementName)
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "metadata":
                inMetadata = false
            case "name":
                if parent == "metadata" || (parent == "gpx" && file.name == nil) { file.name = value }
                else if parent == "trk" || parent == "rte" { currentTrack?.name = value }
                else if parent == "wpt" || parent == "trkpt" || parent == "rtept" { wptName = value }
            case "desc":
                if parent == "metadata" || parent == "gpx" { file.desc = value }
                else if parent == "wpt" { wptDesc = value }
            case "sym":
                if parent == "wpt" { wptSym = value }
            case "ele":
                if currentPoint != nil { currentPoint?.ele = Double(value) }
            case "time":
                if currentPoint != nil { currentPoint?.time = Self.parseDate(value) }
                else if parent == "metadata" || parent == "gpx" { file.time = Self.parseDate(value) }
            case "trkpt", "rtept":
                if let p = currentPoint { currentSegment.append(p) }
                currentPoint = nil; pointKind = nil
            case "wpt":
                if let p = currentPoint {
                    file.waypoints.append(Waypoint(lat: p.lat, lon: p.lon, ele: p.ele, name: wptName.isEmpty ? "Point" : wptName, desc: wptDesc.isEmpty ? nil : wptDesc, symbol: wptSym.isEmpty ? nil : wptSym))
                }
                currentPoint = nil; pointKind = nil
            case "trkseg":
                if !currentSegment.isEmpty { currentTrack?.segments.append(currentSegment) }
                currentSegment = []
            case "trk":
                if let t = currentTrack, !t.segments.isEmpty { file.tracks.append(t) }
                currentTrack = nil
            case "rte":
                if var t = currentTrack {
                    if !currentSegment.isEmpty { t.segments.append(currentSegment) }
                    if !t.segments.isEmpty { file.tracks.append(t) }
                }
                currentTrack = nil; currentSegment = []
            case "project":
                if inProject {
                    file.projectJSON = projectBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    inProject = false
                }
            default: break
            }
            stack.removeLast()
            text = ""
        }

        private func localName(_ s: String) -> String {
            if let i = s.lastIndex(of: ":") { return String(s[s.index(after: i)...]) }
            return s
        }
    }
}

// MARK: - Écriture

public struct GPXWriteOptions: Sendable {
    public var creator: String
    public var includeElevation: Bool
    public var includeTime: Bool
    public var includeWaypoints: Bool
    /// Tolérance Douglas-Peucker en mètres (0 = pas de simplification).
    public var simplifyTolerance: Double
    /// Écrit le projet dans `<metadata><extensions>` (fichier de travail) ; false pour un export propre.
    public var embedProject: Bool
    public var asRoute: Bool

    public init(creator: String = "Tracé", includeElevation: Bool = true, includeTime: Bool = false, includeWaypoints: Bool = true, simplifyTolerance: Double = 0, embedProject: Bool = false, asRoute: Bool = false) {
        self.creator = creator
        self.includeElevation = includeElevation
        self.includeTime = includeTime
        self.includeWaypoints = includeWaypoints
        self.simplifyTolerance = simplifyTolerance
        self.embedProject = embedProject
        self.asRoute = asRoute
    }
}

public enum GPXWriter {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func write(_ file: GPXFile, options: GPXWriteOptions = GPXWriteOptions()) -> Data {
        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"\(esc(options.creator))\""
        s += " xmlns=\"http://www.topografix.com/GPX/1/1\""
        s += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
        s += " xmlns:trace=\"https://charlesneveu.fr/trace/1\""
        s += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        s += "  <metadata>\n"
        if let n = file.name { s += "    <name>\(esc(n))</name>\n" }
        if let d = file.desc, !d.isEmpty { s += "    <desc>\(esc(d))</desc>\n" }
        s += "    <time>\(iso.string(from: file.time ?? Date()))</time>\n"
        if let b = Geo.bounds(file.allPoints) {
            s += "    <bounds minlat=\"\(fmt(b.minLat))\" minlon=\"\(fmt(b.minLon))\" maxlat=\"\(fmt(b.maxLat))\" maxlon=\"\(fmt(b.maxLon))\"/>\n"
        }
        if options.embedProject, let pj = file.projectJSON {
            s += "    <extensions>\n      <trace:project><![CDATA[\(pj.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>"))]]></trace:project>\n    </extensions>\n"
        }
        s += "  </metadata>\n"
        if options.includeWaypoints {
            for w in file.waypoints {
                s += "  <wpt lat=\"\(fmt(w.lat))\" lon=\"\(fmt(w.lon))\">\n"
                if options.includeElevation, let e = w.ele { s += "    <ele>\(fmt(e, 1))</ele>\n" }
                s += "    <name>\(esc(w.name))</name>\n"
                if let d = w.desc, !d.isEmpty { s += "    <desc>\(esc(d))</desc>\n" }
                if let sym = w.symbol, !sym.isEmpty { s += "    <sym>\(esc(sym))</sym>\n" }
                s += "  </wpt>\n"
            }
        }
        for t in file.tracks {
            let tag = options.asRoute ? "rte" : "trk"
            let ptag = options.asRoute ? "rtept" : "trkpt"
            s += "  <\(tag)>\n"
            s += "    <name>\(esc(t.name ?? file.name ?? "Tracé"))</name>\n"
            for seg in t.segments {
                let pts = options.simplifyTolerance > 0 ? Geo.simplify(seg, tolerance: options.simplifyTolerance) : seg
                if !options.asRoute { s += "    <trkseg>\n" }
                for p in pts {
                    s += "      <\(ptag) lat=\"\(fmt(p.lat))\" lon=\"\(fmt(p.lon))\">"
                    var inner = ""
                    if options.includeElevation, let e = p.ele { inner += "<ele>\(fmt(e, 1))</ele>" }
                    if options.includeTime, let tm = p.time { inner += "<time>\(iso.string(from: tm))</time>" }
                    s += inner
                    s += "</\(ptag)>\n"
                }
                if !options.asRoute { s += "    </trkseg>\n" }
            }
            s += "  </\(tag)>\n"
        }
        s += "</gpx>\n"
        return Data(s.utf8)
    }

    static func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&apos;"
            default: o.append(c)
            }
        }
        return o
    }

    static func fmt(_ v: Double, _ decimals: Int = 6) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}
