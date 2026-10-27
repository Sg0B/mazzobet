# MazzoBet sul VPS

**Stato (23 ottobre 2026): online su https://mazzobet.sourlemon.cloud**, ramo `regole-v06` del repository privato `Sg0B/mazzobet`.

## Come è fatto

- VPS Hostinger `srv1255004` (72.62.181.36). Caddy gira in Docker (`n8n-caddy-1`, file `/home/lemon/n8n/Caddyfile`); gli altri giochi sono pagine statiche o app già presenti, e non vengono toccati.
- MazzoBet è un **contenitore Docker** chiamato `mazzobet`, collegato alla rete `n8n_default` (la stessa di Caddy), **senza porte pubbliche**: Caddy lo raggiunge con `reverse_proxy mazzobet:3000`, mette l'HTTPS (certificato Let's Encrypt automatico) e comprime le risposte.
- Il codice sta in `/home/lemon/mazzobet`, clonato da GitHub con una **chiave di sola lettura** (`/root/.ssh/mazzobet_deploy`, registrata come «deploy key» del solo repository).
- La chiave segreta di Supabase è in `/home/lemon/mazzobet/.env` (permessi solo root, escluso da Git). Il database è il progetto `giochi_ufficio`, schema `mazzobet`.
- Il blocco di Caddy è in fondo al Caddyfile; c'è una copia di sicurezza accanto (`Caddyfile.bak-<data>`).

## Aggiornare dopo una modifica

Sul PC: commit e `git push`. Sul VPS:

```bash
cd /home/lemon/mazzobet && sh deploy/aggiorna.sh
```

Lo script scarica l'ultima versione, ricostruisce il contenitore, lo riavvia e controlla che risponda. Per cambiare ramo: `git checkout <ramo>` prima dello script.

## Controlli utili (sola lettura)

```bash
docker ps --filter name=mazzobet                 # stato e salute
docker logs --tail 100 mazzobet                  # ultimi log
curl https://mazzobet.sourlemon.cloud/api/health # risposta: {"ok":true}
```

## Cose da sapere

- **Serata:** prima di giocare apri la serata nell'editor SQL di Supabase con `server/db/ops/05_nuova_serata.sql` (la fine serata è alle 03:00 di Roma). Si chiude con `03_chiudi_serata.sql`.
- **Database:** è lo stesso progetto Supabase degli altri giochi (schema separato, non tocca le loro tabelle). Il PRD chiede test e produzione separati: valuta un progetto a parte.
- **Notifiche push:** nel `.env` del VPS stanno anche `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT=mailto:…` e `PUSH_ENABLED` (la chiave privata non va mai in chat né su GitHub). Come generarle e come spegnerle: `docs/notifiche.md`. Senza chiavi le notifiche restano spente.
- **Chiave segreta:** vive solo nel `.env` del VPS e in `server/.env` sul PC. Se mai venisse mostrata in chiaro, va rigenerata da Supabase.
- **Accesso SSH usato per la messa online:** chiave dedicata (commento `claude-mazzobet-20261023`) in `/root/.ssh/authorized_keys`. Si revoca cancellando quella riga.
- **DNS:** record A `mazzobet` → `72.62.181.36` nella zona di `sourlemon.cloud`. Alcuni provider (e le reti con filtri) impiegano un po' a vedere i nomi nuovi.
- **Ripristino di Caddy:** se un blocco rompe qualcosa, `cp /home/lemon/n8n/Caddyfile.bak-<data> /home/lemon/n8n/Caddyfile` e `docker exec n8n-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`.
- **Fermare MazzoBet** senza toccare altro: `cd /home/lemon/mazzobet && docker compose -f deploy/docker-compose.yml down`.
