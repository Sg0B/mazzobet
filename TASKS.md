# MazzoBet — cose da fare e decisioni da prendere

**Aggiornato:** 26 ottobre 2026 · **Dove siamo:** online https://mazzobet.sourlemon.cloud (ramo Git `regole-v06`, repository privato `Sg0B/mazzobet`). Fatti: regole v0.6, aiuto MAX sulle quote, classifiche, **Banco di Regia** (`/regia`), colletta limitata al saldo, Banco con estrazione pesata, **schermo della sala** (`/tv`). Migration 001–014 applicate a `giochi_ufficio`. Il PRD è alla **v1.0** (`MazzoBet_PRD_v1.0.md`, Appendice F). Per ripartire leggi questo file, poi l'Appendice F del PRD, `docs/accesso-regia.md` e `docs/schermo-tv.md`.

## 0. Prossimi passi, in ordine

1. **Sul VPS:** aggiornare il codice (`sh deploy/aggiorna.sh`) e impostare `ADMIN_CODE` nel `.env` (almeno 12 caratteri, mai in chat), poi ricreare il contenitore. Comandi in `docs/accesso-regia.md`. *(La Regia è già stata provata dall'utente online; la `/tv` e la scheda «Schermo» arrivano con l'aggiornamento.)*
2. **Provare `/tv` su una TV vera** (leggibilità da lontano, dimensione del testo, browser della smart TV o HDMI).
3. **Nuova simulazione** (24 squadre, 60′ ×6): misurare le squadre mai colpite con l'estrazione pesata e decidere il **saldo iniziale** (oggi 1.000, ora parametro in Regia). Prima: `banco_inizio` nel passato, poi ripristinarlo (vedi guida Regia).
4. **PIN delle squadre** (prompt accesso §1): scritto e provato in locale (`server/db/015_pin.sql`, `server/tests/pglite/pin.mjs`). Migration 015 applicata a `giochi_ufficio` (26/10/2026). **Manca:** commit, deploy sul VPS e prova su telefoni veri.
5. **Notifiche push** (prompt notifiche): scritte e provate in locale (`server/db/016_push.sql`, `server/tests/pglite/push*.mjs`, guida `docs/notifiche.md`). Migration 016 applicata a `giochi_ufficio` (27/10/2026). **Manca:** generare le chiavi VAPID e metterle nel `.env` del VPS, deploy e prova su telefoni veri (schermo bloccato, tocco, iPhone dalla Home, Android).
6. **Prova generale con persone vere** (sezione 4) e unione di `regole-v06` a `main`.

## 1. Decisioni

Prese il 25/10/2026 (registro nel PRD v1.0, F.2):

- [x] **1.1** Controllo sul margine delle quote **tenuto**; sponsor del PRD v0.7 **tenuto**.
- [x] **1.2** Colletta limitata al saldo disponibile — **fatto** (migration 013).
- [x] **1.3** Banco ordinario con estrazione pesata — **fatto** (migration 013; corretto anche il difetto che pescava sempre le squadre con id basso).
- [x] **1.4** Database: resta il progetto Supabase `giochi_ufficio` (schema `mazzobet`, condiviso con altri giochi), **con backup prima della serata**.
- [x] **1.5** Merge di `regole-v06` su `main` solo a lavoro finito e provato.
- [x] **1.6** Rischi sociali accettati (esiti in malafede, doppio dispositivo, puntate su eventi già accaduti): da osservare nella prova generale.
- [x] **1.7** Dopo la chiusura serata non si rientra con «Cambia squadra».
- [ ] **1.8** Catalogo testi: verbi al singolare con 2–3 squadre («trova»); da correggere **a mano** in `catalogo_banco_v02_allineato_v07.json`.
- [ ] **1.9 Saldo iniziale:** resta 1.000; decidere dopo la nuova simulazione (parametro in Regia).
- [ ] **1.10 Chiave `service_role`:** non ruotata per scelta; rivalutare se il codice o i file circolano.

## 2. Messa online sul VPS — fatta il 23 ottobre 2026

Online su **https://mazzobet.sourlemon.cloud** (contenitore `mazzobet` dietro Caddy, HTTPS e compressione attivi). Dettagli e comandi in `deploy/README.md`. Aggiornamento: `cd /home/lemon/mazzobet && sh deploy/aggiorna.sh`; dopo una modifica al `.env`: `docker compose -f deploy/docker-compose.yml up -d --force-recreate`.

- [x] SSH con chiave dedicata, repository privato, chiave di deploy di sola lettura, cartella `/home/lemon/mazzobet`, `.env`, contenitore, DNS, blocco di Caddy.
- [x] Aggiornamenti del 25/10 (quote, classifiche) online.
- [ ] **Aggiornamento con Regia/colletta/TV** e `ADMIN_CODE` nel `.env` (vedi sezione 0).
- [ ] **Aprire la serata** il giorno stesso: oggi nel database c'è «Prova famiglia» (8 squadre di prova). Per ripartire pulito basta **Reset totale** dalla Regia (parola `RESET`); in alternativa `server/db/ops/05_nuova_serata.sql`.
- [ ] **Revocare la chiave SSH** di lavoro (riga `claude-mazzobet-20261023` in `/root/.ssh/authorized_keys`) quando non serve più.
- [ ] **Backup** del database prima della serata; nessun backup automatico né monitoraggio oggi.
- [ ] **Unire `regole-v06` a `main`** (e far puntare il VPS su `main`) dopo la prova generale.

## 3. Tecnico

- [ ] **Supabase Realtime** al posto del solo polling ogni 3 s (invariante 8 del PRD).
- [ ] **Prova del riavvio vero del server** durante un esito o un blocco di bancarotta (scenario 13 del prompt).
- [ ] Orari: la scadenza «Orario» usa l'ora del telefono nel form; il server valida (fine serata 03:00 Europe/Rome). Verificare ora legale (il 25/10/2026 si è tornati all'ora solare) e attraversamento della mezzanotte.
- [ ] Ripetere la simulazione con altri seed e per più tempo (almeno 30′ reali).
- [ ] Possibile pulizia: rimuovere `leaderboard` da `mb_get_state` (non più usato dopo le classifiche).
- [ ] Ambiente Docker locale per provare l'immagine prima del VPS (opzionale).

## 4. Prova generale con persone vere

- [ ] Telefoni veri, più dispositivi insieme: countdown, «TUTTI I CARLETTI», aiuto MAX sulle quote, schermata ESITA obbligatoria, «Esita per X Carletti», toast delle notizie, classifiche (`Rank`), pagina Regia da telefono.
- [ ] **Schermo `/tv`** su una TV vera: leggibilità, scene, eventi a tutto schermo, annuncio dalla Regia, QR.
- [ ] Casi che la simulazione non copre: scommessa che nessuno esita (annullamento a T+17′), tempi di reazione reali, invasività percepita del Banco.
- [ ] Prova di fine serata: pausa, chiusura, classifica finale, verifica conti (snippet in `server/db/ops/` o dalla Regia).
- [ ] Test con amici nei giorni prima (reset totali frequenti dalla Regia; il Banco resta spento fino a `banco_inizio`, usare «Avvia Banco adesso» per provarlo).

## 5. Fatto dal 25 al 26 ottobre 2026

- [x] Aiuto «MAX» sulle quote; classifiche (migration 012); saldo del Banco in RadioCorsa.
- [x] **Banco di Regia** (migration 011, `/regia`, guida `docs/accesso-regia.md`): codice `ADMIN_CODE`, reset squadra e totale, parametri, orario del Banco, esito/annulla/rettifica, log.
- [x] **Colletta e Banco pesato** (migration 013).
- [x] **Schermo della sala** (migration 014, `/tv`, guida `docs/schermo-tv.md`) con annuncio dalla Regia.
- [x] PRD v1.0 con Appendice F; test su Postgres in memoria in `server/tests/pglite/` (44 controlli Regia, 4 suite SQL, TV, confronto Banco).

## Come si lavora (promemoria)

- Avvio locale: `npm --prefix server run dev` (carica `server/.env` con la chiave **vera**: per prove usa un finto Supabase come in `server/tests/pglite/`) e `npm --prefix web run dev` (app su `http://localhost:5173`; `/regia` e `/tv` sono pagine dello stesso frontend).
- Prove senza toccare il database vero: `npm i --no-save @electric-sql/pglite`, poi `node server/tests/pglite/db-tests.mjs` (suite SQL), `regia.mjs`, `tv.mjs`, `banco-pesato.mjs`.
- Test SQL sul database vero: file di `server/db/tests/` nell'editor SQL di Supabase (serata attiva e vuota, `banco_inizio` nel passato); `TEST_OK …` = ok. Concorrenza: `node server/tests/concorrenza.mjs` con il server acceso.
- Simulazione: serata pulita, `update mazzobet.game_sessions set time_scale = 6 where status = 'active'`, poi `node server/sim/sim.mjs --teams 24 --sim-minutes 60 --scale 6 --seed 7`; non modificare il server durante la prova. Metriche: `server/sim/metriche.sql`.
- Migration: file numerati in `server/db/`, applicate a mano a `giochi_ufficio` (via editor SQL o strumento Supabase) **solo dopo l'OK**; l'intestazione del file dice se è applicata.
- Snippet operativi: `server/db/ops/`. Registro delle modifiche rispetto al PRD: PRD v1.0, Appendice F, e la memoria del progetto.
- Pubblicazione: `git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin regole-v06` (account Sg0B).
