import SwiftUI
import UniformTypeIdentifiers
import TraceCore

/// Feuille d'export GPX « propre » (sans le projet embarqué), pensée pour l'Apple Watch et les apps tierces.
struct ExportSheet: View {
    @ObservedObject var doc: TraceDocument
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportSimplify") private var simplify: Double = 2
    @AppStorage("exportWaypoints") private var includeWaypoints = true
    @AppStorage("exportElevation") private var includeElevation = true
    @AppStorage("exportAsRoute") private var asRoute = false
    @State private var exporting = false
    @State private var payload: GPXExportDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exporter en GPX").font(.title3).bold()
            Form {
                Toggle("Inclure les altitudes", isOn: $includeElevation)
                Toggle("Inclure les points d'intérêt", isOn: $includeWaypoints)
                Toggle("Exporter en route (rtept) plutôt qu'en trace", isOn: $asRoute)
                LabeledContent("Simplification") {
                    HStack {
                        Slider(value: $simplify, in: 0...20, step: 1).frame(width: 140)
                        Text(simplify == 0 ? "aucune" : String(format: "%.0f m", simplify)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                let count = previewCount
                Text("\(count) points, \(Stats.formatDistance(doc.stats.distance))").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 210)
            Text("Sur l'Apple Watch : envoyez le fichier vers l'iPhone (AirDrop ou iCloud Drive), puis ouvrez-le dans votre app d'entraînement (WorkOutDoors, Komoot, Strava…).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Exporter…") {
                    payload = GPXExportDocument(data: doc.exportGPX(options: options))
                    exporting = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileExporter(isPresented: $exporting, document: payload, contentType: .gpx, defaultFilename: doc.project.name.isEmpty ? "Tracé" : doc.project.name) { _ in
            dismiss()
        }
    }

    private var options: GPXWriteOptions {
        GPXWriteOptions(includeElevation: includeElevation, includeWaypoints: includeWaypoints, simplifyTolerance: simplify, embedProject: false, asRoute: asRoute)
    }

    private var previewCount: Int {
        let pts = doc.trackPoints
        return simplify > 0 ? Geo.simplify(pts, tolerance: simplify).count : pts.count
    }
}

struct GPXExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gpx] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
