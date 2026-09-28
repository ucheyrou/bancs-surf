#!/bin/zsh
# Met à jour la carte des bancs : nouvelles scènes Sentinel-2 -> composite -> output/index.html
cd "$(dirname "$0")"
.venv/bin/python -m sandbanks update "$@" 2>&1 | grep -v -i "warn"
# données embarquées dans l'app iOS (utilisées hors ligne / au premier lancement)
[[ -x ios/sync_data.sh ]] && ios/sync_data.sh >/dev/null && echo "Données iOS synchronisées (ios/Data)"
