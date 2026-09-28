#!/bin/zsh
# Copie les données du pipeline dans le bundle de l'app (copie embarquée = fonctionne hors ligne au premier lancement).
cd "$(dirname "$0")"
rm -rf Data && mkdir -p Data/spots
cp ../output/gouf/gouf_spots.json Data/ 2>/dev/null
for f in scoring.json previsions.json spots.json scenes.json meta.json frequence.png haut_fond.png derniere_rgb.png masque_mer.png champ_banc.png; do cp "../output/$f" Data/ 2>/dev/null; done
cp ../output/spots/*.png Data/spots/
du -sh Data | cut -f1
