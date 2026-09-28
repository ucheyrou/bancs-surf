# App Surf — Bancs de sable landais

App perso (Ulysse et ses potes) pour savoir **où surfer entre Les Casernes (Seignosse) et
La Savane (Capbreton)**. Elle combine trois choses :

1. **les bancs de sable vus par Sentinel-2** (où ça casse, et comment ça bouge) ;
2. **les prévisions** houle / vent / marée (Open-Meteo) ;
3. **la physique du Gouf de Capbreton** (réfraction par tracé de rayons, profil d'approche de La Nord).

Le résultat est une **note sur 10 et un indice tube par spot et par heure**, sur 7 jours.

Ulysse fixe la vision produit et fournit la vérité terrain. Claude écrit tout le code.
Ulysse écrit en français : on répond en français, et le code, l'UI et les commentaires
restent en français.
Le [README.md](README.md) contient le détail (algorithmes, calibrations, résultats du Gouf,
formule de la note). Ce fichier-ci résume et fixe les règles de travail.

## Architecture

```
config/zone.yaml ──► sandbanks/ (pipeline Python) ──► output/  ──┬─► output/index.html  (PWA Leaflet, servie par serve.sh)
                         │                          *.json/*.png └─► ios/ (app SwiftUI) via ios/sync_data.sh → ios/Data
   Sentinel-2 (STAC AWS) ┤  Open-Meteo  ┤  EMODnet (data/)
```

| Module | Rôle |
|---|---|
| `sandbanks/stac.py`, `scene.py` | recherche + lecture fenêtrée des COG Sentinel-2, cache `cache/scenes/` |
| `sandbanks/analyse.py` | écume (visible + ratio SWIR), nuages, zone de surf, composite pondéré par la récence |
| `sandbanks/meteo.py` | Open-Meteo (houle, vent, niveau de mer), coefficients, conditions au passage |
| `sandbanks/gouf.py` | tracé de rayons, Kr réel / sans canyon → `data/gouf_Kr.npz`, `output/gouf/` |
| `sandbanks/scoring.py` | H_b (Kr × protection × shoaling), Iribarren, facteurs → note + indice tube |
| `sandbanks/rendu.py` | GeoTIFF, PNG WGS84, planches par spot, **génère `output/index.html`** (template dans `viewer_html`) |
| `sandbanks/cli.py` | commandes `scenes`, `update`, `score`, `gouf` |
| `ios/BancsSurf/` | `DataStore` (serveur → cache → bundle), `Models` (Codable), `Views/` (un fichier par écran) |

**Contrat de données** : l'interface entre le pipeline et les deux frontends, ce sont les
fichiers de `output/` (`scoring.json`, `previsions.json`, `spots.json`, `scenes.json`,
`meta.json`, `gouf/gouf_spots.json` et les PNG).

## Commandes

```zsh
./update.sh                                   # tout : scènes, composite, prévisions, notes, viewer, sync iOS
.venv/bin/python -m sandbanks score           # prévisions + notes seules (~5 s) — le test rapide
.venv/bin/python -m sandbanks gouf --rendu-seul   # figures Gouf depuis le npz (le calcul complet prend ~4 min)
./serve.sh                                    # sert output/ sur :8765 (dual-stack --bind ::)
ios/build_sim.sh                              # sync données + xcodegen + build + lance sur iPhone 17 Pro
.venv/bin/python tools/shot_iphone.py "index.html?spot=la_nord"   # capture du viewer web → captures/
SIMCTL_CHILD_ONGLET=2 SIMCTL_CHILD_SPOT=la_nord xcrun simctl launch <udid> fr.ulysse.BancsSurf
xcrun simctl io <udid> screenshot captures/xxx.png
```

Python 3.12 dans `.venv` (lien vers `venv.nosync/`) : numpy, scipy, rasterio, pyproj, shapely,
pystac-client, matplotlib, requests, pyyaml. L'app iOS cible iOS 17+, est générée par
XcodeGen (`ios/project.yml`) et n'a aucune dépendance externe.

## État (23/09/2026)

Déjà livré : le pipeline satellite, les prévisions, le modèle du Gouf, la notation, le viewer
web (PWA) et l'app iOS native à 5 onglets (Carte, Où aller, La Nord, Prévisions, Webcams/Spots/Scènes).
Côté carte : animation houle/vent en particules, et vue « banc + houle » pour chaque spot.

Pistes suivantes, par ordre de valeur :
- **calibrer `zone.yaml` avec les retours terrain** ;
- vérifier la position de `la_nord` (probablement ~300 m trop au sud, lat ≈ 43,670), **à
  confirmer avec Ulysse** ;
- brancher la bouée CANDHIS Anglet pour corriger le biais de houle ;
- normaliser les composites par la marée ;
- héberger les données pour ne plus dépendre du Mac.

## Règles pour une app propre et agréable

### Principes
- **La physique d'abord, et la vérifier.** Chaque constante vient d'une source (théorie,
  mesure Sentinel-2, SHOM, terrain) nommée dans un commentaire. On n'invente pas de coefficient
  « qui donne un joli résultat ». Toute nouvelle règle se vérifie sur au moins une scène réelle
  ou un cas de contrôle (voir « Contrôle » dans le README).
- **On calibre dans la config, pas dans le code.** Les paramètres par spot et les seuils vont
  dans `config/zone.yaml`. Quand Ulysse rapporte une session (« 2 m et mou à Penon »), on
  ajuste le YAML, pas `scoring.py`.
- **Toujours expliquer la note.** Chaque note affiche son facteur limitant (« vent onshore »,
  « ferme »…). Un nouveau facteur doit produire sa propre explication.
- **Hors ligne d'abord.** L'app iOS doit rester utilisable sans serveur (cache puis bundle).
  Une panne réseau dans le pipeline (Open-Meteo, SHOM) se signale mais ne fait pas planter le
  pipeline. Le SHOM reste optionnel.
- **Le plus simple possible.** Pas de nouvelle dépendance, de nouvelle couche ou de
  refactor sans bénéfice concret. On garde le style existant : fonctions courtes, noms
  français, unités dans les noms (`_m`, `_s`, `_kmh`, `_deg`, `pos_maree` 0 = BM → 1 = PM).

### Python (`sandbanks/`)
- Écrire des fonctions pures et vectorisées avec numpy, avec des annotations de type. Les
  I/O restent dans `cli.py` et `rendu.py`.
- Les rasters restent sur la grille UTM 30N native (EPSG:32630), sans rééchantillonnage.
  On ne reprojette en WGS84 que pour l'affichage.
- Chaque fonction ou module non trivial commence par une docstring d'une ou deux lignes qui
  dit *pourquoi*.
- On ne modifie jamais `output/`, `ios/Data/` ni `output/index.html` à la main : ce sont des
  fichiers générés. Pour le viewer web, on modifie `rendu.viewer_html`.

### Contrat JSON (pipeline ↔ web ↔ iOS)
- Pour ajouter ou renommer un champ, il faut mettre à jour, dans le même changement :
  le producteur (`cli.py`/`scoring.py`), le viewer (`rendu.viewer_html`) et `Models.swift`.
- Côté Swift, un champ nouveau ou qui peut manquer est optionnel : un vieux JSON en cache ou
  embarqué ne doit jamais casser le décodage.
- Ensuite, relancer `ios/sync_data.sh` (déjà appelé par `update.sh` et `build_sim.sh`).

### SwiftUI (`ios/`)
- Un écran par fichier dans `Views/`. Au-delà d'environ 250 lignes, on extrait des
  sous-vues. La logique de données va dans `DataStore` ou `Models`, pas dans les vues.
- **Design system unique** : fond `Color.fond`, cartes `Color.panneau`, accent `Color.accent`,
  texte secondaire `Color.sourdine`, notes `Color.note(_:)` (vert ≥ 7, jaune ≥ 4, rouge), houle
  `Color.houle`, vent `Color.vent(qualité)`, marée `Color.maree`. Tout est défini dans `Theme.swift`,
  avec les composants `Fleche` (houle) et `PastilleVent`. On n'écrit pas de `Color(red:…)` dans les vues, et une
  nouvelle couleur devient un token.
- Les nombres, directions et dates passent par les helpers `Fmt` (`Fmt.n`, `Fmt.rose`…).
- L'app reste en mode sombre uniquement, en portrait sur iPhone.
- iOS n'affiche que **5 onglets au maximum** : pour un nouvel écran, on regroupe (comme
  Spots/Scènes) plutôt que d'en ajouter un.
- La hiérarchie est claire : un écran répond à une question (« où aller ? », « et La Nord ? »).
  La réponse vient en haut, le détail en dessous.
- **Animation** : sur la carte générale, des particules à traînée (comètes) qui suivent les
  rayons de houle, jamais de longues barres. **Sur la vue d'un spot, des lignes de crête** (choix
  d'Ulysse, 23/09/2026) : on voit quelle partie de la vague touche le banc en premier. Elles vont
  à la célérité réelle ×4 et sont espacées d'une vraie longueur d'onde. L'ombre portée est effilée comme la traînée. Le nord reste en
  haut (rotation de la carte bloquée). L'écume est découpée par `masque_mer.png`.

### Vérifier avant de dire « fini »
- Pour le pipeline : lancer la commande concernée et lire la sortie. Pour la notation, un
  `score` suffit ; comparer avec le cas de contrôle du README.
- Pour l'UI iOS : `ios/build_sim.sh` sans erreur, puis **une capture de l'écran touché**
  (crochets `ONGLET` / `SPOT`), à regarder réellement.
- Pour le web : `tools/shot_iphone.py` sur la page modifiée.
- Si une vérification n'a pas pu être faite, le dire clairement.
- Mettre le README à jour quand le comportement ou une commande change. Garder ce fichier
  court.

## Pièges connus

- **iCloud Drive** : le dossier est sur le Bureau synchronisé. Les fichiers déchargés
  (« dataless ») font « pendre » Python. Le venv et le cache vivent dans `*.nosync` : ne
  jamais les renommer ni recréer le venv ailleurs. Diagnostic : `find . -flags +dataless`.
  Réparation : `find sandbanks config data -type f -exec cat {} + > /dev/null`.
- iCloud crée parfois des doublons « `fichier 2` » (conflits de synchro) : ne pas les utiliser,
  proposer de les supprimer.
- Le disque est presque plein (~9 Go libres) : pas de gros téléchargements (runtimes Xcode,
  historique Sentinel long) sans demander.
- Chrome headless impose une fenêtre d'au moins 500 px : pour une capture web type iPhone,
  passer par `tools/shot_iphone.py`.
- Le simulateur résout `localhost` en IPv6 : le serveur doit écouter en `--bind ::`.
- Signer l'app pour l'iPhone réel se fait dans Xcode (choix de l'équipe), c'est à Ulysse de
  le faire.
- La théorie des rayons exagère les ombres du Gouf : garder `kr_plancher` à 0,4. Sous 10 m de
  fond, EMODnet ne vaut rien et c'est le satellite qui fait foi.

## Dette connue (à traiter quand on touche la zone)

- Pas de tests. Des tests unitaires sur `scoring.py`
  (fonctions pures, cas de contrôle du README) seraient les plus rentables.
- Le viewer web est un template HTML d'environ 300 lignes dans une chaîne de `rendu.py`.
  Le sortir dans un fichier dès qu'on le modifie sérieusement.
- `LaNordView` calcule encore la palette de la matrice Kr avec des `Color(red:…)` : à passer en token.
- `captures/` sert de brouillon de captures. On peut le vider.
