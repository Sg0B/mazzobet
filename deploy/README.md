# Messa online di MazzoBet sul VPS

**Come è fatto il VPS** (dai tuoi appunti): Hostinger `srv1255004` (72.62.181.36), Caddy dentro Docker (contenitore `n8n-caddy-1`, Caddyfile in `/home/lemon/n8n/Caddyfile`), dominio `sourlemon.cloud`. Gli altri giochi sono pagine statiche in `/home/lemon/<nome>`. MazzoBet è diverso: ha un **server Node** (le regole e il Banco), quindi gira in un **suo contenitore Docker** e Caddy gli fa da porta d'ingresso su `mazzobet.sourlemon.cloud`. Non si toccano gli altri giochi.

> Non ho potuto collegarmi al VPS (serve la password o una chiave SSH). Questi passi si possono fare a mano oppure io li eseguo se aggiungiamo una chiave SSH.

## 1. Controlli prima di cominciare (solo lettura, non cambiano niente)

```bash
ssh root@72.62.181.36
docker ps                                   # il contenitore n8n-caddy-1 deve risultare attivo
docker inspect n8n-caddy-1 --format '{{json .NetworkSettings.Networks}}'   # nome della rete di Caddy
cat /home/lemon/n8n/Caddyfile               # per vedere come sono scritti gli altri giochi
nslookup mazzobet.sourlemon.cloud           # deve rispondere 72.62.181.36
```

Se il nome della rete **non** è `n8n_default`, correggilo in `deploy/docker-compose.yml` (riga `name:`).

## 2. Una sola volta

```bash
cd /home/lemon
git clone <indirizzo-del-repository> mazzobet      # oppure copia la cartella dal PC
cd mazzobet
nano .env                                          # vedi sotto
chmod 600 .env
docker compose -f deploy/docker-compose.yml up -d --build
```

Il file `.env` (si crea **solo sul VPS**, mai su GitHub, mai in chat):

```
SUPABASE_URL=https://fxnfaotahrlmmrundkib.supabase.co
SUPABASE_SERVICE_ROLE_KEY=incolla-qui-la-chiave-SEGRETA
PORT=3000
```

Attenzione: la chiave «publishable» (`sb_publishable_…`) dei tuoi appunti **non basta**: il server usa la chiave segreta `service_role`, la stessa che hai messo in `server/.env` sul PC.

## 3. Collegare il dominio (Caddy)

```bash
cd /home/lemon/n8n
cp Caddyfile Caddyfile.bak                         # copia di sicurezza
cat /home/lemon/mazzobet/deploy/Caddyfile.mazzobet >> Caddyfile
docker exec n8n-caddy-1 caddy validate --config /etc/caddy/Caddyfile   # deve dire «Valid configuration»
docker exec n8n-caddy-1 caddy reload   --config /etc/caddy/Caddyfile
```

(Se il percorso del Caddyfile dentro il contenitore è diverso, lo trovi nel `docker-compose.yml` di Caddy.)

## 4. Prova

```bash
curl https://mazzobet.sourlemon.cloud/api/health      # risposta: {"ok":true}
```

Poi apri `https://mazzobet.sourlemon.cloud` dal telefono.

## 5. Aggiornamenti futuri

Dopo ogni modifica spinta su GitHub:

```bash
cd /home/lemon/mazzobet && sh deploy/aggiorna.sh
```

## Cose da sapere

- **Database:** oggi MazzoBet usa il progetto Supabase `giochi_ufficio`, lo stesso degli altri giochi (schema separato `mazzobet`, non tocca le loro tabelle). Il PRD chiede test e produzione separati: valuta un progetto a parte prima della serata vera.
- **Serata:** prima di giocare, nell'editor SQL di Supabase, apri la serata con `server/db/ops/05_nuova_serata.sql` (la fine serata è alle 03:00 di Roma).
- **Log:** `docker logs --tail 100 mazzobet`.
- **Sicurezza:** la chiave `service_role` sta solo nel `.env` del VPS. Se mai venisse mostrata in chiaro, va rigenerata da Supabase.
- Il contenitore non è stato ancora costruito in prova su questo PC (Docker non installato): la prima costruzione sul VPS può richiedere qualche minuto.
