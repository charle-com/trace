import SwiftUI
import AppKit
import TraceCore

/// Fenêtre de bienvenue : nouveau tracé nommé, ou réouverture d'une trace récente.
@MainActor
final class WelcomeController {
    static let shared = WelcomeController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = WelcomeModel()
        let host = NSHostingView(rootView: WelcomeView(model: model, close: { [weak self] in self?.close() }))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 500), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        w.title = "Bienvenue dans Tracé"
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.reload()
    }

    func close() {
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

struct RecentTrace: Identifiable, Hashable {
    let url: URL
    let name: String
    let modified: Date
    var distance: Double?
    var ascent: Double?
    var id: String { url.path }
}

@MainActor
final class WelcomeModel: ObservableObject {
    @Published var recents: [RecentTrace] = []
    @Published var name = ""
    @Published var profile: RoutingProfile = RoutingProfile(rawValue: UserDefaults.standard.string(forKey: "lastProfile") ?? "") ?? .hiking

    func reload() {
        var urls: [URL] = NSDocumentController.shared.recentDocumentURLs
        let folder = TraceDocument.autosaveFolder
        if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            urls += items.filter { $0.pathExtension.lowercased() == "gpx" }
        }
        var seen = Set<String>()
        var out: [RecentTrace] = []
        for u in urls {
            let path = u.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(RecentTrace(url: u, name: u.deletingPathExtension().lastPathComponent, modified: date))
        }
        out.sort { $0.modified > $1.modified }
        recents = Array(out.prefix(40))
        // Distance et D+ lus en arrière-plan.
        let snapshot = recents
        Task.detached(priority: .utility) {
            var stats: [String: (Double, Double)] = [:]
            for r in snapshot {
                if let f = try? GPXReader.read(url: r.url) {
                    let pts = f.allPoints
                    let s = Stats.compute(pts)
                    stats[r.id] = (s.distance, s.ascent)
                }
            }
            let result = stats
            await MainActor.run { [weak self] in
                guard let self else { return }
                for i in self.recents.indices {
                    if let s = result[self.recents[i].id] { self.recents[i].distance = s.0; self.recents[i].ascent = s.1 }
                }
            }
        }
    }

    func createNew() {
        let n = name.trimmingCharacters(in: .whitespaces)
        TraceDocument.pendingName = n.isEmpty ? nil : n
        TraceDocument.pendingProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "lastProfile")
        NSDocumentController.shared.newDocument(nil)
    }

    func open(_ r: RecentTrace) {
        NSDocumentController.shared.openDocument(withContentsOf: r.url, display: true) { _, _, error in
            if let error { NSLog("Tracé : ouverture impossible : \(error.localizedDescription)") }
        }
    }

    func openOther() {
        NSDocumentController.shared.openDocument(nil)
    }

    func remove(_ r: RecentTrace) {
        let a = NSAlert()
        a.messageText = "Mettre « \(r.name) » à la corbeille ?"
        a.informativeText = r.url.path
        a.addButton(withTitle: "Mettre à la corbeille")
        a.addButton(withTitle: "Annuler")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
        reload()
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let close: () -> Void
    @State private var selection: String?
    @AppStorage("showWelcome") private var showWelcome = true

    var body: some View {
        HStack(spacing: 0) {
            // Gauche : nouveau tracé
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tracé").font(.system(size: 30, weight: .bold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)
                Spacer().frame(height: 4)
                Text("Nouveau tracé").font(.headline)
                TextField("Nom du tracé", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { create() }
                Picker("Mode", selection: $model.profile) {
                    ForEach(RoutingProfile.allCases.filter { $0 != .straight }) { p in
                        Label(p.title, systemImage: p.symbolName).tag(p)
                    }
                }
                .labelsHidden()
                Button(action: create) {
                    Label("Créer et ouvrir la carte", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button {
                    model.openOther()
                    close()
                } label: {
                    Label("Ouvrir un fichier GPX…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Spacer()
                Toggle("Afficher cette fenêtre au lancement", isOn: $showWelcome)
                    .toggleStyle(.checkbox).font(.caption)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 28)
            .frame(width: 360)

            Divider()

            // Droite : traces récentes
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Traces récentes").font(.headline)
                    Spacer()
                    Text(TraceDocument.autosaveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 8)
                if model.recents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.title).foregroundStyle(.tertiary)
                        Text("Aucune trace récente").foregroundStyle(.secondary)
                        Text("Les tracés s'enregistrent automatiquement dans le dossier ci-dessus.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.recents, selection: $selection) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "map").foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(r.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                                    if let d = r.distance {
                                        Text("·")
                                        Text(Stats.formatDistance(d))
                                        if let a = r.ascent, a > 0 { Text("· D+ \(Stats.formatElevation(a))") }
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(r) }
                        .tag(r.id)
                        .contextMenu {
                            Button("Ouvrir") { open(r) }
                            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                            Divider()
                            Button("Mettre à la corbeille…", role: .destructive) { model.remove(r) }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
                HStack {
                    Spacer()
                    Button("Ouvrir") { if let s = selection, let r = model.recents.first(where: { $0.id == s }) { open(r) } }
                        .disabled(selection == nil)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 820, height: 500)
    }

    private func create() {
        model.createNew()
        close()
    }

    private func open(_ r: RecentTrace) {
        model.open(r)
        close()
    }
}
