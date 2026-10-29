# Piano di lavoro: La Teramana dentro MazzoBet

**Stato:** proposta del 29/10/2026, in attesa di via libera. Nessun codice toccato.
**Fonti:** cartella `corsa simulata/` (2 JSON, 3 documenti, immagini PCS) e decisioni prese in chat (vedi la memoria del progetto).

## 1. Cosa abbiamo già e riusiamo

| Cosa serve | Cosa c'è già | Come lo uso |
| --- | --- | --- |
| Scommesse SÌ/NO a quota fissa | Tabelle `markets` e `bets`, funzione `mb_place_bet` | Le 10 scommesse della corsa sono scommesse normali con un'etichetta «corsa» e senza creatore |
| Il Banco paga le vincite | `mb_resolve` paga `puntata × quota` dalla cassa del Banco, anche se va sotto zero | Stesso identico pagamento, stessa riga nel registro dei Carletti (`win`) |
| Registro dei Carletti | `ledger_*`, a partita doppia, che non si modifica | Nessuna modifica |
| Rimborso | `void_market` | Per annullare una scommessa della corsa (chiusura serata o Regia) |
| Timer sul server | `mb_tick` ogni 5 secondi, calcolato sugli orari nel database | Aggiungo un secondo timer, più preciso, solo per la corsa |
| Notifiche | `mb_push_due` + worker + tabella `push_log` | Aggiungo 3 tipi di avviso nuovi |
| Regia | `/regia` con codice ADMIN_CODE | Aggiungo il riquadro «Corsa» con START e Pausa |
| Schermo sala | `/tv` e `mb_get_tv` | Aggiungo il pannello della corsa |
| Caricamento dati da file | Il catalogo del Banco viene letto da `server/data/*.json` all'avvio | Stesso metodo per i due JSON della corsa |
| Le 24 squadre | Hanno già gli stessi nomi (migration 001) | Nessun collegamento da inventare |

## 2. Cose da cambiare nel database (migration 017 e 018)

Tutte le tabelle nuove sono chiuse al pubblico: i telefoni non le leggono mai direttamente, solo il server tramite funzioni.

**Nuove tabelle, con i dati riservati (mai inviati ai telefoni)**
- `race_events`: le 73 notizie con ora di uscita, km, tipo, testo.
- `race_markets`: le 10 scommesse con aperture, chiusure, quote, **esito vincente** e regola di pagamento.

**Nuove tabelle, con lo stato (pubbliche solo a pezzi)**
- `race_runs`: una riga per serata. Contiene stato (non partita, in corso, in pausa, finita, interrotta), istante di START, secondi di pausa accumulati.
- `race_feed`: le notizie **già uscite**. Una notizia viene copiata qui solo nel momento in cui esce. I telefoni leggono solo questa tabella, quindi non hanno nessuna possibilità di vedere notizie future.

**Cambi a tabelle esistenti**
- `markets.creator_team_id` diventa facoltativo (le scommesse della corsa non hanno creatore) e arrivano due colonne: `race_market_id` (quale delle 10) e `race_state` (aperta, chiusa, in attesa di conferma, liquidata).
- `push_log.kind` accetta tre nuovi tipi: `C` (si è aperta), `D` (sta per chiudere), `E` (hai vinto).

**Funzioni da ritoccare perché ignorino le scommesse della corsa**
- `mb_tick`: non deve chiuderle, svuotarle o annullarle da solo (lo fa il timer della corsa).
- `mb_place_bet`: stesso controllo di prima, più il blocco «la chiusura la decide l'orologio di gara sul server» e «niente puntate se la corsa è in pausa».
- `mb_get_state`, `mb_admin_state`, `mb_get_tv`: oggi uniscono il creatore con un join che scarterebbe le scommesse senza creatore. Va reso opzionale.
- `mb_push_due`: le notifiche A e B (esito) devono saltare le scommesse della corsa.
- `try_finalize` e chiusura serata: alla chiusura la corsa si interrompe e le puntate non decise tornano ai giocatori (stesso meccanismo del rimborso già esistente).

## 3. Come funziona l'orologio

- START dalla Regia scrive l'istante di partenza **sul database**. Il tempo di gara è: `adesso − START − secondi di pausa`.
- **Pausa**: ferma il conteggio. Alla ripresa i secondi di pausa si sommano. Durante la pausa non si accettano puntate sulla corsa e i conti alla rovescia si fermano.
- Un timer sul server (ogni secondo, solo se la corsa è in corso) fa tre cose, sempre in quest'ordine:
  1. pubblica le notizie il cui orario è arrivato, in ordine di codice (PCS001, PCS002, …);
  2. apre le scommesse arrivate all'orario di apertura, con le loro quote fisse;
  3. liquida le scommesse il cui risultato è già pubblicato.
- Tutto si basa sul tempo di gara salvato nel database, non su orologi di telefoni e non su timer in memoria. Se il server si riavvia, al primo secondo successivo recupera tutto in ordine, senza duplicati.
- **Chiusura delle puntate**: non dipende dal timer. `mb_place_bet` calcola il tempo di gara al momento della puntata e rifiuta se è ≥ ora di chiusura. Anche se il timer è in ritardo, la puntata non passa.

## 4. Come si liquida (una volta sola, mai due)

- Ogni scommessa ha un segno «liquidata alle…» e il pagamento usa la chiave unica già presente nel registro (`win:<puntata>`). Anche se il codice girasse due volte, il database rifiuta il duplicato.
- La liquidazione parte solo **dopo** che la notizia che la determina è stata pubblicata, nello stesso passo del timer.

| Scommessa | Regola |
| --- | --- |
| B01–B05 | Liquidata alla notizia di risultato (PCS009, 016, 033, 039). B03 e B04 insieme (PCS033). |
| B06 | A +142:00 (PCS053) diventa **«in attesa di conferma»**, senza esito. Si liquida solo a +171:00 (PCS064). |
| B07 | SÌ alla prima foratura valida (PCS021 a +80:00). Il NO scatterebbe alla prima notizia dopo il km 107 (PCS050), solo se nessuna foratura valida fosse uscita. Le due forature sono segnate nei dati per codice notizia, senza leggere il testo. La seconda (Rabobank) non liquida niente. |
| B08–B10 | Aperte insieme a +176:00, chiuse a +179:00, liquidate a +180:00 con PCS073. |

- Chi ha vinto prende `puntata × quota`, e la sua statistica «scommesse azzeccate» sale, come per le scommesse normali. Non ci sono compenso per chi esita, ricorsi, colletta o aiuto MAX.
- Chi ha una puntata ancora aperta sulla corsa non va in bancarotta (regola già esistente). Per B06 sono fino a 29 minuti.

## 5. Cosa vedono i telefoni (anti-fuga)

- Dal server i telefoni ricevono **solo**: le scommesse della corsa già aperte (con quote e domanda), lo stato della corsa (non partita, in corso, in pausa, finita) con il tempo di gara e `race_feed` (notizie uscite). Mai `race_events`, mai `race_markets`, mai l'esito vincente.
- L'esito appare solo come `outcome` della scommessa **dopo** la liquidazione, come per le altre.
- Il tempo di gara viaggia col suo istante del server: il telefono calcola solo il conto alla rovescia e non decide niente.
- Chi arriva tardi riceve le notizie già uscite e le scommesse già chiuse o liquidate. Un refresh non cambia niente.

## 6. Cosa cambia nell'app (con la grafica approvata)

- **Quinta voce nel menu in basso: «Corsa»** (con il piccolo logo PCS). Prima di START mostra «La corsa non è ancora partita».
- **Pagina Corsa:** logo dei tre quadrati con «PRO CARLETTO STATS», riga con km mancanti, tempo di gara e velocità media; sotto la cronaca con linea verticale, cerchi dei km, icone per tipo, nomi in blu. Sfondo `#1D2922`, barra `#26362C`, rosso PCS `#E5575B`, blu dei nomi `#6CC0F5`. Il nome della propria squadra è evidenziato nelle notizie.
- **Pagina Scommesse e Home:** le scommesse della corsa appaiono in alto con fascia rossa PCS e piccolo logo, SÌ/NO in rosso. Dentro l'app usano la stessa scheda di puntata. Le scommesse normali non cambiano.
- **In Scommesse → Le mie puntate:** stesse righe, con la scritta «IN ATTESA DI CONFERMA UFFICIALE» per B06.
- **Notizie importanti** (risultato, ritiro, caduta): nessun popup. Compaiono nella pagina Corsa; le scommesse invece avvisano con le notifiche.
- **`/tv`:** pannello cronaca ultime 6 notizie, scommesse aperte con conto alla rovescia, risultati appena usciti.
- **Regia:** nuovo riquadro «Corsa» con stato, tempo di gara, **Avvia corsa** (con conferma), **Pausa/Riprendi**, e l'elenco delle 10 scommesse con stato e possibilità di annullarle (rimborso). Nessun comando di velocità in Regia.

## 7. Notifiche (solo sulle scommesse)

- **C, «si è aperta»**: a tutte le squadre in gioco con avvisi attivi. Se se ne aprono più insieme (B03+B04, B08–B10) parte **una sola** notifica che le conta.
- **D, «sta per chiudere»**: 2 minuti prima della chiusura, solo a chi non ha già puntato (1 minuto per B08–B10, che restano aperte 3 minuti).
- **E, «hai vinto»**: a chi ha vinto, con l'importo.
- Nessuna notifica rivela l'esito di una scommessa non ancora liquidata. Ogni (scommessa, squadra, tipo) parte una volta sola, come già avviene per A e B.

## 8. Caricamento dei dati

- I due JSON vanno in `server/data/` insieme al catalogo. All'avvio il server li legge, **li controlla** (73 notizie ordinate per tempo e codice, 10 scommesse con quote e orari coerenti, i codici delle notizie citati esistono) e li carica nel database. Se qualcosa non torna, non carica e scrive l'errore nei log: la corsa non parte, ma il resto del gioco funziona.
- Dopo START i dati non si possono più cambiare.

## 9. Test (prima di toccare il VPS)

1. **Test del database** nello stile di `server/db/tests/`, sulla copia locale: si porta lo START «nel passato» per saltare al tempo che serve, senza aspettare 3 ore.
2. **Controlli sui momenti chiave** della lista del documento: +33:30 / +34:00, +79:45 / +80:00, +102:30 / +103:00, +141:30 / +142:00 / +171:00, +176:00 / +179:00 / +180:00.
3. **Controlli sui casi difficili**: puntata un secondo dopo la chiusura (rifiutata), due timer insieme (un solo pagamento), riavvio del server a metà corsa, pausa e ripresa, arrivo in ritardo, saldo insufficiente, squadra in bancarotta, chiusura serata durante la corsa, Reset totale, controllo del registro dei Carletti (tutto somma zero) e che ai telefoni non arrivi mai un esito o una notizia futura.
4. **Simulazione accelerata**: un solo script di test (non in Regia, non in produzione) che gira la corsa a velocità alta con squadre finte, confronta le vincite con quelle attese e controlla la cassa del Banco a fine corsa.
5. **Prova sul telefono**: in locale con la corsa accelerata, poi sul VPS in una serata di prova con gli amici.

## 10. Ordine dei lavori

1. **Fase 1, dati e motore (senza interfaccia).** Migration 017, caricamento JSON, timer, apertura, chiusura, liquidazione, pausa, interruzione. Test SQL.
2. **Fase 2, app.** Pagina Corsa, scommesse della corsa dentro Home e Scommesse, Regia, `/tv`.
3. **Fase 3, notifiche.** Tre nuovi tipi C, D, E.
4. **Fase 4, prove.** Simulazione accelerata, controlli finali, prova con gli amici, poi aggiornamento del PRD (v1.2) e di `TASKS.md`.

Ogni fase si ferma per una tua verifica prima della successiva. Sul VPS non si pubblica niente finché le fasi 1–3 non passano i test in locale.

## 11. Rischi e punti di attenzione

- **Economia dei Carletti.** Il Banco paga sempre. Un giocatore può puntare tutto il saldo su più scommesse con quote fino a 3,50. Lo osserveremo nella simulazione e ne parliamo prima della serata. Non metto limiti da solo.
- **Puntata massima.** Oggi le scommesse normali hanno minimo 10 Carletti e nessun massimo (si può puntare fino al proprio saldo). I «minimo e massimo del Banco» in Regia riguardano gli importi di bonus e malus, non le puntate. Per le scommesse della corsa propongo le stesse regole delle normali (minimo 10, massimo il saldo).
- **Pausa e corsa a metà serata.** La corsa si interrompe se la Regia chiude la serata o fa Reset totale. La corsa si rifà da zero con una nuova serata.
- **Quote e orari.** Non ricalcolo niente. Se i dati hanno un'incoerenza, la segnalo e aspetto la tua decisione.
- **Tempi molto stretti.** B08–B10 restano aperte 3 minuti di gara: chi ha il telefono lento ha poco margine. Non cambio i tempi, ma lo teniamo d'occhio nella prova.
- **Velocità media.** Il documento non ne dà una. La calcolo da km dell'ultima notizia e dal suo orario, quindi è un valore approssimato, come i km indicativi dell'ultimo tratto.
