#!/bin/zsh
# Sert la carte aux appareils du réseau (iPhone en USB via partage de connexion, ou même Wi-Fi).
cd "$(dirname "$0")"
PORT=${PORT:-8765}
pkill -f "http.server $PORT" 2>/dev/null
echo "Adresses à ouvrir dans Safari sur l'iPhone :"
for dev in $(networksetup -listallhardwareports | awk '/Device/{print $2}'); do
  ip=$(ipconfig getifaddr $dev 2>/dev/null) || continue
  nom=$(networksetup -listallhardwareports | grep -B1 "Device: $dev" | head -1 | sed 's/Hardware Port: //')
  echo "  http://$ip:$PORT/    ($nom)"
done
echo "  http://$(scutil --get LocalHostName).local:$PORT/    (nom du Mac, si le réseau le résout)"
echo
echo "Puis dans Safari : bouton Partager → « Sur l'écran d'accueil ». Ctrl-C pour arrêter."
exec .venv/bin/python -m http.server $PORT --directory output --bind ::
