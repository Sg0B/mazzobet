# MazzoBet — cose da fare e decisioni da prendere

**Aggiornato:** 23 ottobre 2026 · **Dove siamo:** regole del prompt v0.6 confermate e implementate (ramo Git `regole-v06`), test del database salvati, prova di concorrenza e due simulazioni fatte (la colletta ora è sotto controllo), file per la messa online pronti. Il PRD è alla **v0.9** (`MazzoBet_PRD_v0.9.md`, Appendice E). Per ripartire leggi questo file, poi `MazzoBet_Report_Simulazione_v09.md` e `docs/delta-v0.6.md`.

## 1. Decisioni da prendere

- [ ] **1.1 Due scelte che ho applicato io come predefinite:** (a) **controllo sul margine delle quote** (blocca coppie come 5,00 e 5,00): tenerlo? (b) **sponsor**: ho tenuto quello del PRD v0.7 (timer 8–45′, `2000 + 150·N`, pioggia 150) e non quello del prompt v0.6 (soglia di cassa −2.000): confermi?
- [ ] **1.2 Prelievo della colletta oltre il saldo:** oggi preleva sempre 25 Carletti anche a chi ne ha 10–24 e lo porta in negativo. Limitarlo al saldo disponibile? (Nella nuova simulazione non è mai successo, ma può.)
- [ ] **1.3 Banco ordinario:** estrazione pesata per ridurre le squadre mai colpite (17 su 24 in un'ora) oppure va bene così?
- [ ] **1.4 Database di produzione.** Oggi tutto è nel progetto Supabase `giochi_ufficio`, schema `mazzobet`, condiviso con gli altri giochi (non tocca le loro tabelle). Il PRD chiede test e produzione separati: nuovo progetto Supabase (costo da verificare) o si resta così per la prima serata?
- [ ] **1.5 GitHub e ramo di lavoro.** Il lavoro è sul ramo `regole-v06`. Posso unirlo a `main` quando dai il via libera. Per il VPS serve un repository: lo creo io su GitHub (consiglio **privato**, i tuoi altri giochi sono pubblici) o preferisci copiare la cartella a mano sul VPS?
- [ ] **1.6 Rischi sociali** (esiti in malafede da terzi, doppio dispositivo, puntate su eventi già accaduti): confermi di accettarli o vuoi un rimedio minimo? Da osservare nella prova generale.
- [ ] **1.7 Dopo la chiusura serata:** chi usa «Cambia squadra» a serata chiusa non può rientrare. Va bene?
- [ ] **1.8 Catalogo testi:** alcuni usano il verbo al singolare anche con 2–3 squadre («trova»). Correggere a mano il catalogo.

## 2. Messa online sul VPS (in corso)

Preparato: `Dockerfile`, `deploy/docker-compose.yml`, `deploy/Caddyfile.mazzobet`, `deploy/aggiorna.sh`, `deploy/README.md` (passi in italiano semplice). **Da fare:**

- [ ] **Accesso al VPS:** da questo PC non riesco a collegarmi (nessuna chiave SSH, il VPS chiede la password). Due strade: (a) lanci tu i comandi della guida e mi incolli l'esito, (b) aggiungiamo una chiave SSH dedicata e li eseguo io.
- [ ] Controlli di sola lettura (rete di Caddy, Caddyfile, DNS di `mazzobet.sourlemon.cloud`) e correggere `name:` in `deploy/docker-compose.yml` se la rete non è `n8n_default`.
- [ ] Creare il repository su GitHub (1.5) e clonarlo sul VPS in `/home/lemon/mazzobet`.
- [ ] Creare **a mano sul VPS** il file `.env` con `SUPABASE_URL` e la chiave **segreta** `service_role` (non la «publishable» dei tuoi appunti). Mai in chat, mai su Git.
- [ ] `docker compose -f deploy/docker-compose.yml up -d --build` (l'immagine non è stata provata su questo PC: Docker non c'è).
- [ ] Aggiungere il blocco al Caddyfile (con copia di sicurezza e `caddy validate` prima del reload: il Caddyfile è condiviso con gli altri giochi).
- [ ] Prova: `https://mazzobet.sourlemon.cloud/api/health`, poi dal telefono.
- [ ] **Aprire la serata** il giorno stesso con `server/db/ops/05_nuova_serata.sql`: la serata attuale nel database finisce alle 03:00 di stanotte.

## 3. Tecnico

- [ ] **Supabase Realtime** al posto del solo polling ogni 3 s (invariante 8 del PRD). Con la compressione di Caddy il peso degli aggiornamenti (23 KB, max 42 KB) scende molto, ma il polling resta.
- [ ] **Prova del riavvio vero del server** durante un esito o un blocco di bancarotta (scenario 13 del prompt): i timer dipendono solo dagli orari nel database e ripetere il timer non duplica nulla (provato), ma non l'ho fatto con un riavvio reale.
- [ ] **Token dei dispositivi dopo la chiusura serata:** i vecchi token restano legati alla vecchia serata; decidere cosa vede chi riapre l'app il giorno dopo.
- [ ] Orari: la scadenza «Orario» usa l'ora del telefono nel form; il server valida (fine serata 03:00 Europe/Rome). Verificare ora legale e attraversamento della mezzanotte.
- [ ] Ripetere la simulazione con **altri seed** e per più tempo (almeno 30 minuti reali) prima della serata vera.
- [ ] Ambiente Docker locale per provare l'immagine prima del VPS (opzionale).

## 4. Prova generale con persone vere

- [ ] Telefoni veri, più dispositivi insieme: leggibilità del countdown, tasto «TUTTI I CARLETTI», messaggio del controllo sulle quote, schermata ESITA obbligatoria, «Esita per X Carletti», toast delle notizie (durata, sovrapposizione, priorità).
- [ ] Casi che la simulazione non copre: scommessa che nessuno esita (annullamento a T+17′), tempi di reazione reali, tempo per puntare/creare, invasività percepita del Banco.
- [ ] Prova di fine serata con gli snippet di `server/db/ops/`: pausa, chiusura, classifica finale, verifica conti.

## Come si lavora (promemoria)

- Avvio locale: `npm --prefix server run dev` e `npm --prefix web run dev` (app su `http://localhost:5173`).
- Test del database: incolla un file di `server/db/tests/` nell'editor SQL di Supabase (serve una serata attiva e vuota); se vedi `TEST_OK …` è andato bene. Prova di concorrenza: `node server/tests/concorrenza.mjs` con il server acceso.
- Simulazione: serata pulita, `update mazzobet.game_sessions set time_scale = 6 where status = 'active'`, poi `node server/sim/sim.mjs --teams 24 --sim-minutes 60 --scale 6 --seed 7`; dopo, chiudere la serata e aprirne una nuova. **Non modificare il server durante la prova** (si riavvia). Metriche: `server/sim/metriche.sql`.
- Snippet operativi: `server/db/ops/` (da incollare nell'editor SQL di Supabase).
- Registro delle modifiche rispetto al PRD: PRD v0.9, Appendice E, e la memoria del progetto.
