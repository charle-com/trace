import Foundation
import MapKit
import CoreLocation
import Combine

/// Réglages de la carte, persistés.
@MainActor
final class MapSettings: ObservableObject {
    @Published var baseLayerID: String { didSet { UserDefaults.standard.set(baseLayerID, forKey: "baseLayerID") } }
    @Published var overlayIDs: Set<String> { didSet { UserDefaults.standard.set(Array(overlayIDs), forKey: "overlayIDs") } }
    @Published var retina: Bool { didSet { UserDefaults.standard.set(retina, forKey: "retinaTiles") } }
    @Published var showKilometerMarkers: Bool { didSet { UserDefaults.standard.set(showKilometerMarkers, forKey: "kmMarkers") } }
    @Published var showAnchors: Bool = true

    init() {
        let d = UserDefaults.standard
        baseLayerID = d.string(forKey: "baseLayerID") ?? LayerCatalog.defaultBaseID
        overlayIDs = Set(d.stringArray(forKey: "overlayIDs") ?? [])
        retina = d.object(forKey: "retinaTiles") == nil ? true : d.bool(forKey: "retinaTiles")
        showKilometerMarkers = d.object(forKey: "kmMarkers") == nil ? true : d.bool(forKey: "kmMarkers")
    }

    var baseLayer: MapLayer { LayerCatalog.layer(id: baseLayerID) ?? LayerCatalog.base.first! }
    var overlays: [MapLayer] { LayerCatalog.overlays.filter { overlayIDs.contains($0.id) } }
}

/// Pont entre SwiftUI et la MKMapView (commandes impératives).
@MainActor
final class MapController: ObservableObject {
    weak var mapView: MKMapView?
    @Published var zoomLevel: Double = 0
    @Published var centerCoordinate = CLLocationCoordinate2D(latitude: 46.6, longitude: 2.3)
    /// Coordonnée sous la souris (affichée dans la barre d'état).
    @Published var mouseCoordinate: CLLocationCoordinate2D?
    /// Message d'erreur de localisation à afficher (autorisation refusée, service coupé…).
    @Published var locationError: String?
    @Published var isLocating = false

    private var locationManager: CLLocationManager?
    private var locationDelegate: LocationDelegate?
    private var wantsLocation = false

    func zoomToFit(_ coords: [CLLocationCoordinate2D], animated: Bool = true) {
        guard let map = mapView, !coords.isEmpty else { return }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0.1, height: 0.1))
        }
        let inset = NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60)
        map.setVisibleMapRect(rect, edgePadding: inset, animated: animated)
    }

    func center(on c: CLLocationCoordinate2D, zoom: Double? = nil, animated: Bool = true) {
        guard let map = mapView else { return }
        if let zoom {
            let span = Self.span(forZoom: zoom, latitude: c.latitude, viewWidth: map.bounds.width)
            map.setRegion(MKCoordinateRegion(center: c, span: span), animated: animated)
        } else {
            map.setCenter(c, animated: animated)
        }
    }

    func zoom(by factor: Double) {
        guard let map = mapView else { return }
        var r = map.region
        r.span.latitudeDelta = min(180, max(0.0005, r.span.latitudeDelta / factor))
        r.span.longitudeDelta = min(360, max(0.0005, r.span.longitudeDelta / factor))
        map.setRegion(r, animated: true)
    }

    /// « Ma position » : demande l'autorisation CoreLocation (MapKit seul ne la demande jamais sur macOS),
    /// puis centre la carte sur la première position reçue.
    func showUserLocation() {
        let lm = locationManager ?? CLLocationManager()
        locationManager = lm
        let d = locationDelegate ?? LocationDelegate(controller: self)
        locationDelegate = d
        lm.delegate = d
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        wantsLocation = true
        isLocating = true
        switch lm.authorizationStatus {
        case .notDetermined:
            lm.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isLocating = false
            locationError = "La localisation est refusée pour Tracé. Autorisez-la dans Réglages Système > Confidentialité et sécurité > Service de localisation, ou vérifiez que le service est activé."
        default:
            mapView?.showsUserLocation = true
            lm.startUpdatingLocation()
        }
    }

    /// Statut d'autorisation lisible (QA).
    var locationStatus: String {
        guard let lm = locationManager else { return "aucun gestionnaire" }
        switch lm.authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        default: return "autre"
        }
    }

    fileprivate func locationAuthorized() {
        guard wantsLocation, let lm = locationManager else { return }
        mapView?.showsUserLocation = true
        lm.startUpdatingLocation()
    }

    fileprivate func locationDenied() {
        guard wantsLocation else { return }
        wantsLocation = false
        isLocating = false
        locationError = "La localisation est refusée pour Tracé. Autorisez-la dans Réglages Système > Confidentialité et sécurité > Service de localisation."
    }

    fileprivate func locationReceived(_ loc: CLLocation) {
        guard wantsLocation else { return }
        wantsLocation = false
        isLocating = false
        locationManager?.stopUpdatingLocation()
        mapView?.showsUserLocation = true
        center(on: loc.coordinate, zoom: 14)
    }

    fileprivate func locationFailed(_ error: Error) {
        guard wantsLocation else { return }
        // kCLErrorLocationUnknown est transitoire avec startUpdatingLocation : on attend la suite.
        if let e = error as? CLError, e.code == .locationUnknown { return }
        wantsLocation = false
        isLocating = false
        locationManager?.stopUpdatingLocation()
        if let e = error as? CLError, e.code == .denied {
            locationDenied()
            wantsLocation = false
        } else {
            locationError = "Position introuvable pour l'instant (\(error.localizedDescription)). Sur un Mac sans Wi-Fi ni GPS, le service de localisation peut ne rien renvoyer."
        }
    }

    static func span(forZoom zoom: Double, latitude: Double, viewWidth: CGFloat) -> MKCoordinateSpan {

        let lonDelta = 360 / pow(2, zoom) * Double(viewWidth) / 256
        return MKCoordinateSpan(latitudeDelta: lonDelta * cos(latitude * .pi / 180), longitudeDelta: lonDelta)
    }

    static func zoomLevel(for map: MKMapView) -> Double {
        let lonDelta = map.region.span.longitudeDelta
        guard lonDelta > 0 else { return 0 }
        return log2(360 * Double(map.bounds.width) / (256 * lonDelta))
    }
}

/// Délégué CoreLocation (les rappels arrivent sur le thread principal).
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    weak var controller: MapController?
    init(controller: MapController) { self.controller = controller }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorized: self.controller?.locationAuthorized()
            case .denied, .restricted: self.controller?.locationDenied()
            default: break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.controller?.locationReceived(loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.controller?.locationFailed(error) }
    }
}
