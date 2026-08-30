import Foundation
import TraceCore

/// Moteur de calcul d'itinéraire entre deux points.
protocol RoutingService: Sendable {
    /// Retourne la polyligne (altitude incluse si le moteur la fournit). Lève en cas d'échec.
    func route(from: TrackPoint, to: TrackPoint, profile: RoutingProfile) async throws -> [TrackPoint]
}

/// Service d'altitude.
protocol ElevationService: Sendable {
    /// Retourne une altitude par point, dans le même ordre. Lève en cas d'échec.
    func elevations(for points: [TrackPoint]) async throws -> [Double]
}

enum ServiceError: Error, LocalizedError {
    case http(Int, String)
    case badResponse(String)
    case noRoute
    case cancelled

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Le serveur a répondu \(code)\(body.isEmpty ? "" : " : \(body.prefix(160))")"
        case .badResponse(let m): return "Réponse inattendue : \(m)"
        case .noRoute: return "Aucun itinéraire trouvé entre ces deux points."
        case .cancelled: return "Calcul annulé."
        }
    }
}

enum Network {
    static let userAgent = "Trace/1.0 (macOS; https://charlesneveu.fr; contact charlesneveu35@gmail.com)"

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "fr-FR,fr;q=0.9"]
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30, directory: cacheDirectory.appendingPathComponent("http"))
        return URLSession(configuration: cfg)
    }()

    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("fr.charlesneveu.trace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func data(for request: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError.badResponse("pas de réponse HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    static func get(_ url: URL) async throws -> Data {
        try await data(for: URLRequest(url: url))
    }

    static func postJSON(_ url: URL, body: Any) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await data(for: req)
    }
}
