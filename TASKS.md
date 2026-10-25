# MazzoBet — cose da fare e decisioni da prendere

**Aggiornato:** 23 ottobre 2026 · **Dove siamo:** regole del prompt v0.6 confermate e implementate (ramo Git `regole-v06`), test del database salvati, prova di concorrenza e due simulazioni fatte (la colletta ora è sotto controllo), file per la messa online pronti. Il PRD è alla **v0.9** (`MazzoBet_PRD_v0.9.md`, Appendice E). Per ripartire leggi questo file, poi `MazzoBet_Report_Simulazione_v09.md` e `docs/delta-v0.6.md`.

## 1. Decisioni da prendere

- [ ] **1.1 Due scelte che ho applicato io come predefinite:** (a) **controllo sul margine delle quote** (blocca coppie come 5,00 e 5,00): tenerlo? (b) **sponsor**: ho tenuto quello del PRD v0.7 (timer 8–45′, `2000 + 150·N`, pioggia 150) e non quello del prompt v0.6 (soglia di cassa −2.000): confermi?
- [ ] **1.2 Prelievo della colletta oltre il saldo:** oggi preleva sempre 25 Carletti anche a chi ne ha 10–24 e lo porta in negativo. Limitarlo al saldo disponibile? (Nella nuova simulazione non è mai successo, ma può.)
- [ ] **1.3 Banco ordinario:** estrazione pesata per ridurre le squadre mai colpite (17 su 24 in un'ora) oppure va bene così?
- [ ] **1.4 Database di produzione.** Oggi tutto è nel progetto Supabase `giochi_ufficio`, schema `mazzobet`, condiviso con gli altri giochi (non tocca le loro tabelle). Il PRD chiede test e produzione separati: nuovo progetto Supabase (costo da verificare) o si resta così per la prima serata?
- [ ] **1.5 Ramo di lavoro.** Il repository privato `Sg0B/mazzobet` esiste e il VPS lo legge. Il lavoro è sul ramo `regole-v06`: posso unirlo a `main` quando dai il via libera.
- [ ] **1.6 Rischi sociali** (esiti in malafede da terzi, doppio dispositivo, puntate su eventi già accaduti): confermi di accettarli o vuoi un rimedio minimo? Da osservare nella prova generale.
- [ ] **1.7 Dopo la chiusura serata:** chi usa «Cambia squadra» a serata chiusa non può rientrare. Va bene?
- [ ] **1.8 Catalogo testi:** alcuni usano il verbo al singolare anche con 2–3 squadre («trova»). Correggere a mano il catalogo.

## 2. Messa online sul VPS — **fatta il 23 ottobre 2026**

Online su **https://mazzobet.sourlemon.cloud** (repository privato `Sg0B/mazzobet`, ramo `regole-v06`, contenitore `mazzobet` dietro Caddy, HTTPS e compressione attivi). Dettagli e comandi in `deploy/README.md`. Provato dall'esterno: pagina, elenco squadre dal database, certificato valido, risposte compresse, `/api/state` senza chiave = 401, aggiornamento con `deploy/aggiorna.sh`. Gli altri giochi sul VPS rispondono ancora normalmente.

- [x] Accesso SSH con chiave dedicata, controlli di sola lettura, repository privato su GitHub (account Sg0B, nessuna chiave nei file), chiave di deploy di sola lettura sul VPS, cartella `/home/lemon/mazzobet`, `.env` copiato senza mostrarlo, contenitore avviato, record DNS, blocco di Caddy (con copia di sicurezza e validazione).
- [ ] **Aprire la serata** il giorno stesso con `server/db/ops/05_nuova_serata.sql`: quella attuale nel database finisce alle 03:00 di stanotte e contiene la tua squadra di prova.
- [ ] **Revocare la chiave SSH** di lavoro (riga `claude-mazzobet-20261023` in `/root/.ssh/authorized_keys`) quando non serve più.
- [ ] **Unire `regole-v06` a `main`** (e far puntare il VPS su `main`) quando dai il via libera.
- [ ] Nessun backup automatico del database e nessun monitoraggio: valuta se servono prima della serata vera.

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

## 5. Aggiornamento del 25 ottobre 2026 — Regia, classifiche, quote

- [x] Aiuto «MAX» sulle quote, classifiche (migration 012 **applicata**) e saldo del Banco in RadioCorsa: online.
- [ ] **Banco di Regia** (`/regia`, `docs/accesso-regia.md`): scritto e provato in locale. Da fare: (1) via libera e applicazione della **migration 011** su Supabase (prima, poi il VPS); (2) impostare `ADMIN_CODE` nel `.env` del VPS e ricreare il contenitore; (3) prova da telefono vero.
- [ ] **PIN delle squadre** (prompt accesso §1): dopo la Regia (migration 013 se serve); «Resetta squadra» cancellerà anche il PIN.
- [ ] **Notifiche push** (prompt notifiche): dopo il PIN. Leggere precedenza e finestra di esito dal DB, non da variabili d'ambiente.
- [ ] Colletta limitata al saldo disponibile (1.2) e Banco ordinario con estrazione pesata (1.3), da fare con la prossima simulazione.
- [ ] Prima di simulazioni e test SQL: il Banco parte solo dopo `banco_inizio` (vedi la guida della Regia).
