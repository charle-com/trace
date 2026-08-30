import SwiftUI

struct SettingsView: View {
    @AppStorage("ignKey") private var ignKey = ""
    @AppStorage("thunderforestKey") private var tfKey = ""
    @AppStorage("preferMarkedTrails") private var preferMarkedTrails = false
    @AppStorage("autosave") private var autosave = true
    @AppStorage("autosaveFolder") private var autosaveFolder = ""

    var body: some View {
        Form {
            Section("Enregistrement") {
                Toggle("Enregistrer automatiquement après chaque modification", isOn: $autosave)
                LabeledContent("Dossier des nouveaux tracés") {
                    HStack {
                        Text(autosaveFolder.isEmpty ? "~/Documents/Tracés" : autosaveFolder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choisir…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { autosaveFolder = u.path }
                        }
                        if !autosaveFolder.isEmpty { Button("Par défaut") { autosaveFolder = "" } }
                    }
                }
                Text("Un tracé sans titre est créé dans ce dossier dès le premier point ; ensuite chaque modification est réécrite dans son fichier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Itinéraires") {
                Toggle("Privilégier les sentiers balisés (GR, PR) en randonnée", isOn: $preferMarkedTrails)
                Text("Désactivé : le mode Randonnée cherche le chemin le plus court à pied (sentiers, chemins, petites routes). Activé : il suit les itinéraires balisés quitte à rallonger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cartes IGN") {
                TextField("Clé Géoplateforme (couches SCAN 25)", text: $ignKey)
                Text("Sans clé, seuls Plan IGN et photos aériennes (licence ouverte) sont proposés. Avec une clé, la Carte topo IGN (SCAN 25) et la TOP 25 apparaissent dans la barre latérale. Clé à obtenir sur cartes.gouv.fr (gratuite pour un usage professionnel ou associatif).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Thunderforest (optionnel)") {
                TextField("Clé API", text: $tfKey)
                Text("Débloque OpenCycleMap, Outdoors et Landscape en Retina. Clé gratuite (150 000 tuiles par mois) sur thunderforest.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cache") {
                Button("Vider le cache des tuiles") {
                    LayerTileOverlay.diskCache.removeAllCachedResponses()
                    Network.session.configuration.urlCache?.removeAllCachedResponses()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 10)
    }
}
