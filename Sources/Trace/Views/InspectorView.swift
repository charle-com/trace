import SwiftUI
import TraceCore

struct InspectorView: View {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var ctx: SceneContext
    @ObservedObject var settings: MapSettings
    @AppStorage("hikingSpeed") private var hikingSpeed: Double = 4.5
    @AppStorage("bikeSpeed") private var bikeSpeed: Double = 24
    @AppStorage("mtbSpeed") private var mtbSpeed: Double = 14

    var body: some View {
        Form {
            Section("Tracé") {
                CommitTextField(title: "Nom", value: doc.project.name) { doc.rename($0) }
                CommitTextField(title: "Notes", value: doc.project.notes, axis: .vertical) { doc.setNotes($0) }
                    .lineLimit(2...5)
            }
            Section("Statistiques") {
                let s = doc.stats
                stat("Distance", Stats.formatDistance(s.distance), "point.topleft.down.to.point.bottomright.curvepath")
                if s.hasElevation {
                    stat("Dénivelé positif", "+ " + Stats.formatElevation(s.ascent), "arrow.up.right")
                    stat("Dénivelé négatif", "- " + Stats.formatElevation(s.descent), "arrow.down.right")
                    stat("Altitude min / max", "\(Stats.formatElevation(s.minElevation ?? 0)) / \(Stats.formatElevation(s.maxElevation ?? 0))", "mountain.2")
                }
                stat("Durée estimée", Stats.formatDuration(duration(s)), "clock")
                stat("Points", "\(s.pointCount)", "circle.grid.2x1")
                if !doc.project.anchors.isEmpty {
                    stat("Points d'ancrage", "\(doc.project.anchors.count)", "smallcircle.filled.circle")
                }
            }
            if !doc.project.legs.isEmpty {
                Section("Tronçons") {
                    ForEach(Array(doc.project.legs.enumerated()), id: \.element.id) { i, leg in
                        HStack {
                            Image(systemName: leg.profile.symbolName).foregroundStyle(Color(nsColor: leg.profile.color)).frame(width: 18)
                            Text("\(i + 1)").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing).monospacedDigit()
                            Text(Stats.formatDistance(leg.distance)).monospacedDigit()
                            Spacer()
                            if doc.pendingLegIDs.contains(leg.id) {
                                ProgressView().controlSize(.mini)
                            } else if leg.fallback {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).help("Itinéraire introuvable : ligne droite")
                            }
                            Menu {
                                ForEach(RoutingProfile.allCases) { p in
                                    Button { doc.setProfile(p, forLegAt: i) } label: {
                                        Label(p.title, systemImage: p.symbolName)
                                    }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 24)
                        }
                        .font(.callout)
                    }
                }
            }
            Section("Vitesses de référence") {
                LabeledContent("Marche") { speedField($hikingSpeed) }
                LabeledContent("Vélo route") { speedField($bikeSpeed) }
                LabeledContent("VTT") { speedField($mtbSpeed) }
            }
            Section("Affichage") {
                Toggle("Marqueurs kilométriques", isOn: $settings.showKilometerMarkers)
                Toggle("Points d'ancrage", isOn: $settings.showAnchors)
                Toggle("Tuiles nettes (Retina)", isOn: $settings.retina)
            }
            if !doc.project.importedTracks.isEmpty && doc.project.anchors.isEmpty {
                Section("Trace importée") {
                    Text("Cette trace vient d'un fichier. Rendez-la éditable pour la modifier par points d'ancrage.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Rendre éditable") { doc.makeImportedEditable() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func duration(_ s: TrackStats) -> TimeInterval {
        let p = doc.project.defaultProfile
        let speed: Double
        switch p {
        case .hiking, .shortest, .straight: speed = hikingSpeed
        case .roadBike, .gravel: speed = bikeSpeed
        case .mtb: speed = mtbSpeed
        case .car: speed = p.defaultSpeedKmh
        }
        return Stats.estimatedDuration(distance: s.distance, ascent: s.ascent, descent: s.descent, profile: p, flatSpeedKmh: speed)
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().fontWeight(.medium)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func speedField(_ v: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: v, format: .number.precision(.fractionLength(1)))
                .frame(width: 48).multilineTextAlignment(.trailing)
            Text("km/h").foregroundStyle(.secondary)
        }
    }
}
