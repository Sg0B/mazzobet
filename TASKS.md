# MazzoBet — cose da fare e decisioni da prendere

**Aggiornato:** 30 ottobre 2026 · **Dove siamo:** online https://mazzobet.sourlemon.cloud (ramo Git `regole-v06`, repository privato `Sg0B/mazzobet`). Fatti: regole v0.6, classifiche, Banco di Regia, schermo `/tv`, PIN, «Aggiungi a Home», notifiche push e **la corsa simulata «La Teramana»** (migration 017–020 già applicate a `giochi_ufficio`, codice committato in locale ma **non ancora sul VPS né pubblicato su GitHub**). Il PRD è alla **v1.2** (`MazzoBet_PRD_v1.2.md`, Appendice H). Per ripartire leggi questo file, poi le Appendici F, G e H del PRD, `docs/piano-corsa-simulata.md` e `docs/notifiche.md`.

## 0. Prossimi passi, in ordine

0. **Corsa simulata:** (a) `git push origin regole-v06` e **deploy sul VPS** con `sh deploy/aggiorna.sh` (le migration 017–020 sono già nel database: prima il database, poi il server; nei log deve comparire il caricamento della corsa e nessun errore); (b) **serata di prova con gli amici** (Regia → Corsa → Avvia corsa; guardare pagina Corsa, scommesse in alto, notifiche C/D/E a schermo bloccato, tempi stretti di B08–B10, `/tv`); (c) dopo la prova, valutare l'economia (il Banco con puntate casuali chiude in perdita: vedi PRD H.3) e il saldo iniziale. Prove locali: `node server/tests/pglite/corsa.mjs` (102 controlli) e `corsa-simulazione.mjs`.
1. **Provare le notifiche push su telefoni veri** (guida `docs/notifiche.md`): attivazione dalla card in Home, notifica A al creatore e notifica B ai non puntatori con schermo bloccato, tocco con app chiusa e aperta, iPhone dalla Home e Android. *(Utente: 28/10 sera.)* Se qualcosa non arriva: log del VPS (`docker logs --tail 50 mazzobet`).
2. **Provare «Aggiungi a Home» su Android** (icona maskable separata; su iPhone è già a posto).
3. **Nuova simulazione** (24 squadre, 60′ ×6): misurare le squadre mai colpite con l'estrazione pesata e decidere il **saldo iniziale** (oggi 1.000, parametro in Regia). Prima: `banco_inizio` nel passato, poi ripristinarlo (vedi guida Regia).
4. **Prova generale con persone vere** (sezione 4), poi unione di `regole-v06` a `main` e VPS su `main`.

Fatti e verificati: Regia, `/tv` (provata su TV), PIN (online, provato su iPhone), «Aggiungi a Home» (iPhone), chiavi VAPID nel `.env` del VPS e notifiche accese (verificate nei log e da `/api/push/key`).

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
- [x] Aggiornamenti del 26–27/10: Regia, colletta, TV, PIN, «Aggiungi a Home», notifiche push; `ADMIN_CODE` e chiavi VAPID nel `.env`.
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

## 6. Fatto il 26 e 27 ottobre 2026

- [x] **PIN delle squadre** (migration 015): PIN a 4 cifre con hash scrypt, blocco di 1 minuto dopo 5 errori, telefono riconosciuto senza PIN, riquadro «Imposta il PIN» per le squadre già in gara, «Resetta squadra» cancella anche il PIN. Provato dall'utente su iPhone.
- [x] **«Aggiungi a Home»:** manifest, icone dal logo (normali e maskable), riquadro in Home. Provato su iPhone.
- [x] **Notifiche push** (migration 016, guida `docs/notifiche.md`): avviso A al creatore e B ai non puntatori, tempi dal database, una volta sola, fallback sempre attivi. Chiavi VAPID nel `.env` del VPS.
- [x] Test: `pin.mjs`, `push.mjs`, `push-server.mjs` in `server/tests/pglite/`.
- [x] PRD v1.1 con Appendice G; la v1.0 resta come storico.

## 7. Fatto il 29 e 30 ottobre 2026 — corsa simulata

- [x] **Fase 1, dati e motore** (migration 017–018, `server/src/race.ts`, caricamento controllato dei due JSON, orologio sul database, pausa, chiusura serata/reset).
- [x] **Fase 2, app** (migration 019): pagina Corsa «Pro Carletto Stats», scommesse fissate in alto in rosso PCS, voce nel menu, scheda Corsa in Regia, scena sulla TV, `/api/race`.
- [x] **Fase 3, notifiche** (migration 020): C aperta, D sta per chiudere, E hai vinto.
- [x] **Fase 4 (parte locale):** `corsa-simulazione.mjs`, PRD v1.2 con Appendice H.
- [ ] Deploy sul VPS e prova con gli amici (sezione 0).

## Come si lavora (promemoria)

- Avvio locale: `npm --prefix server run dev` (carica `server/.env` con la chiave **vera**: per prove usa un finto Supabase come in `server/tests/pglite/`) e `npm --prefix web run dev` (app su `http://localhost:5173`; `/regia` e `/tv` sono pagine dello stesso frontend).
- Prove senza toccare il database vero: `npm i --no-save @electric-sql/pglite`, poi `node server/tests/pglite/db-tests.mjs` (suite SQL), `regia.mjs`, `tv.mjs`, `banco-pesato.mjs`, `pin.mjs`, `push.mjs`, `push-server.mjs` (gli ultimi due avviano il server vero con un finto Supabase; chiudono da soli i processi che lanciano).
- Test SQL sul database vero: file di `server/db/tests/` nell'editor SQL di Supabase (serata attiva e vuota, `banco_inizio` nel passato); `TEST_OK …` = ok. Concorrenza: `node server/tests/concorrenza.mjs` con il server acceso.
- Simulazione: serata pulita, `update mazzobet.game_sessions set time_scale = 6 where status = 'active'`, poi `node server/sim/sim.mjs --teams 24 --sim-minutes 60 --scale 6 --seed 7`; non modificare il server durante la prova. Metriche: `server/sim/metriche.sql`.
- Migration: file numerati in `server/db/`, applicate a mano a `giochi_ufficio` (via editor SQL o strumento Supabase) **solo dopo l'OK**; l'intestazione del file dice se è applicata.
- Snippet operativi: `server/db/ops/`. Registro delle modifiche rispetto al PRD: PRD v1.1, Appendici F e G, e la memoria del progetto.
- Pubblicazione: `git push origin regole-v06` (account Sg0B; dopo `gh auth setup-git` Git usa il login di `gh`. In caso di errore 403 «denied to …» le credenziali salvate di Windows sono di un altro account).
