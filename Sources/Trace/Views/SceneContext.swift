import SwiftUI
import MapKit
import TraceCore

/// Objets partagés d'une fenêtre (document, carte, réglages), exposés aux menus via FocusedValue.
@MainActor
final class SceneContext: ObservableObject {
    let doc: TraceDocument
    let settings = MapSettings()
    let controller = MapController()
    @Published var showInspector = true
    @Published var showProfile = true
    @Published var showExport = false
    @Published var searchText = ""

    init(doc: TraceDocument) { self.doc = doc }
}

struct SceneContextKey: FocusedValueKey { typealias Value = SceneContext }
extension FocusedValues {
    var scene: SceneContext? {
        get { self[SceneContextKey.self] }
        set { self[SceneContextKey.self] = newValue }
    }
}
