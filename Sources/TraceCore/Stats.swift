import Foundation

/// Statistiques d'une trace.
public struct TrackStats: Equatable, Sendable {
    public var distance: Double        // m
    public var ascent: Double          // m (D+)
    public var descent: Double         // m (D-)
    public var minElevation: Double?
    public var maxElevation: Double?
    public var pointCount: Int
    public var hasElevation: Bool

    public static let empty = TrackStats(distance: 0, ascent: 0, descent: 0, minElevation: nil, maxElevation: nil, pointCount: 0, hasElevation: false)
}

/// Un échantillon du profil altimétrique.
public struct ProfileSample: Equatable, Identifiable, Sendable {
    public var id: Int            // ordinal de l'échantillon
    public var index: Int         // index du point d'origine
    public var distance: Double   // m cumulés
    public var elevation: Double  // m
    public var grade: Double      // pente en % (moyenne locale)
    public init(id: Int, index: Int, distance: Double, elevation: Double, grade: Double) {
        self.id = id
        self.index = index
        self.distance = distance
        self.elevation = elevation
        self.grade = grade
    }
}

public enum Stats {
    /// Seuil d'hystérésis (m) : une variation n'est comptée que lorsqu'elle dépasse ce seuil.
    /// Valeur usuelle des outils grand public (gpx.studio, Garmin Connect) : 3 à 10 m selon la source d'altitude.
    public static let defaultAscentThreshold: Double = 5

    /// Lissage par moyenne glissante sur une fenêtre en mètres (0 = pas de lissage).
    public static func smoothedElevations(_ pts: [TrackPoint], window: Double = 100) -> [Double]? {
        let eles = pts.map { $0.ele }
        guard !eles.isEmpty, eles.allSatisfy({ $0 != nil }) else { return nil }
        let e = eles.map { $0! }
        guard window > 0, pts.count > 2 else { return e }
        let cum = Geo.cumulativeDistances(pts)
        var out = [Double](repeating: 0, count: e.count)
        var lo = 0, hi = 0
        var sum = 0.0
        for i in 0..<e.count {
            let center = cum[i]
            while hi < e.count && cum[hi] <= center + window / 2 { sum += e[hi]; hi += 1 }
            while lo < hi && cum[lo] < center - window / 2 { sum -= e[lo]; lo += 1 }
            out[i] = sum / Double(max(1, hi - lo))
        }
        return out
    }

    /// D+ / D- avec hystérésis : on ne comptabilise que les mouvements cumulés supérieurs au seuil.
    public static func ascentDescent(_ elevations: [Double], threshold: Double = defaultAscentThreshold) -> (ascent: Double, descent: Double) {
        guard elevations.count > 1 else { return (0, 0) }
        var up = 0.0, down = 0.0
        var ref = elevations[0]
        for e in elevations.dropFirst() {
            let d = e - ref
            if d >= threshold { up += d; ref = e }
            else if d <= -threshold { down += -d; ref = e }
        }
        return (up, down)
    }

    public static func compute(_ pts: [TrackPoint], smoothingWindow: Double = 100, threshold: Double = defaultAscentThreshold) -> TrackStats {
        guard !pts.isEmpty else { return .empty }
        let dist = Geo.length(pts)
        if let sm = smoothedElevations(pts, window: smoothingWindow) {
            let ad = ascentDescent(sm, threshold: threshold)
            return TrackStats(distance: dist, ascent: ad.ascent, descent: ad.descent, minElevation: sm.min(), maxElevation: sm.max(), pointCount: pts.count, hasElevation: true)
        }
        return TrackStats(distance: dist, ascent: 0, descent: 0, minElevation: nil, maxElevation: nil, pointCount: pts.count, hasElevation: false)
    }

    /// Échantillonne le profil sur au plus `maxSamples` points, régulièrement en distance.
    public static func profile(_ pts: [TrackPoint], maxSamples: Int = 600, smoothingWindow: Double = 100) -> [ProfileSample] {
        guard pts.count >= 2, let sm = smoothedElevations(pts, window: smoothingWindow) else { return [] }
        let cum = Geo.cumulativeDistances(pts)
        let total = cum.last ?? 0
        guard total > 0 else { return [] }
        let n = min(maxSamples, pts.count)
        var out: [ProfileSample] = []
        out.reserveCapacity(n)
        var j = 0
        for k in 0..<n {
            let target = total * Double(k) / Double(n - 1)
            while j < cum.count - 1 && cum[j + 1] <= target { j += 1 }
            if k == n - 1 { j = cum.count - 1 }
            // Pente locale sur ~100 m autour de j.
            var a = j, b = j
            while a > 0 && cum[j] - cum[a] < 50 { a -= 1 }
            while b < cum.count - 1 && cum[b] - cum[j] < 50 { b += 1 }
            let dd = cum[b] - cum[a]
            let grade = dd > 0 ? (sm[b] - sm[a]) / dd * 100 : 0
            out.append(ProfileSample(id: k, index: j, distance: cum[j], elevation: sm[j], grade: grade))
        }
        return out
    }

    /// Durée estimée en secondes.
    /// Marche : règle des randonneurs (4,5 km/h à plat + 1 h par 350 m de D+ + 1 h par 700 m de D-), à la manière de la formule
    /// « temps = max(horizontal, vertical) + min(horizontal, vertical) / 2 » du CAS suisse.
    /// Vélo : vitesse à plat + 1 h par 700 m de D+ (route) ou 500 m (VTT).
    public static func estimatedDuration(distance: Double, ascent: Double, descent: Double, profile: RoutingProfile, flatSpeedKmh: Double? = nil) -> TimeInterval {
        let v = flatSpeedKmh ?? profile.defaultSpeedKmh
        let horizontal = distance / 1000 / v * 3600
        switch profile {
        case .hiking, .shortest, .straight:
            let vertical = ascent / 350 * 3600 + descent / 700 * 3600
            return max(horizontal, vertical) + min(horizontal, vertical) / 2
        case .roadBike, .gravel:
            return horizontal + ascent / 700 * 3600
        case .mtb:
            return horizontal + ascent / 500 * 3600
        case .car:
            return horizontal
        }
    }

    // MARK: - Formatage

    public static func formatDistance(_ m: Double) -> String {
        if m < 1000 { return String(format: "%.0f m", m) }
        if m < 10_000 { return String(format: "%.2f km", m / 1000).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",")
    }

    public static func formatElevation(_ m: Double) -> String {
        String(format: "%.0f m", m)
    }

    public static func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h == 0 { return "\(m) min" }
        return String(format: "%d h %02d", h, m)
    }
}
