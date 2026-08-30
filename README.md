# Tracé

Éditeur de traces GPX natif pour macOS (SwiftUI + MapKit), pensé pour préparer des sorties rando, vélo, VTT ou course et les envoyer sur l'Apple Watch. Remplace en local calculitineraires.fr et l'outil de tracé Visorando. Aucun compte, aucune clé obligatoire, aucun serveur à soi : routage BRouter, altitudes IGN, fonds IGN et OpenStreetMap.

![Tracé sur macOS](docs/screenshot.png)

## Installer

```bash
git clone https://github.com/charle-com/trace.git && cd trace
./build.sh --install     # exige Xcode ; produit /Applications/Tracé.app (signature ad hoc)
```

Au premier lancement, macOS peut demander de confirmer l'ouverture (app non notarisée) : clic droit sur l'app → Ouvrir.

## Ce que fait l'app

- **Tracer par points d'ancrage** : clic gauche = nouveau point, l'itinéraire entre deux points est calculé automatiquement (BRouter) selon le mode : Randonnée, Vélo route, Gravel, VTT, Au plus court, Voiture, Ligne droite.
- **Clic droit sur la carte** : « Tracer jusqu'ici (mode courant) », « au plus court », « en ligne droite », « en… » (autre mode), insertion d'un point sur le tracé, point d'intérêt, boucle, suppression du dernier point, centrage, copie des coordonnées.
- **Édition** : glisser une ancre recalcule les deux tronçons voisins ; clic sur la ligne insère une ancre ; ⌥-clic force la ligne droite ; ⌫ supprime le point sélectionné (sinon le dernier) ; ⌘Z / ⇧⌘Z annuler-rétablir nommés.
- **Fin de tracé** : Revenir au départ (⌘L), Aller-retour (⇧⌘L), Inverser (⌘I), Recalculer tout avec le mode courant (⇧⌘R), Tout effacer (⇧⌘⌫).
- **Fonds de carte** (barre latérale, ⌘1 à ⌘9) : Plan IGN v2, Photos aériennes IGN, OpenStreetMap, OpenTopoMap, CyclOSM, OSM France, Satellite Esri, Plans / Satellite / Hybride Apple. Avec une clé Géoplateforme saisie dans les Réglages : Carte topo IGN (SCAN 25) et TOP 25 touristique. Avec une clé Thunderforest : Outdoors, OpenCycleMap, Landscape (Retina natif).
- **Enregistrement automatique** : dès le premier point, un fichier est créé dans `~/Documents/Tracés/` (dossier modifiable) et réécrit à chaque modification ; un document déjà nommé est réenregistré en silence. Désactivable dans les Réglages.
- **Surcouches** : sentiers balisés (GR, PR), itinéraires vélo, itinéraires VTT (Waymarked Trails), courbes de niveau IGN, estompage LiDAR HD, pentes IGN, cadastre.
- **Tuiles nettes sur Retina** : assemblage 2x2 des tuiles du niveau supérieur (désactivable), cache disque de 2 Go.
- **Altitudes** : IGN RGE ALTI (précision métrique) avec repli Valhalla puis Open-Meteo, profil altimétrique synchronisé avec la carte (survol = point jaune sur le tracé), D+ / D- lissés (fenêtre 100 m, hystérésis 5 m), durée estimée (règle des randonneurs, vitesses réglables).
- **Fichiers** : le document est un GPX standard (`.gpx`). Le projet (ancres, modes) est embarqué dans `<metadata><extensions>` : rouvrable et éditable dans Tracé, lisible par n'importe quelle app. Autosave, versions, iCloud Drive.
- **Import** : ouvrir n'importe quel GPX (Garmin, Strava, Komoot…) ; « Rendre éditable » convertit la trace en ancres ; altitudes complétées si absentes.
- **Export** (⌘E) : GPX propre pour l'Apple Watch (trace ou route, altitudes, points d'intérêt, simplification Douglas-Peucker au choix) ; bouton Partager = AirDrop vers l'iPhone.
- **Recherche** : champ de recherche (lieu, adresse, ou « lat, lon »), Ma position (⌘⌥L), Ajuster au tracé (⌘⏎), marqueurs kilométriques (⌘K).

## Construire

```bash
./build.sh            # release, build/Tracé.app
./build.sh --debug    # debug
./build.sh --install  # copie dans /Applications
swift test            # tests du cœur (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)
```

Exige Xcode (toolchain) ; pas de projet Xcode, tout passe par SwiftPM. Signature ad hoc.

## QA automatisée

`./qa.sh <dossier> --scenario route|gestures|open [--open f.gpx] [--layer id] [--overlay a,b] [--profile raw]`
Lance l'app en mode `--qa`, déroule le scénario (clics, menus, drag, undo, export), capture la fenêtre (`window.png` si l'écran est déverrouillé, `window-cache.png` sinon) et écrit `result.json`, `export.gpx`, `work.gpx`.

## Sources de données (vérifiées le 30/08/2026)

| Usage | Service | Remarques |
|---|---|---|
| Routage | `brouter.de/brouter` (repli `bikerouter.de`, puis OSRM FOSSGIS) | sans clé, altitude incluse ; Randonnée = `hiking-mountain` + `profile:shortest_way=1` (le plus court à pied), option « sentiers balisés » dans les Réglages |
| Altitude | IGN Géoplateforme `altimetrie/1.0/calcul/alti/rest/elevation.json` | POST JSON, 5 000 points max, nodata `-99999` interpolé ; repli Valhalla `/height`, puis Open-Meteo |
| Fonds IGN | `data.geopf.fr/wmts` (ouvert) | Plan IGN v2, orthophotos, courbes, estompage, pentes, cadastre : Licence Ouverte |
| SCAN 25 | `data.geopf.fr/private/wmts?apikey=…` | uniquement avec une clé Géoplateforme saisie dans les Réglages (compte cartes.gouv.fr ; la licence IGN réserve le SCAN 25 aux usages professionnels ou associatifs, l'app n'embarque aucune clé) |
| OSM | tile.openstreetmap.org, OpenTopoMap (max z17), CyclOSM (max z17), OSM France | User-Agent identifiant obligatoire, pas de préchargement |
| Sentiers | tile.waymarkedtrails.org | overlays hiking / cycling / mtb |

## Licence

Code sous licence MIT. Les fonds de carte et services restent soumis à leurs propres conditions (IGN Géoplateforme, OpenStreetMap, OpenTopoMap, CyclOSM, Waymarked Trails, BRouter, FOSSGIS) : usage personnel modéré, pas de téléchargement massif.

## Structure

- `Sources/TraceCore` : géométrie (haversine, Douglas-Peucker, tuiles), lecture/écriture GPX, modèle de projet (ancres, tronçons, POI), statistiques et profil. Testé par `Tests/TraceCoreTests`.
- `Sources/Trace/Model` : document (`ReferenceFileDocument`, undo), protocoles de services.
- `Sources/Trace/Services` : `RoutingHub` (BRouter + replis + cache), `ElevationHub` (IGN + replis + cache).
- `Sources/Trace/Map` : `MapView` (MKMapView, gestes, menu contextuel, annotations, polylignes), `TileOverlay` (tuiles + assemblage Retina), `LayerCatalog`, `MapSettings`.
- `Sources/Trace/Views` : fenêtre (split view, inspecteur, barre d'outils), barre latérale, profil altimétrique, export, menus, réglages.
- `Sources/Trace/QARunner.swift` : mode `--qa`.
