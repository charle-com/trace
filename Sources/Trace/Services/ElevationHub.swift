import Foundation
import TraceCore

/// Altimétrie : IGN Géoplateforme (RGE ALTI 1 m) en principal, Valhalla /height en repli, Open-Meteo en dernier.
/// Vérifié le 30/08/2026 : IGN = POST JSON uniquement, `zonly` en chaîne, 5 000 points max, nodata -99999, 5 req/s.
final class ElevationHub: ElevationService, @unchecked Sendable {
    private let cache = Cache<String, Double>(limit: 200_000)
    /// Une seule requête IGN à la fois (rate limit).
    private let gate = AsyncGate()

    func elevations(for points: [TrackPoint]) async throws -> [Double] {
        guard !points.isEmpty else { return [] }
        var result = [Double?](repeating: nil, count: points.count)
        var missing: [Int] = []
        for (i, p) in points.enumerated() {
            if let v = cache[Self.key(p)] { result[i] = v } else { missing.append(i) }
        }
        if !missing.isEmpty {
            let pts = missing.map { points[$0] }
            let values = try await fetch(pts)
            for (j, i) in missing.enumerated() {
                result[i] = values[j]
                cache[Self.key(points[i])] = values[j]
            }
        }
        return result.map { $0 ?? 0 }
    }

    private func fetch(_ pts: [TrackPoint]) async throws -> [Double] {
        var lastError: Error = ServiceError.badResponse("altimétrie indisponible")
        do {
            let v = try await ign(pts)
            let nodata = v.filter { $0 <= -9999 }.count
            if Double(nodata) / Double(v.count) <= 0.10 { return Self.interpolateNodata(v) }
            // Trop de points hors France : repli mondial.
        } catch { lastError = error }
        do { return Self.interpolateNodata(try await valhalla(pts)) } catch { lastError = error }
        do { return Self.interpolateNodata(try await openMeteo(pts)) } catch { lastError = error }
        throw lastError
    }

    // MARK: - IGN

    private func ign(_ pts: [TrackPoint]) async throws -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(pts.count)
        for chunk in pts.chunked(5000) {
            let body: [String: Any] = [
                "lon": chunk.map { RoutingHub.f($0.lon) }.joined(separator: "|"),
                "lat": chunk.map { RoutingHub.f($0.lat) }.joined(separator: "|"),
                "zonly": "true",
                "resource": "ign_rge_alti_wld",
                "delimiter": "|",
            ]
            let url = URL(string: "https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json")!
            let data: Data = try await gate.run {
                var attempt = 0
                while true {
                    do {
                        return try await Network.postJSON(url, body: body)
                    } catch ServiceError.http(429, _) where attempt < 2 {
                        attempt += 1
                        try await Task.sleep(nanoseconds: 1_100_000_000)
                    }
                }
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eles = json["elevations"] as? [Double], eles.count == chunk.count else {
                throw ServiceError.badResponse("réponse IGN inattendue")
            }
            out.append(contentsOf: eles)
        }
        return out
    }

    // MARK: - Valhalla

    private func valhalla(_ pts: [TrackPoint]) async throws -> [Double] {
        let url = URL(string: "https://valhalla1.openstreetmap.de/height")!
        let body: [String: Any] = ["shape": pts.map { ["lat": $0.lat, "lon": $0.lon] }, "height_precision": 2]
        let data = try await Network.postJSON(url, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = json["height"] as? [Any], h.count == pts.count else {
            throw ServiceError.badResponse("réponse Valhalla inattendue")
        }
        return h.map { ($0 as? Double) ?? -99999 }
    }

    // MARK: - Open-Meteo

    private func openMeteo(_ pts: [TrackPoint]) async throws -> [Double] {
        var out: [Double] = []
        for chunk in pts.chunked(100) {
            let lat = chunk.map { RoutingHub.f($0.lat) }.joined(separator: ",")
            let lon = chunk.map { RoutingHub.f($0.lon) }.joined(separator: ",")
            let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(lat)&longitude=\(lon)")!
            let data = try await Network.get(url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let e = json["elevation"] as? [Double], e.count == chunk.count else {
                throw ServiceError.badResponse("réponse Open-Meteo inattendue")
            }
            out.append(contentsOf: e)
        }
        return out
    }

    // MARK: - Utilitaires

    static func key(_ p: TrackPoint) -> String { String(format: "%.5f,%.5f", p.lat, p.lon) }

    /// Remplace les nodata par interpolation linéaire entre voisins valides.
    static func interpolateNodata(_ v: [Double]) -> [Double] {
        var out = v
        let valid = out.indices.filter { out[$0] > -9999 }
        guard !valid.isEmpty else { return out.map { _ in 0 } }
        var prev: Int? = nil
        var nextIdx = 0
        for i in out.indices {
            if out[i] > -9999 { prev = i; continue }
            while nextIdx < valid.count && valid[nextIdx] < i { nextIdx += 1 }
            let next = nextIdx < valid.count ? valid[nextIdx] : nil
            switch (prev, next) {
            case let (p?, n?): out[i] = out[p] + (out[n] - out[p]) * Double(i - p) / Double(n - p)
            case let (p?, nil): out[i] = out[p]
            case let (nil, n?): out[i] = out[n]
            default: out[i] = 0
            }
        }
        return out
    }
}

/// Sérialise des opérations asynchrones (une à la fois).
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ op: () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if let w = waiters.first { waiters.removeFirst(); w.resume() } else { busy = false }
        }
        return try await op()
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
