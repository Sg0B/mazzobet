# Delta: prompt «regole v0.6» contro lo stato attuale (PRD v0.8 + codice)

**Data:** 23 ottobre 2026 · **Fonte:** `prompt_claude_code_mazzobet_v06.md` · **Confrontato con:** `MazzoBet_PRD_v0.8.md`, `TASKS.md`, codice in `web/` e `server/`.
Il prompt è antecedente al PRD v0.7: dove i due si contraddicono, il PRD v0.7/v0.8 dice che prevale la versione più recente, ma sono **regole di gioco** e le decide tu (sezione B).

Legenda stato: ✅ già fatto · 🟡 fatto in parte · ❌ da fare · ⚠️ in conflitto col PRD v0.8 (serve una tua decisione) · ➖ superato, si tiene il PRD v0.8.

## A. Tabella area per area

| Area | Stato attuale | Regola richiesta dal prompt | Azione | Rischio |
| --- | --- | --- | --- | --- |
| 2.1 «Scommessa», non «mercato» | ✅ L'interfaccia dice «Scommessa n. 42». | Idem | Nessuna (controllare che non resti «mercato» nei messaggi del server) | Basso |
| 2.1 Valuta senza simbolo | ⚠️ L'app usa ovunque **₡** («₡ 1.000»), come il PRD v0.7 e il prototipo validato. | «Carletti» senza simbolo, «1.000 Carletti», funzione per «1 Carletto». | **Decisione B.2**, poi sostituzione in interfaccia, errori, notizie | Medio: tocca tutte le schermate |
| 2.1 Tasto MAX | ❌ Si chiama «MAX». | «TUTTI I CARLETTI» | Rinominare | Basso |
| 2.2 Costo, creatore escluso, 100 Carletti | ✅ | Idem | Nessuna | — |
| 2.2 LIVE 20 min + A SCADENZA (+30m, +1h, +2h, custom), fine serata 03:00 | ✅ (LIVE 20 reintrodotto in v0.8) | Idem | Nessuna | — |
| 2.2 Quote 1,10–10,00 in centesimi | ✅ | Idem | Nessuna | — |
| 2.2 **Controllo sul margine** `100·(A+B) ≥ A·B` | ❌ Nessun controllo: oggi si può pubblicare 5,00 e 5,00. | Bloccare le quote «regalo» con messaggio chiaro | **Decisione B.5**; poi 1 controllo in SQL + messaggio | Basso |
| 2.2 Riga sul compenso nel pannello di creazione | ❌ | «Se esiti tu ricevi il 10% (max 250)…» | Dipende da **B.3** | — |
| 2.2 ESITA ORA in un passo | 🟡 Oggi in due passi: pulsante, poi schermata dove scegli SÌ/NO. | Il creatore sceglie SÌ o NO e chiude subito | Unire i due passi (interfaccia + SQL) | Basso |
| 2.3 Puntate: una per squadra, minimo 10, importi rapidi, floor | ✅ | Idem | Nessuna | — |
| 2.3 Saldo disponibile / impegnato | ✅ | Idem | Nessuna | — |
| 2.4 **Precedenza del creatore** per i primi 2 minuti dopo T | ⚠️ Non c'è: dopo T esitano subito creatore e non scommettitori, la prima risposta vince (PRD v0.7 §7: «senza precedenza per il creatore»). Finestra 15' da T. | Solo il creatore fino a T+2'; poi tutti fino a T+17'; poi annullamento | **Decisione B.1** | Medio: cambia tempi e «Da esitare» |
| 2.4 **Scommessa senza puntate** | ❌ Oggi anche senza puntate il creatore vede la schermata obbligatoria e dopo 15' la scommessa si annulla. | Si chiude alla scadenza «senza puntate»: niente esito, niente contestazione, niente annullamento; i 100 restano spesi | Implementare | Basso, utile |
| 2.4 Contestazione 3', maggioranza `floor(N/2)+1`, ribaltamento unico, rettifica netta | ✅ | Idem | Nessuna | — |
| 2.4 Bancarotta può esitare e incassare | ✅ (può esitare; il compenso non esiste) | Idem | Nessuna | — |
| 2.4 **Compenso di chi esita** (10% del totale puntato, max 250; altro esitatore 50%; pagato 3' dopo, solo se non ribaltato, dal Banco) | ❌ Non esiste. | Come descritto, con «Esita per X Carletti» nella scheda e compenso mostrato al creatore | **Decisione B.3**; se sì: nuova voce di ledger, scheda, tab Scommesse | Medio-alto: nuovi flussi economici |
| 2.5 Bancarotta sotto 10 | ✅ | Idem | Nessuna | — |
| 2.5 **Bancarotta solo senza puntate da risolvere** (decisione 7.A) | ❌ Oggi si fallisce subito, anche con puntate in corso: è la causa principale del problema trovato nella simulazione (**opzione A di TASKS 1.1**). | Si fallisce solo se saldo < 10 **e** nessuna puntata da risolvere; scatta quando l'ultima si risolve e il saldo è ancora < 10 | **Decisione B.4** (nel prompt è «da confermare»); poi SQL + nuova simulazione | Medio: tocca il cuore dell'economia |
| 2.5 Blocco 5', riammissione 500, rientro automatico ≥10, nessuna colletta da riammissione | ✅ | Idem | Nessuna | — |
| 2.6 Colletta: 25 a giro, paganti ≥10, un prelievo per squadra a giro, cascata, valvola 3, una notizia | ✅ | Idem | Nessuna (vedi scenario di test 10) | — |
| 2.7 Banco: timer 8–14', 5ª squadra, 1–3 squadre, importo unico 100–250, 55/45, malus solo ≥10, fallback bonus | ✅ | Idem | Nessuna | — |
| 2.7 Importi in **multipli di 10** | ❌ Oggi qualsiasi valore tra 100 e 250. | Multipli di 10 | Piccola modifica | Basso |
| 2.7 **Non ripetere lo stesso testo nella sessione** | ❌ Pesca a caso, può ripetere. | Evitare ripetizioni | Piccola modifica | Basso |
| 2.7 Registro degli interventi con saldi risultanti | 🟡 Registrati ora, tipo, destinatari, importo; i saldi si ricavano dal ledger. | «…e saldi risultanti» | Valutare se aggiungere nel registro | Basso |
| 2.8 Cassa del Banco da ledger, informativa | ✅ | Idem | Nessuna | — |
| 2.8 **Sponsor a soglia di cassa** (−2.000, 4.000/8.000, pausa 30', max 3, pioggia 100–150 dopo 1–2') | ➖ Sostituito dal PRD v0.7: timer 8–45', contributo `2000+150N+max(0,−C)`, pioggia 150 a tutte le squadre contestuale, nessun tetto. Già implementato e provato. | Come descritto | **Si tiene il v0.7** (da confermare in B.6) | Basso |
| 2.8 Comunicati cassa in rosso / in attivo | ❌ | Quando la cassa cambia segno | Implementare (TASKS 1.7) | Basso |
| 2.9 Classifiche, spareggio, conteggi, statistiche cassa | ✅ | Idem | Nessuna | — |
| 2.9 Compenso potenziale/ricevuto in «Create da me» | ❌ | Mostrarlo | Dipende da B.3 | — |
| 2.10 Accesso senza PIN, «Stai entrando come X», token | ✅ | Idem | Nessuna | — |
| 2.11 Script di fine serata | ➖ Già meglio del prompt: pausa, chiusura in due tempi, chiusura forzata, nuova serata, classifica finale, verifica conti (`server/db/ops/`). | Due script (pausa, chiusura con rimborsi) | Nessuna | — |
| 2.12 Comunicati per bancarotta, riammissione, ribaltamento, colletta, annullamento | ✅ | Idem | Nessuna | — |
| 2.12 **Grande vincita** (soglia 500) | ❌ | Comunicato per vincite ≥ 500 Carletti | Implementare con la soglia 500 data dal prompt | Basso |
| 2.12 Banner Home 3–4 notizie, cronologia in RadioCorsa | ✅ | Idem | Nessuna | — |
| 3 **Parametri in configurazione** (tutti i numeri fuori dal codice) | ❌ I numeri (15', 3', 5', 100, 25, 8–14…) sono dentro le funzioni SQL. | Tabella di configurazione unica | Creare una tabella parametri per serata e farla leggere alle funzioni | Medio: riscrive molte funzioni |
| 4 Test automatici (13 scenari) | 🟡 Quasi tutti già provati a mano nel database ma **non salvati**; mancano: concorrenza vera (scenari 3-4), riavvio server (13), nuove regole. | Suite ripetibile con orologio simulato | Salvare i test nel repository; il fattore di velocità `time_scale` fa da orologio accelerato | Medio |
| Metodo: branch `regole-v06`, commit per area | ❌ La cartella **non è un repository Git**. | Branch dedicato, un commit per area | Creare il repository e il branch (vedi sezione D) | Basso |
| Metodo: solo database di test, migrazioni versionate | 🟡 Migrazioni versionate in `server/db/` ✅. Un solo database (`giochi_ufficio`), che fa da test. | Idem | Nessuna fino alla messa online | — |
| Consegna: riassunto, test, passi per provare a mano, istruzioni GitHub/VPS | ❌ | Come descritto | A fine lavoro | — |

## B. Decisioni che servono (cambiano le regole del gioco)

1. **Precedenza del creatore per 2 minuti** (prompt) contro **nessuna precedenza** (PRD v0.7). Con la precedenza la schermata «ESITA LA SCOMMESSA!» ha più senso, perché il creatore non viene scavalcato subito (nella simulazione il 56% degli esiti è arrivato da altri).
2. **Simbolo ₡**: toglierlo e scrivere «Carletti» (prompt) o tenerlo (PRD v0.7, prototipo validato)?
3. **Compenso di chi esita** (10%, max 250): è una funzione nuova, non presente nel PRD v0.7. Incentiva a esitare, ma aggiunge flussi economici e schermate.
4. **Bancarotta solo senza puntate in corso** (7.A del prompt = opzione A di TASKS 1.1): risolve il grosso del problema della colletta. Va poi rifatta la simulazione con lo stesso seed.
5. **Controllo sul margine delle quote**: bloccare coppie come 5,00 e 5,00?
6. **Sponsor**: confermi che vale il PRD v0.7 (timer, formula `2000+150N`, pioggia 150) e non quello del prompt (soglia cassa −2.000)?

## C. Dove il codice fa già meglio del prompt, o i punti del prompt si contraddicono

- **Fine serata:** il prompt prevede due script semplici; abbiamo chiusura in due tempi con classifica congelata e sola lettura.
- **Sponsor e pioggia:** il prompt e il PRD v0.7 sono incompatibili; il codice segue il v0.7.
- **Strumenti non previsti dal prompt:** simulatore di carico, fattore di velocità, snippet di verifica dei conti, limite di richieste per dispositivo.
- **Contraddizioni interne al prompt:** la pioggia va alle squadre «non in bancarotta» (2.8) mentre il PRD v0.7 la dà anche alle fallite; il Banco ordinario può colpire anche le fallite (2.7), la pioggia no. Il compenso è pagato dal Banco ma il prompt dice «nessuna commissione sulle vincite»: non sono in conflitto, ma va chiarito nei testi.
- **Percorsi:** il prompt usa `content/`, `ops/`, `docs/`; il codice ha `server/data/` e `server/db/ops/`. Si tengono quelli attuali.

## D. Piano proposto dopo la tua conferma

1. Creare il repository Git, un primo commit dello stato attuale e il branch `regole-v06` (il prompt lo chiede).
2. **Subito, senza dipendere da decisioni:** scommessa senza puntate, importi del Banco in multipli di 10 e testi non ripetuti, comunicati «grande vincita» (soglia 500) e cassa in rosso/in attivo, ESITA ORA in un passo, tasto «TUTTI I CARLETTI».
3. Applicare le decisioni B.1–B.5: bancarotta con puntate pendenti, valuta, precedenza, controllo margine e compenso (se confermati).
4. Tabella dei parametri di configurazione.
5. Suite di test salvata (13 scenari del prompt + quelli già fatti) e **nuova simulazione con lo stesso seed (7)** per confrontare con il report.
6. Aggiornare PRD (v0.9), TASKS.md e consegnare riassunto, passi di prova a mano e istruzioni di messa online.

Dopo ogni area ti dico in italiano semplice cosa è cambiato e come verificarlo a mano nell'app.

---

## E. Esito dell'implementazione (23 ottobre 2026, ramo `regole-v06`)

**Decisioni prese da te:** bancarotta solo senza puntate in corso (A) · precedenza del creatore di 2 minuti · «Carletti» senza simbolo · compenso di chi esita.
**Applicate con la scelta consigliata, da confermare:** controllo sul margine delle quote (applicato) · sponsor secondo il PRD v0.7, non secondo il prompt (tenuto).

| Area | Esito |
| --- | --- |
| «Scommessa» / numero progressivo | ✅ già presente |
| Valuta «Carletti» senza simbolo, «1 Carletto», tasto «TUTTI I CARLETTI» | ✅ fatto (interfaccia, errori del server, notizie). Nelle classifiche e nei movimenti solo il numero, con «Carletti» nel titolo |
| Controllo sul margine `100·(A+B) ≥ A·B` | ✅ fatto (database e controllo immediato nel foglio di creazione) |
| Riga sul compenso nel pannello di creazione | ✅ fatto |
| ESITA ORA in un passo | ✅ fatto (si sceglie SÌ o NO e si chiude subito) |
| Precedenza del creatore (T+2′) e annullamento a T+17′ | ✅ fatto; «Da esitare» visibile agli altri da T+2′ |
| Scommessa senza puntate | ✅ fatto: si chiude da sola, nessun esito, nessun annullamento |
| Compenso di chi esita (10%, max 250, altro esitatore 50%, a fine contestazione, non se ribaltato) | ✅ fatto, con «Esita per X Carletti» nelle schede e il compenso in «Create da me» |
| Bancarotta con puntate in corso (7.A) | ✅ fatto: si fallisce quando l'ultima puntata si risolve con saldo sotto 10 |
| Banco: importi in multipli di 10, testi non ripetuti, registro con saldi risultanti | ✅ fatto |
| Comunicati «cassa in rosso / in attivo» e «grande vincita» (soglia 500) | ✅ fatto |
| Parametri in configurazione | ✅ tabella `mazzobet.config` letta dalle funzioni; il client riceve i valori che gli servono |
| Sponsor a soglia di cassa del prompt | ➖ non fatto di proposito: resta lo sponsor a timer del PRD v0.7 |
| Test automatici | ✅ 4 file in `server/db/tests/` (scenari 1–12 e timer ripetuti) + `server/tests/concorrenza.mjs` (12 controlli sull'API). Il riavvio vero del server (scenario 13) non è provato: i timer dipendono solo dagli orari nel database e ripetere il timer non duplica nulla |
| Git | ✅ repository creato, `main` = stato di prima, lavoro sul ramo `regole-v06` |
| Messa online | 🟡 Dockerfile, compose, blocco Caddy e guida in `deploy/`; da eseguire sul VPS |
