#!/bin/sh
# Da lanciare SUL VPS, dentro la cartella di MazzoBet:  sh deploy/aggiorna.sh
# Scarica l'ultima versione, ricostruisce il contenitore e controlla che risponda.
set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Manca il file .env (vedi deploy/README.md)"; exit 1; }
git pull --ff-only
docker compose -f deploy/docker-compose.yml build
docker compose -f deploy/docker-compose.yml up -d
echo "Attendo l'avvio..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 3
  if docker exec mazzobet wget -qO- http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    echo "MazzoBet risponde. Aggiornamento riuscito."; exit 0
  fi
done
echo "MazzoBet non risponde: guarda i log con  docker logs --tail 50 mazzobet"; exit 1
