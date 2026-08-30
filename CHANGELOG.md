# Changelog

## 1.1.0 (2026-08-30)

- Fenêtre de bienvenue au lancement : nouveau tracé nommé avec son mode, traces récentes (nom, date, distance, D+), ouverture d'un fichier. ⇧⌘1 pour la rappeler.
- Enregistrement automatique après chaque modification : fichier créé dès le premier point dans `~/Documents/Tracés/` (dossier réglable), réécrit à chaque changement. Un GPX venu d'ailleurs n'est jamais réécrit : copie « nom (Tracé).gpx ».
- Changer le mode dans la barre d'outils (⌘⌥1 à ⌘⌥7) recalcule tous les tronçons du tracé, en une action annulable.
- Ma position : demande d'autorisation de localisation, suivi jusqu'au premier point, point bleu dessiné par l'app (celui de MapKit est masqué par les fonds IGN/OSM).
- Revue de code : annuler/rétablir fiables pendant un calcul en cours, altitudes manquantes interpolées puis réessayées, insertion d'un point sur une trace importée sans perte de géométrie, ⌫ agit sur la sélection, champs texte validés à la sortie, cache de tuiles revalidé et réponses non image rejetées, assemblage Retina en bitmap 512 px, raccourcis ⇧⌘E (export) et ⌘⌥⌫ (dernier point).
- Signature avec une identité stable (`setup-signing.sh`) pour conserver les autorisations d'une version à l'autre.
- Clé IGN partagée `ign_scan_ws` par défaut pour la Carte topo IGN, remplaçable dans les Réglages.

## 1.0.0 (2026-08-30)

- Première version : tracé par points d'ancrage avec routage BRouter (randonnée, vélo route, gravel, VTT, au plus court, voiture, ligne droite), clic droit « Tracer jusqu'ici », insertion sur la ligne, drag des ancres, boucle, aller-retour, inversion.
- Fonds Plan IGN v2, Carte topo IGN, TOP 25, photos aériennes IGN, OpenStreetMap, OpenTopoMap, CyclOSM, OSM France, Esri, Apple ; surcouches sentiers balisés, vélo, VTT, courbes de niveau, estompage, pentes, cadastre ; tuiles nettes sur Retina.
- Altitudes IGN RGE ALTI (replis Valhalla, Open-Meteo), profil altimétrique synchronisé, D+/D- lissés, durée estimée.
- Document GPX standard avec projet embarqué, import de tout GPX, export GPX pour l'Apple Watch, partage AirDrop.
