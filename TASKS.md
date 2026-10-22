# MazzoBet — cose da fare e decisioni da prendere

**Aggiornato:** 21 ottobre 2026 · **Dove eravamo:** V1 funzionale completa (frontend, server, database, ricorsi, Banco, sponsor, chiusura serata) e prima simulazione di carico fatta. Il PRD è alla **v0.8** (`MazzoBet_PRD_v0.8.md`, vedi Appendice D). Per ripartire leggi prima questo file, poi il report `MazzoBet_Report_Simulazione_60min.md`.

## 1. Decisioni da prendere (nell'ordine)

- [ ] **1.1 Puntata MAX e bancarotta (bloccante).** Oggi una puntata che azzera il saldo manda subito in bancarotta e fa partire la colletta su tutte le squadre. Nella simulazione: 41 catene, ₡28.675 prelevati (la moneta iniziale è ₡24.000), 23 squadre su 24 fallite. Scegli una opzione:
  - **A.** Bancarotta solo con saldo < ₡10 **e nessuna puntata in corso** (consigliata: coerente con «chi fallisce incassa le puntate già piazzate»).
  - **B.** Una puntata non può far scendere il saldo sotto ₡10 (MAX lascia ₡10).
  - **C.** Si tiene la regola, ma la colletta non parte se la bancarotta nasce da una propria puntata, oppure c'è un tempo di attesa tra una catena e l'altra.
- [ ] **1.2 Prelievo della colletta:** limitarlo al saldo disponibile (oggi preleva ₡25 anche a chi ne ha 10–24 e lo porta in negativo; minimo visto −₡114)?
- [ ] **1.3 Convenienza dell'all-in:** fallire non costa niente (debito azzerato e ₡500 gratis, pagano gli altri). Dopo 1.1, serve altro?
- [ ] **1.4 Banco ordinario:** estrazione pesata per ridurre le squadre mai colpite (15 su 24 nella simulazione) oppure va bene così?
- [ ] **1.5 Conferma delle interpretazioni adottate** (PRD v0.8, D.3): importo del Banco unico per evento e uguale per tutti i destinatari; malus senza tetto (saldo negativo possibile).
- [ ] **1.6 Database di produzione.** Oggi tutto è nel progetto Supabase `giochi_ufficio`, schema `mazzobet`, condiviso con altri giochi. Il PRD vuole test e produzione separati: nuovo progetto Supabase (costo da verificare) o altro?
- [ ] **1.7 Eventi RadioCorsa non implementati:** «grande vincita» (serve una soglia, es. incasso ≥ ₡X) e «cassa in rosso / in attivo»: li vuoi in V1?
- [ ] **1.8 Rischi sociali** (esiti in malafede da terzi, doppio dispositivo, puntate su eventi già accaduti): confermi di accettarli o vuoi un rimedio minimo? Da guardare nella prova generale.
- [ ] **1.9 Dopo la chiusura serata:** chi usa «Cambia squadra» a serata chiusa non può rientrare. Va bene o si consente comunque la sola lettura?
- [ ] **1.10 Catalogo testi:** alcuni testi usano il verbo al singolare anche con 2–3 squadre («trova»). Correggere a mano il catalogo.

## 2. Da fare dopo le decisioni

- [ ] Applicare 1.1 e 1.2 (modifica funzioni SQL + eventuale blocco nell'interfaccia, es. tasto MAX) e **rifare la simulazione con lo stesso seed (7)** per confrontare con il report.
- [ ] Applicare 1.3–1.4 se decisi.
- [ ] Riscrivere/aggiornare il PRD a v0.9 con le decisioni prese.

## 3. Tecnico, già noto

- [ ] **Alleggerire le risposte di stato:** 27 KB per aggiornamento (circa 32 MB/ora per telefono), crescono con i mercati. Compressione, meno dati per aggiornamento o Supabase Realtime con polling di riserva.
- [ ] **Supabase Realtime** al posto del solo polling ogni 3 s (invariante 8 del PRD).
- [ ] **Salvare i test come suite ripetibile:** i test SQL del database (accesso, puntata, ricorsi, catena, Banco, sponsor, chiusura) sono stati eseguiti una tantum e non sono nel repository. Includere sempre `set local role service_role` + `set constraints all immediate`.
- [ ] **Test di concorrenza reale** (puntate simultanee stessa squadra/mercato, doppio tap, riavvio server durante un evento) e test del riavvio dei timer.
- [ ] **Token dei dispositivi dopo la chiusura serata:** i vecchi token restano legati alla vecchia serata; decidere cosa succede alla serata successiva (oggi bisogna ripassare dalla scelta squadra).
- [ ] Messaggio più chiaro quando si perde la gara per l'esito («Esito già registrato»): in simulazione è capitato nel 26% dei tentativi.
- [ ] Orari: oggi la scadenza «Orario» nel form usa l'ora del telefono; il server valida (fine serata 03:00 Europe/Rome). Verificare cambio ora legale e attraversamento mezzanotte.
- [ ] Pulire: `server/sim/out/` (risultati delle simulazioni) e `server/sim/out-run.log` non servono nel repository.

## 4. Messa online

- [ ] Creare il repository Git (la cartella **non è ancora un repository**), primo commit, `.gitignore` già presente (esclude `.env`, `node_modules`, `dist`).
- [ ] Database di produzione separato (1.6): applicare le migrazioni `server/db/001`–`008`, caricare le squadre (già nella 001), aprire la serata.
- [ ] VPS: build (`npm --prefix web run build`), server Node come servizio, Caddy per HTTPS e reverse proxy, variabili d'ambiente (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `PORT`).
- [ ] La chiave `service_role` è solo in `server/.env` sul tuo PC: tenerla fuori da Git e dalla chat; ruotarla se è mai uscita.
- [ ] Controllare i consigli di sicurezza di Supabase sul progetto di produzione.

## 5. Prova generale (con persone vere)

- [ ] Telefoni veri, più dispositivi insieme: leggibilità del countdown, tasto MAX, bottom sheet, toast delle notizie (durata, sovrapposizione, priorità), schermata ESITA obbligatoria.
- [ ] Misure che la simulazione non può dare: tempo per puntare/creare, invasività percepita del Banco, lettura delle notizie.
- [ ] Prova di fine serata con gli snippet di `server/db/ops/`: pausa, chiusura, classifica finale, verifica conti.
- [ ] Rifare la simulazione di carico più lunga (almeno 30 minuti reali o 60+ di serata) dopo le modifiche.

## Come si lavora (promemoria)

- Avvio locale: `npm --prefix server run dev` e `npm --prefix web run dev`; app su `http://localhost:5173`.
- Snippet operativi: `server/db/ops/` (da incollare nell'editor SQL di Supabase). Simulazione: `server/sim/sim.mjs` con serata pulita e `time_scale = 6`; poi chiudere la serata e aprirne una nuova.
- Registro delle modifiche rispetto al PRD: memoria del progetto (`prd-deviations-log`) e PRD v0.8, Appendice D.
