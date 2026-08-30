import Foundation

/// Un point géographique WGS84, avec altitude et horodatage optionnels.
public struct TrackPoint: Codable, Equatable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var time: Date?

    public init(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.time = time
    }
}

public enum Geo {
    public static let earthRadius: Double = 6_371_008.8

    /// Distance orthodromique en mètres (haversine).
    public static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let dφ = (lat2 - lat1) * .pi / 180
        let dλ = (lon2 - lon1) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Longueur totale d'une polyligne en mètres.
    public static func length(_ pts: [TrackPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<pts.count { d += distance(pts[i - 1], pts[i]) }
        return d
    }

    /// Distances cumulées (index 0 = 0).
    public static func cumulativeDistances(_ pts: [TrackPoint]) -> [Double] {
        var out = [Double](repeating: 0, count: pts.count)
        guard pts.count > 1 else { return out }
        for i in 1..<pts.count { out[i] = out[i - 1] + distance(pts[i - 1], pts[i]) }
        return out
    }

    /// Cap initial en degrés (0 = nord, 90 = est).
    public static func bearing(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Interpolation linéaire entre deux points (fraction 0…1), altitude interpolée si présente des deux côtés.
    public static func interpolate(_ a: TrackPoint, _ b: TrackPoint, fraction t: Double) -> TrackPoint {
        var p = TrackPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
        if let ea = a.ele, let eb = b.ele { p.ele = ea + (eb - ea) * t }
        return p
    }

    /// Ligne droite échantillonnée tous les `step` mètres (inclut les deux extrémités).
    public static func straightLine(from a: TrackPoint, to b: TrackPoint, step: Double = 25) -> [TrackPoint] {
        let d = distance(a, b)
        guard d > step else { return [a, b] }
        let n = Int(ceil(d / step))
        var out: [TrackPoint] = []
        out.reserveCapacity(n + 1)
        for i in 0...n { out.append(interpolate(a, b, fraction: Double(i) / Double(n))) }
        return out
    }

    // MARK: - Projection locale (mètres) pour les calculs planaires courts

    /// Projection équirectangulaire locale : (x, y) en mètres autour d'une origine.
    public static func localXY(_ p: TrackPoint, origin: TrackPoint) -> (x: Double, y: Double) {
        let kx = cos(origin.lat * .pi / 180) * .pi / 180 * earthRadius
        let ky = Double.pi / 180 * earthRadius
        return ((p.lon - origin.lon) * kx, (p.lat - origin.lat) * ky)
    }

    /// Point le plus proche de `p` sur la polyligne. Retourne l'index du segment (i -> i+1), la fraction sur ce segment,
    /// la distance (m) et le point projeté.
    public static func nearestPoint(on pts: [TrackPoint], to p: TrackPoint) -> (segment: Int, fraction: Double, distance: Double, point: TrackPoint)? {
        guard pts.count >= 2 else { return nil }
        var best: (Int, Double, Double, TrackPoint)?
        let o = p
        let pxy = (0.0, 0.0)
        for i in 0..<(pts.count - 1) {
            let a = localXY(pts[i], origin: o), b = localXY(pts[i + 1], origin: o)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 0 { t = max(0, min(1, ((pxy.0 - a.x) * dx + (pxy.1 - a.y) * dy) / len2)) }
            let cx = a.x + t * dx, cy = a.y + t * dy
            let d = sqrt((cx - pxy.0) * (cx - pxy.0) + (cy - pxy.1) * (cy - pxy.1))
            if best == nil || d < best!.2 {
                best = (i, t, d, interpolate(pts[i], pts[i + 1], fraction: t))
            }
        }
        return best.map { ($0.0, $0.1, $0.2, $0.3) }
    }

    // MARK: - Simplification Douglas-Peucker (tolérance en mètres)

    public static func simplify(_ pts: [TrackPoint], tolerance: Double) -> [TrackPoint] {
        guard pts.count > 2, tolerance > 0 else { return pts }
        let origin = pts[0]
        let xy = pts.map { localXY($0, origin: origin) }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e - s > 1 else { continue }
            let ax = xy[s].x, ay = xy[s].y, bx = xy[e].x, by = xy[e].y
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            var maxD = -1.0, idx = s
            for i in (s + 1)..<e {
                let px = xy[i].x, py = xy[i].y
                let d: Double
                if len2 == 0 {
                    d = sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay))
                } else {
                    d = abs(dy * px - dx * py + bx * ay - by * ax) / sqrt(len2)
                }
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return zip(pts, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Tuiles Web Mercator

    public static func tileXY(lat: Double, lon: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(zoom))
        let x = Int(floor((lon + 180) / 360 * n))
        let latR = lat * .pi / 180
        let y = Int(floor((1 - log(tan(latR) + 1 / cos(latR)) / .pi) / 2 * n))
        return (x, y)
    }

    /// Emprise (minLat, minLon, maxLat, maxLon) d'un nuage de points.
    public static func bounds(_ pts: [TrackPoint]) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        guard let f = pts.first else { return nil }
        var b = (f.lat, f.lon, f.lat, f.lon)
        for p in pts {
            b.0 = min(b.0, p.lat); b.1 = min(b.1, p.lon)
            b.2 = max(b.2, p.lat); b.3 = max(b.3, p.lon)
        }
        return b
    }
}
