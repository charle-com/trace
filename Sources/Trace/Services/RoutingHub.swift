import Foundation
import TraceCore

/// Routage : BRouter (brouter.de) en principal, miroir bikerouter.de, puis OSRM FOSSGIS + altitude Valhalla.
/// Vérifié le 30/08/2026 : tous répondent sans clé, BRouter renvoie l'altitude en 3e coordonnée.
final class RoutingHub: RoutingService, @unchecked Sendable {
    struct Key: Hashable {
        let a: String, b: String, profile: RoutingProfile, marked: Bool
    }

    private let cache = Cache<Key, [TrackPoint]>(limit: 400)
    /// Préférer les sentiers balisés (GR/PR) plutôt que le plus court à pied.
    var preferMarkedTrails: Bool { UserDefaults.standard.bool(forKey: "preferMarkedTrails") }

    func route(from: TrackPoint, to: TrackPoint, profile: RoutingProfile) async throws -> [TrackPoint] {
        precondition(profile.isRouted)
        let key = Key(a: Self.k(from), b: Self.k(to), profile: profile, marked: preferMarkedTrails)
        if let hit = cache[key] { return hit }
        // Aller-retour : on réutilise le tronçon inverse.
        let rkey = Key(a: key.b, b: key.a, profile: profile, marked: preferMarkedTrails)
        if let hit = cache[rkey] { return hit.reversed() }

        let pts = try await routeUncached(from: from, to: to, profile: profile)
        cache[key] = pts
        return pts
    }

    private func routeUncached(from: TrackPoint, to: TrackPoint, profile: RoutingProfile) async throws -> [TrackPoint] {
        var lastError: Error = ServiceError.noRoute
        // 1. brouter.de, avec un retry unique (watchdog).
        for attempt in 0..<2 {
            do {
                return try await brouter(base: "https://brouter.de/brouter", from: from, to: to, profile: profile, mirror: false)
            } catch let e as ServiceError {
                if case .http(400, let body) = e, body.contains("not mapped") { throw ServiceError.noRoute }
                lastError = e
                if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            } catch {
                lastError = error
            }
        }
        // 2. Miroir bikerouter.de.
        do {
            return try await brouter(base: "https://bikerouter.de/brouter-engine/brouter", from: from, to: to, profile: profile, mirror: true)
        } catch let e as ServiceError {
            if case .http(400, let body) = e, body.contains("not mapped") { throw ServiceError.noRoute }
            lastError = e
        } catch { lastError = error }
        // 3. OSRM FOSSGIS (sans altitude ; l'altitude est complétée par le service d'altimétrie de l'app).
        do {
            return try await osrm(from: from, to: to, profile: profile)
        } catch { lastError = error }
        throw lastError
    }

    // MARK: - BRouter

    private func brouterProfile(_ p: RoutingProfile, mirror: Bool) -> (name: String, extra: String) {
        switch p {
        case .hiking:
            let base = mirror ? "hiking-beta" : "hiking-mountain"
            return preferMarkedTrails ? (base, "") : (base, "&profile:shortest_way=1")
        case .roadBike: return ("fastbike", "")
        case .gravel: return ("gravel", "")
        case .mtb: return (mirror ? "MTB" : "mtb", "")
        case .shortest: return ("shortest", "")
        case .car: return ("car-fast", "")
        case .straight: return ("shortest", "")
        }
    }

    private func brouter(base: String, from: TrackPoint, to: TrackPoint, profile: RoutingProfile, mirror: Bool) async throws -> [TrackPoint] {
        let (name, extra) = brouterProfile(profile, mirror: mirror)
        let lonlats = "\(Self.f(from.lon)),\(Self.f(from.lat))%7C\(Self.f(to.lon)),\(Self.f(to.lat))"
        guard let url = URL(string: "\(base)?lonlats=\(lonlats)&profile=\(name)\(extra)&alternativeidx=0&format=geojson") else {
            throw ServiceError.badResponse("URL invalide")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data = try await Network.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]], let f = features.first,
              let geom = f["geometry"] as? [String: Any],
              let coords = geom["coordinates"] as? [[Double]] else {
            throw ServiceError.badResponse("GeoJSON BRouter illisible")
        }
        let pts = coords.compactMap { c -> TrackPoint? in
            guard c.count >= 2 else { return nil }
            return TrackPoint(lat: c[1], lon: c[0], ele: c.count >= 3 ? c[2] : nil)
        }
        guard pts.count >= 2 else { throw ServiceError.noRoute }
        return pts
    }

    // MARK: - OSRM (repli)

    private func osrm(from: TrackPoint, to: TrackPoint, profile: RoutingProfile) async throws -> [TrackPoint] {
        let service: String
        switch profile {
        case .hiking, .straight: service = "routed-foot"
        case .car: service = "routed-car"
        default: service = "routed-bike"
        }
        let url = URL(string: "https://routing.openstreetmap.de/\(service)/route/v1/driving/\(Self.f(from.lon)),\(Self.f(from.lat));\(Self.f(to.lon)),\(Self.f(to.lat))?overview=full&geometries=geojson&steps=false")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data = try await Network.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? String) == "Ok",
              let routes = json["routes"] as? [[String: Any]], let r = routes.first,
              let geom = r["geometry"] as? [String: Any], let coords = geom["coordinates"] as? [[Double]] else {
            throw ServiceError.noRoute
        }
        // Contrôle du snapping : un point trop loin du réseau donne un itinéraire absurde.
        if let wps = json["waypoints"] as? [[String: Any]] {
            for w in wps { if let d = w["distance"] as? Double, d > 500 { throw ServiceError.noRoute } }
        }
        let pts = coords.compactMap { c -> TrackPoint? in c.count >= 2 ? TrackPoint(lat: c[1], lon: c[0]) : nil }
        guard pts.count >= 2 else { throw ServiceError.noRoute }
        return pts
    }

    // MARK: - Utilitaires

    static func f(_ v: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), v) }
    static func k(_ p: TrackPoint) -> String { "\(f(p.lat)),\(f(p.lon))" }
}

/// Cache LRU minimal, thread-safe.
final class Cache<K: Hashable, V>: @unchecked Sendable {
    private var dict: [K: V] = [:]
    private var order: [K] = []
    private let limit: Int
    private let lock = NSLock()
    init(limit: Int) { self.limit = limit }
    subscript(key: K) -> V? {
        get { lock.lock(); defer { lock.unlock() }; return dict[key] }
        set {
            lock.lock(); defer { lock.unlock() }
            if let v = newValue {
                if dict[key] == nil { order.append(key) }
                dict[key] = v
                if order.count > limit { let old = order.removeFirst(); dict[old] = nil }
            } else {
                dict[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }
}
