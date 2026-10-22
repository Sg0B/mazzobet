# MazzoBet — Product Requirements Document (PRD)

**Versione:** 0.9 — regole del prompt v0.6 confermate e implementate (bancarotta con puntate in corso, precedenza del creatore, compenso di chi esita, valuta «Carletti», controllo sulle quote) e risultati della seconda simulazione  
**Data:** 23 ottobre 2026  
**Stato:** V1 funzionale completa e provata (test SQL, test di concorrenza, due simulazioni); **in attesa di messa online** e di poche decisioni residue (vedi Appendice E e `TASKS.md`)  
**Fonti:** PRD v0.8; `prompt_claude_code_mazzobet_v06.md` (regole confermate il 23/10/2026); `docs/delta-v0.6.md`; report `MazzoBet_Report_Simulazione_60min.md` e `MazzoBet_Report_Simulazione_v09.md`; `catalogo_banco_v02.json`. In caso di conflitto prevale questa v0.9. Le modifiche rispetto alla v0.8 sono in **Appendice E**; le Appendici A–D restano come storico.

> **Obiettivo:** individuare rischi, casi limite e semplificazioni senza snaturare MazzoBet. I requisiti approvati non vanno sostituiti con alternative solo perché tecnicamente più convenzionali.

## 0. Legenda e regole di revisione

- **[APPROVATO]** Decisione di prodotto concordata e da implementare.
- **[PROVVISORIO]** Impostazione di partenza da misurare nella prova generale.
- **[APERTO]** Decisione o ambiguità ancora da risolvere.
- **[TECNICO PROPOSTO]** Soluzione ingegneristica suggerita, da validare durante lo sviluppo.

Le nuove decisioni v0.6 **sostituiscono**: puntata minima 1, Carletti doppio innesco attività/tempo del Banco, 15 minuti di bancarotta, esito riservato al creatore entro 10 minuti, limite fisso Live 20 minuti come unica scorciatoia, e possibilità di più puntate per squadra/mercato. Non riportare questi comportamenti nel codice.

## 1. Visione, contesto e pilastri [APPROVATO]

MazzoBet è una web app mobile-first per le **24 squadre del Fanta Mazzocchetto**: si creano scommesse binarie **SÌ/NO** su fatti verificabili durante una cena/premiazione, anche da remoto, usando soltanto **Carletti** virtuali (**[v0.9]** scritti per esteso, senza simbolo: «1.000 Carletti», «1 Carletto»; nell'interfaccia si dice «scommessa», mai «mercato», con numero progressivo «Scommessa n. 42»). Il gioco dura una serata, eventualmente due. Nessun denaro reale, deposito, prelievo, conversione o premio monetario.

Tre pilastri non negoziabili:

1. **Immediatezza:** entrare e puntare in pochi tocchi; la cena rimane protagonista. Niente host operativo, moderazione ordinaria o onboarding pesante.
2. **Aspetto da betting app:** UI credibile e compatta, dark, ispirata a sportsbook e alla chiarezza dei mercati SÌ/NO di Polymarket; non un party game infantile.
3. **Il Banco fa da padrone:** personaggio narrativo automatizzato, ironico, capriccioso, a tratti crudele. Può regalare e sottrarre Carletti, influenzare la classifica e commentare la corsa. **Non è un chatbot** e non usa LLM in runtime.

L'app deve reggere anche alcune centinaia di mercati (scenario estremo: circa 500), senza richiedere attenzione continua.

## 2. Squadre, accesso e identità

### Squadre ufficiali [APPROVATO]

1. Parallelo24
2. Saunier Duval
3. Team Sbornia Cycling
4. VeloClub Mosciano
5. Team Pomanti
6. S.C. Colleranesco
7. Rabobank
8. Vini la vespa e l’uva
9. I Cosacchi
10. Nerito Team
11. Us Postal Service
12. Team Patxi
13. Annateresa
14. Team Sbronzi
15. Tubateam
16. Pennello Cinghiale
17. Della Rovere Pro Cycling
18. Sanfelice 2023
19. Gli Scalatori
20. Fave Marchisio
21. Mercatone Uno
22. Team Festina con la droga
23. Subaru B. Cycling Team
24. Pianograndecc

### Accesso [APPROVATO]

Link condiviso → scelta della squadra → Home, con **1.000 Carletti iniziali** al primo ingresso di quella squadra. Nessun PIN, password, email o registrazione. La scelta persiste sul dispositivo. Una squadra diventa **in gara** al suo primo accesso e da allora è eleggibile per gli eventi del Banco; le squadre mai entrate non ricevono bonus né malus.

- Se la squadra risulta associata anche a un altro dispositivo, mostrare **«Stai entrando come X»** con conferma e tono del Banco, senza impedire l'accesso. **[PROVVISORIO]**
- Assegnare un token di sessione al dispositivo e registrare gli accessi concorrenti. **[TECNICO PROPOSTO]**
- Il rischio di impersonificazione o accessi multipli alla stessa squadra è **accettato** come rischio sociale; la conferma non è autenticazione e non va presentata come tale. **[APPROVATO]**
- **[v0.8 — APPROVATO]** «Cambia squadra» **non** è in Home: sta in fondo alla tab **Scommesse**, con conferma, per scoraggiare uscite e rientri ripetuti durante la serata. Il saldo resta legato alla squadra, non al dispositivo. A serata chiusa chi esce non può rientrare (nessuna serata attiva).

Stati: **non entrata**, **in gara**, **in bancarotta**. La bancarotta non cancella la partecipazione e non impedisce di incassare puntate già piazzate.

## 3. Carletti, quote, wallet e conto del Banco

### Economia giocatore [APPROVATO]

- Saldo iniziale: **1.000 Carletti** per squadra.
- Creazione mercato: **100 Carletti** addebitati e non rimborsati anche se il mercato è annullato per mancato esito.
- Puntata minima **10 Carletti**; massima **intero saldo disponibile**, senza cap aggiuntivo.
- Quote fisse SÌ e NO scelte dal creatore, **da 1.10 a 10.00**, con **due decimali**; memorizzarle come interi in centesimi (es. 1.80 → 180).
- Vincita totale accreditata: **`floor(puntata × quota)`** in Carletti interi, con calcolo esatto su interi (`floor(stake * odds_cents / 100)`). Esempio: 10 Carletti a 1.10 → accredito 11. Carletti
- **Nessuna commissione** sui pagamenti delle vincite.
- Le puntate vengono addebitate al momento della conferma; il saldo mostrato è quello disponibile. Le vincite accreditano l'intero payout, comprensivo della puntata originaria.
- Il Banco **non ha limiti di solvibilità**: i pagamenti sono sempre possibili, anche se il conto del Banco è negativo.

### Cassa del Banco [APPROVATO come concetto; visualizzazione PROVVISORIA]

Il Banco ha un **conto di gioco informativo**, ricostruibile dal ledger come controparte delle movimentazioni. Non rappresenta un budget che limita gli interventi.

| Entrate della cassa | Uscite della cassa |
| --- | --- |
| Puntate, 100 Carletti per mercato, malus, collette | Vincite, bonus, riammissioni a 500, Carletti rimborsi di puntate annullate |

Mostrare due righe: **«Cassa del Banco»** (comprende le puntate in corso) e **«di cui puntate in corso»** per chiarire la composizione. **[PROVVISORIO]**

**[TECNICO PROPOSTO]** Ledger immutabile a importi interi, con `transaction_id`, `idempotency_key`, causale, squadra, mercato/evento, conto controparte, importo e timestamp. Saldi e cassa aggiornati atomicamente, mai modificabili dal client. Definire contabilmente le sponsorizzazioni come finanziamento del conto Banco, distinto dai Carletti accreditati alle squadre.

## 4. Navigazione e design [APPROVATO]

**Quattro tab inferiori:** **Home**, **Classifiche**, **Scommesse**, **RadioCorsa**.

Home, nell'ordine: logo e saldo; banner RadioCorsa con ultime 3–4 notizie in rotazione; grande CTA lime **CREA UNA SCOMMESSA**; sezione **Live Betting** con mercati aperti. Banner e CTA scorrono via con la pagina; bottom navigation fissa.

**Stile iniziale [PROVVISORIO]:** fondo `#101714`, card `#1D2922`, accento lime `#D9FF82`, testo bianco, secondari verde-grigio. Numeri delle quote grandi, leggibilità elevata, uso con una mano.

**Card mercato:** domanda, autore, countdown/scadenza, quote SÌ/NO cliccabili, barra con percentuali della **somma puntata** sui due lati (non probabilità, né nomi degli scommettitori). Barra neutra senza puntate. Distinguere i mercati a scadenza breve e quelli più lunghi, senza aggiungere filtri complessi non necessari. **[v0.8 — APPROVATO]** Bollino **«LIVE»** per i mercati con durata di **30 minuti o meno**, **«A SCADENZA»** per gli altri (soglia provvisoria). Il countdown è in evidenza con l'etichetta «CHIUDE TRA»; l'orario di chiusura compare sulla riga dell'autore («Chiude alle 00:51»), non attaccato al countdown. La sezione della Home si chiama «Live betting».

## 5. Creazione mercato [APPROVATO]

Ogni squadra in gara, con almeno 100 Carletti disponibili, può creare senza approvazione un mercato su evento SÌ/NO verificabile. Form minimale: **domanda, quota SÌ, quota NO, scadenza, pubblica per 100 Carletti**. Creatore escluso dalle puntate sul proprio mercato; quote immutabili.

**Scadenza:** scorciatoie **LIVE 20 MIN** (preselezionata), **+30 min**, **+1 h**, **+2 h**, oppure **orario personalizzato**. **[v0.8 — APPROVATO]** Il «LIVE 20 MIN» del prototipo è **reintrodotto** come scorciatoia rapida (la v0.6/v0.7 lo avevano eliminato): non è però l'unica né obbligatoria, e le scadenze libere restano valide. Il backend valida che la scadenza sia futura e non oltre la **fine serata configurata**, default **03:00 nel fuso `Europe/Rome`**. La data effettiva va risolta correttamente se si attraversa mezzanotte.

**Controllo sul margine delle quote [v0.9 — APPROVATO]:** alla pubblicazione, con A e B quote in centesimi, la scommessa è ammessa solo se `100 × (A + B) ≥ A × B` (equivale a 1/qSÌ + 1/qNO ≥ 1). Blocca le quote «regalo» come 5,00 e 5,00; (2,00 e 2,00) e (1,10 e 10,00) sono ammesse, (2,50 e 2,50) è bloccata.

**ESITA ORA [v0.9: in un solo passo]:** il creatore, finché la scommessa è aperta, sceglie **SÌ o NO** e chiude subito: l'azione chiude immediatamente nuove puntate, registra l'esito e apre **subito** i 3 minuti di contestazione, con pagamenti immediati.

**Compenso di chi esita [v0.9 — APPROVATO]:** vedi §7. Nel pannello di creazione una riga ricorda: «Se esiti tu la scommessa ricevi il 10% delle puntate (max 250 Carletti). Se la esita un altro, non ricevi nulla.»

**[PROVVISORIO]** Si accetta il rischio sociale di puntate piazzate quando l'evento è già accaduto ma il risultato non è ancora stato registrato; contestazioni e buon senso sono le mitigazioni previste. Mostrare un richiamo brevissimo alla verificabilità della domanda.

## 6. Puntate [APPROVATO]

Tap su quota SÌ/NO → bottom sheet → importo rapido (25 / 50 / 100 / 250), personalizzato o **TUTTI I CARLETTI** (**[v0.9]** nuovo nome del tasto MAX) → payout potenziale → conferma → addebito atomico. Minimo 10 Carletti, massimo il saldo disponibile.

**Una sola puntata per squadra per mercato, su un solo lato**, irrevocabile e non modificabile. Vincolo di unicità database **`(game_session_id, team_id, market_id)`** (o equivalente). Il creatore non può puntare sul proprio mercato. Nessun **cash-out** nella V1.

Conferma server valida: squadra in gara e non bloccata, saldo, mercato ancora aperto, quote congelate, unicità puntata e importo. Doppio tap e retry non devono creare due addebiti.

## 7. Chiusura, esito e ricorsi

### Esito ordinario [APPROVATO — v0.9: precedenza del creatore]

Sia **T** la scadenza (per ESITA ORA, T è il momento in cui il creatore preme il pulsante). Alla scadenza la scommessa non accetta più puntate e passa a **Da esitare**:

| Momento | Chi può esitare |
| --- | --- |
| Prima di T | Solo il creatore, con ESITA ORA |
| Da T a T + 2 minuti | **Solo il creatore** (precedenza) |
| Da T + 2 a T + 17 minuti | Il creatore **e qualsiasi squadra in gara che non abbia puntato**; chi ha puntato è escluso. **La prima risposta valida vince.** |
| T + 17 minuti, nessun esito | **Annullamento**: tutte le puntate rimborsate, nessun compenso, i 100 Carletti di creazione non tornano |

Le squadre in bancarotta possono esitare e incassare come le altre. Un esito registrato all'ultimo secondo vale e la contestazione prosegue oltre T + 17.

**Scommessa senza puntate [v0.9]:** alla scadenza si chiude come «senza puntate», senza schermata di esito, contestazione né annullamento. I 100 Carletti di creazione restano spesi.

Il tab Scommesse segnala con badge gli esiti disponibili, e la sezione **«Da esitare»** è visibile alle squadre che non hanno puntato **solo da T + 2 minuti**; ogni scheda mostra «Esita per X Carletti» (nascosto se X vale 0). La schermata obbligatoria **«ESITA LA SCOMMESSA!»** rimane soltanto per il creatore delle proprie scommesse con puntate, con la riga «Esita ora e incassi C Carletti»; più scommesse da esitare si presentano in sequenza. **[PROVVISORIO]** Per gli altri esitatori l'azione è volontaria.

Se qualcuno esita: **pagamento immediato** dei vincitori, nessuna commissione sulle vincite.

### Compenso di chi esita [APPROVATO v0.9]

Calcolato sul totale puntato (entrambi i lati) quando le puntate sono chiuse: `C = min( floor(totale × 10 / 100), 250 )`. Se esita il **creatore** incassa **C**; se esita **un'altra squadra** incassa `floor(C / 2)` e il creatore non incassa nulla. Pagamento **a fine contestazione (3 minuti dopo l'esito) e solo se l'esito non è stato ribaltato**; pagato dal Banco, una sola voce di ledger «compenso esito» per scommessa. Esempi: totale 3.450 → C = 250 (altro: 125); totale 905 → C = 90 (altro: 45); totale 15 → C = 1 (altro: 0, niente «Esita per»). Annullata o ribaltata → nessun compenso. Il tab Scommesse mostra al creatore il compenso potenziale mentre la scommessa è aperta e quello ricevuto a esito chiuso.

### Esito anticipato [APPROVATO]

Con **ESITA ORA** il creatore chiude e risolve subito la scommessa **in un solo passo** (sceglie SÌ o NO), senza attendere la scadenza programmata; i **3 minuti di ricorso decorrono dall'esito anticipato**. La finestra ordinaria di esito non si apre. **[TECNICO PROPOSTO]** Registrare distintamente `scheduled_close_at`, `actual_closed_at`, `resolved_at` e `appeal_deadline_at`.

### Ricorsi [APPROVATO]

- Finestra di **3 minuti dall'esito**.
- Possono contestare **tutte e soltanto le squadre che hanno puntato**, vincenti o perdenti.
- Soglia: **maggioranza assoluta dei distinti scommettitori** `floor(N/2)+1`; nessuna soglia minima di partecipazione. Con un solo scommettitore basta un ricorso.
- Contatore e soglia non visibili; pulsante discreto nel mercato concluso.
- Raggiunta la soglia, esito **ribaltato automaticamente una sola volta**, senza secondo ricorso; altrimenti definitivo dopo tre minuti.
- Il Banco annuncia la decisione con tono da giuria, senza fingere che sia intervenuto davvero un revisore umano.

**Rettifica netta [APPROVATO]:** per ogni scommettitore registrare **un solo movimento** pari a `payout_nuovo − payout_vecchio`; applicarlo atomicamente e in modo idempotente. Il saldo può diventare negativo se una vincita già spesa viene rettificata. Aggiornare i pronostici corretti sull'esito finale. Nessuna doppia erogazione.

**[APERTO]** L'esitatore non scommettitore può favorire un amico; il ricorso è l'unica tutela prevista. Valutare il rischio nella prova generale, senza introdurre ora un moderatore.

## 8. Bancarotta e riammissione [APPROVATO]

- **Saldo < 10 Carletti E nessuna puntata ancora da risolvere** → bancarotta automatica, anche se il saldo è positivo (es. 7 Carletti). **[v0.9 — APPROVATO]** Chi punta tutto (saldo 0) **non** fallisce finché la scommessa è in corso; quando l'ultima puntata si risolve e il saldo è ancora sotto 10, la bancarotta scatta in quel momento (e con lei la colletta). Una squadra con saldo basso ma puntate in corso non può puntare né creare, ma non è «in bancarotta». In bancarotta la squadra non può puntare né creare scommesse.
- **Blocco 5 minuti** dall'ingresso in bancarotta. Puntate pregresse, esiti e rettifiche continuano a funzionare.
- Se il saldo torna a **≥ 10 Carletti** in qualsiasi momento, anche prima dei cinque minuti, la squadra rientra automaticamente **senza** riammissione e senza incrementarne il contatore.
- Trascorsi cinque minuti, se ancora in bancarotta, può premere **RICHIEDI RIAMMISSIONE**: debito azzerato e **saldo impostato a 500 Carletti**, contatore riammissioni +1.
- La riammissione **non** provoca una colletta: la colletta parte **all'ingresso in bancarotta**.
- Il conto del Banco registra l'uscita necessaria per la riammissione, ma il Banco non ha vincoli di disponibilità.

Le squadre in bancarotta rimangono «in gara» per la sessione. I malus ordinari le escludono (§9.1), mentre **la pioggia sponsor le include** (§9.3).

## 9. Il Banco: interventi, colletta, sponsor

### Personalità e catalogo [APPROVATO]

Il Banco è il padrone della corsa: personaggio automatizzato, beffardo e imprevedibile. Eventi narrativi ciclistici, con riferimenti a fughe, ammiraglie, premi di tappa, sponsor, controlli antidoping, maglia nera e al gestore **Bila** che chiede quote per la prossima stagione. Gli eventi **non richiedono memoria di precedenti sponsor**: una «fuga dello sponsor» è una nuova sanzione narrativa, non la restituzione di un accredito mai ricevuto.

### 9.1 Ciclo ordinario [APPROVATO]

**Eliminato integralmente il precedente sistema a punti attività.** Il Banco ordinario usa **solo un timer casuale**, indipendente da mercati, puntate e riammissioni.

| Parametro | V1 |
| --- | --- |
| Innesco | Solo timer casuale |
| Intervallo | **8–14 minuti**, estratto a ogni ciclo |
| Avvio | All'ingresso della **quinta** squadra |
| Ripartenza | Dopo ogni intervento, nuovo ciclo senza code |
| Destinatari | **1–3 squadre** estratte tra quelle in gara |
| Importo | **Unico per evento** (uguale per tutti i destinatari), estratto fra **100 e 250 Carletti**, **in multipli di 10** (v0.9) |
| Tipo | **55% bonus / 45% malus** |
| Malus | Escludono squadre con saldo **< 10 Carletti** |
| Nessun eleggibile al malus | Convertire l'evento in **bonus** |

La selezione concreta di squadre e importi deve essere riproducibile nel log. I valori sono approvati come **regole iniziali**; la loro invasività si valuta nella prova generale. Il Banco continua lato server anche senza browser aperti.

### 9.2 Colletta per il gregario caduto [APPROVATO salvo principio di taratura PROVVISORIO]

**Ogni nuovo ingresso in bancarotta** avvia una **catena di collette**, separata dal timer ordinario. La riammissione non avvia collette.

- Primo giro: **25 Carletti** prelevati a ogni squadra **in gara, non in bancarotta, con saldo ≥ 10 Carletti**. Chi è già in bancarotta non paga e non riceve nulla.
- Se più squadre falliscono **nello stesso giro**, si effettua **un solo prelievo per squadra pagante** per quel giro, non uno per fallimento.
- Chi, a causa del prelievo, scende sotto 10 Carletti entra in bancarotta e **innesca un giro successivo** sui paganti rimasti.
- La cascata continua **senza limite prefissato di giri** fino a quando non ci sono nuovi fallimenti.
- **Valvola:** ogni giro si effettua soltanto se ci sono **almeno 3 paganti**; altrimenti la catena termina.
- Una sola notizia RadioCorsa per l'intera catena, in stile **Almanacco del Banco**, con primo caduto e nomi dei successivi.
- **[TECNICO PROPOSTO]** Un'unica transazione serializzata con identificativo di catena, giri registrati, lock e idempotenza. Ogni squadra può entrare in bancarotta una sola volta all'interno della stessa catena; i paganti diminuiscono, quindi la catena termina.

La colletta è un **prelievo destinato al conto Banco**, non una redistribuzione diretta ai falliti; il saldo di riammissione 500 Carletti viene erogato successivamente dal Banco. **[TECNICO PROPOSTO: esplicitazione contabile coerente con §3 e §8]**

**[APERTO]** L'effetto valanga può coinvolgere molte squadre con saldi bassi; la valvola dei tre paganti non limita il numero complessivo di bancarotte. Va misurato prima di aggiungere ulteriori protezioni.

### 9.3 Sponsor del Banco e pioggia di Carletti [APPROVATO — sostituisce integralmente v0.6]

Lo sponsor è un evento autonomo, **indipendente dal saldo del Banco**. Non esiste più la soglia di cassa negativa, né cooldown o tetto di 2–3 sponsor per serata.

| Parametro | Regola V1 |
| --- | --- |
| Avvio scheduler sponsor | Al primo ingresso della **quinta squadra** nella sessione |
| Frequenza | Intervallo casuale **8–45 minuti**, estratto dopo ciascun evento |
| Relazione col Banco ordinario | Timer indipendenti; eventi ravvicinati ammessi, nessun reset reciproco |
| Scelta sponsor | Casuale tra le **8 voci** della sezione `sponsor` del catalogo editoriale v0.2 |
| Squadre conteggiate `N` | Tutte le squadre che hanno effettuato almeno un accesso, **incluse quelle in bancarotta** |
| Contributo sponsor alla cassa | `2.000 Carletti + (150 Carletti × N) + max(0, −C)` dove `C` è la cassa Banco immediatamente prima dell'evento |
| Pioggia | **150 Carletti per ciascuna delle N squadre**, incluse le bancarottate |
| Esecuzione | Contributo sponsor e pioggia nella **stessa transazione atomica** |
| Comunicazione | Evento sponsor in Almanacco/RadioCorsa, con titolo, testo cassa e testo pioggia dal catalogo |

**Verifica contabile:** la variazione netta della cassa è `contributoSponsor − 150 × N`. Quindi, se `C < 0`, il saldo finale della cassa è esattamente **2.000 Carletti**; se `C ≥ 0`, il saldo finale è `C + 2.000 Carletti`. Il Banco resta illimitato anche fra due sponsorizzazioni.

La pioggia può far uscire automaticamente dalla bancarotta una squadra che torna a saldo ≥ 10, Carletti senza riammissione e senza relativo contatore. **[TECNICO PROPOSTO]** Serializzare sponsor e tutte le operazioni economiche sullo stesso ledger, usare identificativo univoco per evento e scadenze persistenti recuperabili dopo riavvio, senza doppie esecuzioni. Il motore calcola gli importi; il JSON fornisce esclusivamente il testo.

## 10. RadioCorsa, Almanacco e notifiche live

RadioCorsa **non** racconta ogni puntata: raccoglie gli interventi economici del Banco, sponsor/piogge, catene di colletta, bancarotte, riammissioni, ribaltamenti e altri eventi editoriali previsti. Un intervento economico produce sempre una registrazione leggibile; evitare doppioni di comunicati per un'unica catena/operazione.

**[v0.9 — APPROVATO]** Comunicati aggiunti: **cassa in rosso** e **cassa in attivo** (quando la cassa del Banco passa sotto zero e quando torna sopra, valutati a fine operazione) e **grande vincita** (vincita ≥ 500 Carletti, un comunicato per scommessa, riferito alla vincita più alta; le puntate normali non generano comunicati). Un testo del catalogo **non si ripete nella stessa serata** finché ce ne sono di nuovi per quel tipo di evento. Il registro di ogni intervento del Banco conserva ora anche i saldi risultanti dei destinatari.

- **Home:** banner con ultime **3–4 notizie** a rotazione; tap apre il tab RadioCorsa.
- **RadioCorsa:** feed cronologico persistente, con due registri editoriali: avviso breve e **Almanacco del Banco** per proclami solenni.
- **Notifiche live in-app [PROVVISORIO da provare su smartphone]:** toast/banner temporaneo in alto per nuovi eventi, non bloccante, non copre la conferma delle puntate; resta comunque nel feed. Eventi speciali possono avere una resa più evidente, senza bloccare il gioco.
- **Eccezione importante:** la schermata **«ESITA LA SCOMMESSA!»** per il creatore è **obbligatoria e bloccante**; non è una notifica RadioCorsa. Gestire più mercati da esitare in coda e liberare l'interfaccia quando scadono o sono risolti.
- Nessuna generazione LLM in runtime: si usa **`catalogo_banco_v02.json`**, separato dal codice economico.
- Le notizie pubblicate salvano **titolo e testo già renderizzati** nel database, così future modifiche al catalogo non alterano la cronologia.

### 10.1 Catalogo editoriale v0.2 [APPROVATO]

Il file allegato `catalogo_banco_v02.json` è la fonte dei testi. **64 voci:** 24 bonus, 18 malus, 8 sponsor, 14 RadioCorsa. Il motore seleziona la voce coerente col tipo di evento; il catalogo non decide importi, probabilità, destinatari o movimenti economici.

Struttura: `versione`, `nota`, `variabili`, `bonus[]`, `malus[]`, `sponsor[]`, `radiocorsa[]`. Bonus e malus hanno `id`, `evento`, `titolo`, `testo`; sponsor hanno `id`, `nome`, `titolo`, `testoCassa`, `testoPioggia`; RadioCorsa ha propri identificativi/tipi e testi. Conservare i segnaposto, tra cui `{nomeSquadre}`, `{nomeSquadra}`, `{importo}`, `{numeroScommessa}`, `{nomeSponsor}`, `{importoSponsor}`, `{numeroSquadre}`, `{importoPerSquadra}`, `{elencoCaduti}`.

**Correzione v0.7:** `{numeroSquadre}` significa *tutte le squadre entrate almeno una volta, comprese quelle in bancarotta*. L'eventuale testo di colletta deve riflettere solo i **paganti effettivi**, non genericamente tutti i non falliti: minimo 3 paganti, con catene a giri.

**Validazione obbligatoria:** JSON valido, ID univoci, campi richiesti, eventi riconosciuti, testi non vuoti, segnaposto consentiti, escaping sicuro in UI. Se manca un template adatto, fallback testuale deterministico; mai bloccare una transazione economica per un errore editoriale. Il catalogo può essere ampliato senza modificare il motore.

## 11. Classifiche e statistiche

- **Classifica patrimonio** in Carletti; **spareggio**: più pronostici corretti. **[APPROVATO]**
- **Classifica pronostici corretti**: al massimo **uno per mercato** per squadra, coerentemente con l'unica puntata consentita. I mercati annullati sono esclusi. Vale sempre l'**esito definitivo** dopo l'eventuale ribaltamento. **[APPROVATO]**
- Conteggi di **bancarotte** e **riammissioni**. **[APPROVATO]**
- Statistiche Banco: **«Cassa del Banco»** e **«di cui puntate in corso»**, calcolate dal ledger, solo informative. **[PROVVISORIO]**
- **[APERTO]** Spareggio ulteriore per parità sia di patrimonio sia di pronostici, ordine squadre non entrate, visibilità dei saldi negativi.

## 12. Flussi utente principali

**A — Ingresso:** link → squadra → eventuale avviso di doppio dispositivo → primo ingresso 1.000 Carletti → Home → eleggibilità Banco; il timer parte quando entra la quinta squadra.

**B — Puntata:** mercato → quota → importo ≥10 Carletti → conferma → una puntata unica → saldo aggiornato → pagamento immediato se vincente → eventuale rettifica netta entro i tre minuti di ricorso.

**C — Creazione:** CTA → domanda → quote 1.10–10.00 → scadenza +30m/+1h/+2h/custom → addebito 100 Carletti → mercato visibile → chiusura programmata o ESITA ORA → esito da soggetto abilitato entro 15 minuti (oppure immediato dal creatore) → ricorso.

**D — Banco:** quinta squadra → timer 8–14m → evento 55/45 → 1–3 destinatari → ledger → controllo bancarotte e eventuale colletta → comunicato → nuovo timer.

**E — Bancarotta:** saldo <10 Carletti → bancarotta e colletta immediata → 5m blocco → eventuale recupero a ≥10 Carletti oppure riammissione a 500 Carletti su richiesta → nessuna nuova colletta per la riammissione.

**F — Sponsor:** timer indipendente 8–45m dalla quinta squadra → contributo sponsor calcolato sulla cassa → pioggia simultanea di 150 Carletti a ogni squadra entrata, anche fallita → ledger atomico e RadioCorsa.

## 13. Architettura, deployment e operazioni

### Infrastruttura [APPROVATO]

- **Supabase Cloud**: PostgreSQL e, quando utile, realtime. Non self-hosted.
- **VPS personale**: frontend, backend e worker/timer Banco.
- **Caddy** già disponibile: HTTPS e reverse proxy.
- **GitHub**: repository, Codex → commit/push → `git pull` e deploy da terminale VPS.

### Stack [TECNICO PROPOSTO]

Frontend **React + Vite + TypeScript**; backend **Node.js + TypeScript**; **un'istanza** applicativa per V1; database Supabase Cloud. Nessun microservizio o orchestrazione complessa.

### Invarianti tecniche obbligatorie

1. **Server autoritativo** per saldo, quote, puntate, esiti, destinatari Banco, orari.
2. **Atomicità e serializzazione** delle modifiche economiche: creazione, puntata, esito, ricorso, colletta a cascata, bonus/malus, sponsor, riammissione.
3. **Idempotenza** su doppio tap, retry, riavvio, timeout e worker concorrenti.
4. **Una puntata per squadra/mercato** garantita da vincolo database.
5. **Ledger con controparte Banco** per ogni movimento economico, e voci sponsor distinguibili.
6. **Timer persistenti**: scadenze mercati, 15m esito, 3m ricorso, 5m bancarotta, 8–14m Banco, 1–2m pioggia. Recupero corretto dopo riavvio.
7. **Chiavi privilegiate solo server**; policy Supabase rigorose, validazione input, rate limit leggero, log accessi e sessioni.
8. **Realtime con fallback** a refresh/polling; l'app resta fruibile anche dopo una disconnessione.
9. **Separazione test/produzione** di database, configurazioni e dati.
10. **[v0.9] Parametri di gioco in configurazione:** tutti i numeri (costo di creazione, puntata minima, finestre di esito/ricorso/bancarotta, precedenza del creatore, compenso, Banco, colletta, sponsor, pioggia, soglia grande vincita) stanno in una tabella `mazzobet.config` letta dalle funzioni, non nel codice; il client riceve quelli che gli servono insieme allo stato. Il fattore di velocità `time_scale` (solo simulazioni, default 1) scala le durate.

### Fine serata [APPROVATO v0.8]

**Niente pannello admin V1.** Le operazioni manuali si fanno su Supabase con **snippet SQL transazionali e idempotenti** (cartella `server/db/ops/`), che chiamano funzioni dello schema `mazzobet` non raggiungibili dall'API:

- **Pausa del Banco:** ferma **sia** gli interventi ordinari **sia** gli sponsor. Gioco, puntate, esiti e ricorsi continuano. Alla ripresa partono due nuovi intervalli casuali, senza recuperare gli eventi persi.
- **Chiusura serata «lascia finire tutto», in due tempi:**
  1. **In chiusura:** nessuna nuova puntata né creazione di scommesse (vincolo anche a livello database); Banco e sponsor fermi. I mercati aperti arrivano alla scadenza; esiti e ricorsi in corso si concludono normalmente; i mercati senza esito entro 15 minuti sono annullati e rimborsati (i 100 Carletti di creazione non sono restituiti).
  2. **Chiusa:** appena non resta nulla di pendente (nessun mercato aperto o in attesa di esito, nessuna finestra di ricorso aperta) la serata si congela da sola: la classifica finale è salvata in modo immutabile e l'app diventa in **sola lettura** con l'avviso «Serata chiusa».
- **Chiusura forzata (emergenza):** annulla e rimborsa subito i mercati pendenti e congela, senza attendere le finestre di ricorso.
- **Nuova serata:** snippet dedicato; una sola serata attiva alla volta.

Risolta la regola di precedenza: gli esiti già pubblicati e i loro ricorsi aperti **vengono rispettati**; i mercati non esitati vengono rimborsati.

## 14. Modello dati concettuale [TECNICO PROPOSTO]

- `game_sessions`: stato, avvio, fine serata, fuso, configurazioni.
- `teams`: nomi ufficiali, primo ingresso, stato, saldo, statistiche.
- `team_sessions`: token dispositivo, associazione squadra, ultimo accesso, log multi-dispositivo.
- `markets`: creatore, domanda, quote intere, scadenza, chiusura effettiva, stato, esito, scadenza ricorso.
- `bets`: mercato, squadra, lato, importo, quota congelata, payout, unicità.
- `appeals`: una contestazione per squadra/mercato, timestamp.
- `ledger_transactions` / `ledger_entries`: movimento atomico, controparti, importi interi, causale, idempotency key.
- `bank_cycles`: avvio alla quinta squadra, timer estratto, ultimo intervento, stato.
- `bank_events`: tipo, destinatari, importo, timer, correlazione ledger, causale.
- `bankruptcy_events` / `collection_chains` / `collection_rounds`: ingressi in bancarotta, catene, giri e paganti.
- `sponsor_events`: sponsor scelto, timer programmato, saldo cassa prima dell’evento, N squadre entrate, importo ricapitalizzazione, pioggia, idempotenza ed esecuzione.
- `news`: messaggi RadioCorsa/Almanacco, tipologia, evento collegato.

Schema esatto e naming da decidere in sviluppo, preservando gli invarianti.

## 15. UX, prestazioni e accessibilità

- Mobile-first, una mano, pochi tap, caricamento rapido, quote leggibili, importi chiari.
- Distinguere **saldo disponibile** e **puntate in corso**, senza rendere il wallet complesso.
- Messaggi d'errore chiari: puntata già effettuata, saldo insufficiente, mercato chiuso, quota non valida, sessione terminata.
- Stati chiari per **Da esitare**, **In contestazione**, **Definitivo**, **Annullato**.
- Il creatore vede il richiamo obbligatorio per i propri esiti; gli altri eleggibili vedono badge discreto.
- Il Banco non interrompe ogni attività con pop-up. RadioCorsa serve a spiegare gli interventi che incidono sui patrimoni.
- Nessuna geolocalizzazione; stessa esperienza per partecipanti presenti e remoti.
- Accessibilità: contrasti, touch target, etichette non affidate soltanto al colore.

## 16. Perimetro V1

### Incluso

Accesso squadra senza PIN; sessione persistente; 24 squadre; wallet/ledger; quattro tab; mercati SÌ/NO a quote fisse e scadenza configurabile; una puntata per mercato; ESITA ORA; esito da non scommettitori entro 15m; ricorso 3m e rettifica netta; bancarotta 5m; riammissione 500 Carletti; colletta a cascata; Banco ordinario 8–14m; sponsor/cassa/pioggia; RadioCorsa/Almanacco; statistiche; deploy VPS/Caddy/Supabase Cloud; log e test.

### Escluso

Denaro reale; PIN/account/password; app native; GPS; LLM runtime; quote dinamiche; cash-out; approvazione umana ordinaria; pannello admin completo; microservizi; sistema di punti attività Banco; bonus con contratti sponsor persistenti.

## 17. Rischi e decisioni residue — priorità

### Da chiarire prima o all'inizio dello sviluppo

1. **[RISOLTO v0.8] Chiusura della sessione e stati pendenti.** Si rispettano esiti già pubblicati e ricorsi aperti; i mercati non esitati sono annullati e rimborsati; poi la classifica si congela (vedi §13).
2. **[APERTO] Esiti da terzi.** Un non scommettitore può esitare in malafede; i ricorsi potrebbero non raggiungere la maggioranza anche se l'esito è falso. Accettare esplicitamente la mitigazione soltanto sociale o definire un minimo rimedio.
3. **[APERTO] Identità multi-dispositivo.** Confermare UX di avviso e definire quale dispositivo può dichiarare esiti o spendere per la stessa squadra. La v0.6 accetta il rischio, ma le azioni devono essere registrabili e serializzate.
4. **[RISOLTO v0.7] Pioggia sponsor.** Sempre 150 Carletti per ogni squadra entrata, comprese le bancarottate; timer autonomo 8–45 minuti, nessuna soglia/cooldown/cap.
5. **[RISOLTO v0.7] Saldo cassa e sponsor.** La cassa include le puntate in corso; lo sponsor è a timer e non ha trigger di soglia.
6. **[RISOLTO v0.8 per l'aggregazione; APERTO per l'impatto] Bancarotte simultanee e collette.** Implementato: tutte le azioni economiche di una serata sono serializzate; i fallimenti dello stesso giro generano un solo prelievo per squadra pagante; una sola notizia per catena. **Resta aperta** la decisione su puntata MAX e colletta (vedi punto 8 e Appendice D.4).
7. **[APERTO] Mercati già risolti nella realtà.** ESITA ORA è disponibile soltanto al creatore; chi punta dopo l'evento e prima dell'esito può approfittarne. Rischio sociale dichiarato provvisorio.

### Da misurare nella prova generale, non da sovraprogettare

8. **Colletta:** rischio di effetto valanga. **[MISURATO v0.8 — CRITICO; RISOLTO in v0.9]** Prima simulazione (24 squadre, 60 minuti): 41 catene, 71 bancarotte, 28.675 Carletti prelevati (più dei 24.000 iniziali), 23 squadre su 24 fallite; 37 bancarotte su 71 nascevano da una puntata che azzerava il saldo. Con la regola «bancarotta solo senza puntate in corso» la stessa simulazione dà **1 catena, 1 bancarotta, 500 Carletti prelevati**. Da riconfermare con altri seed e con persone vere.
9. **Banco:** frequenza reale ~4–7 interventi/ora a seconda dell'estrazione, più eventi straordinari; percezione d'invasività e squadre mai colpite.
10. **Sponsor:** quante ricapitalizzazioni, quanto la pioggia altera la classifica.
11. **Quote fino a 10.00:** se la classifica diventa una lotteria, rivalutare il tetto.
12. **RadioCorsa:** densità e qualità di 40–50 template, più 10 dedicati.
13. **Classifiche:** spareggi ulteriori, squadre non entrate, statistiche negative.
14. **Interventi ripetuti:** eventuale estrazione pesata per ridurre squadre mai colpite.

## 18. Piano di test e prova generale

### Test tecnici

- Puntate simultanee su una squadra e unicità `(squadra, mercato)`.
- Precisione delle quote intere e `floor` payout; 10 Carletti × 1.10 = 11. Carletti
- ESITA ORA contro puntata concorrente, scadenza e primo esito concorrente.
- Esito da non scommettitore e creator senza priorità; finestra 15m, annullamento/rimborso.
- Ricorso al limite dei 3m, soglia `floor(N/2)+1`, rettifica netta, saldi negativi.
- Bancarotta a saldo 9, Carletti recupero a 10, Carletti timer 5m, riammissione 500. Carletti
- Colletta con 1/2/3 paganti, fallimenti simultanei, più giri, idempotenza e arresto.
- Sponsor indipendente dal saldo: timer 8–45m, formula su cassa negativa/positiva, pioggia simultanea inclusi falliti, riavvio backend.
- Chiusura manuale, rimborsi e classifiche congelate.
- Riavvio worker e recupero timer senza duplicazioni.

### Simulazione carico/serata

**15–24 squadre simulate** con puntate casuali per **almeno 30 minuti**; integrare un test più lungo per vedere sponsor e catene. Misurare:

| Area | Misure |
| --- | --- |
| Banco ordinario | Interventi/ora (atteso circa 5–6), squadre mai colpite, bancarotte da malus |
| Colletta | Lunghezza media catene, falliti per catena, giri prima dello stop, Carletti sottratti |
| Sponsor | Frequenza timer 8–45m, correttezza formula, effetto pioggia anche sui falliti, andamento cassa |
| Esiti | Numero «Da esitare», tempo medio all'esito, annullamenti dopo 15m, ricorsi |
| UX | Tempo per puntare/creare, errori, lettura notizie, invasività percepita |

**Criterio di successo:** il Banco è memorabile e imprevedibile, ma non rende il gioco ingestibile né trasforma la cena in una sequenza di notifiche obbligatorie.

## 19. Prompt per revisione con altro LLM

> Analizza questo PRD v0.7 di MazzoBet, web app di scommesse **solo virtuali** per 24 squadre di una lega fantasy ciclistica. Non stravolgere il concept, non proporre denaro reale, account tradizionali, chatbot, admin complesso o nuove meccaniche decorative. Rispetta i tre pilastri: immediatezza, estetica betting app, Banco narrativo capriccioso. Distingui: (1) bug o contraddizioni bloccanti, (2) casi limite economici/temporali, (3) rischi UX e sociali, (4) piccoli miglioramenti coerenti con V1. Per ogni problema indica scenario riproducibile, gravità, correzione minima e se serve una decisione del product owner. Concentrati su ESITA ORA vs esito ordinario, ricorsi e rettifiche, colletta a cascata e bancarotte simultanee, sponsor/ledger, timer persistenti, identità senza PIN e chiusura sessione. **Non cambiare regole marcate APPROVATO senza motivare il problema.** Concludi con le **cinque decisioni realmente necessarie prima di iniziare con Codex**, distinguendole dai parametri da testare.

---

> **Nota:** le appendici storiche riportano regole superate; prevalgono sempre i paragrafi normativi v0.7 e l’Appendice C.

## Appendice A — Delta storico v0.5 → v0.6 (non sostituisce le regole v0.7)

| Tema | v0.5 | v0.6 |
| --- | --- | --- |
| Puntate | Minimo 1, Carletti molteplicità aperta | **Minimo 10, Carletti una sola per squadra/mercato** |
| Quote | Range e rounding aperti | **1.10–10.00, 2 decimali, `floor`** |
| Scadenze | 20m Live o custom | **+30m/+1h/+2h/custom, max fine serata** |
| Esito | Solo creatore, 10m | **Creatore o non scommettitori, 15m; ESITA ORA** |
| Rettifica | Storno e nuovo pagamento | **Differenza netta, una voce per scommettitore** |
| Bancarotta | Saldo ≤0, 15m | **Saldo <10, Carletti 5m** |
| Banco ordinario | Punti attività + timer | **Solo timer 8–14m, da quinta squadra** |
| Colletta | Assente | **25 Carletti per pagante, cascata, min 3 paganti** |
| Sponsor | Bonus narrativi | **Ricapitalizzazione cassa + pioggia** |
| Cassa Banco | Fondi illimitati, nessuna cassa UI | **Conto informativo da ledger, non vincolante** |
| Admin | Nessuna console prevista | **Due snippet SQL per pausa e fine sessione** |

## Appendice B — Nota sulle interpretazioni tecniche

Questo PRD mantiene i comportamenti approvati nel documento di modifiche. Le precisazioni non espressamente decise (come la destinazione contabile della colletta, i timestamp distinti per ESITA ORA e la procedura transazionale di chiusura) sono indicate **[TECNICO PROPOSTO]** e vanno confermate durante la progettazione. Non sono nuovi vincoli di prodotto nascosti.


## Appendice C — Delta v0.6 → v0.7 e handoff a Claude Code

### C.1 Modifiche vincolanti

1. **Sponsor:** sostituito il vecchio trigger per cassa negativa con timer indipendente **8–45 minuti** avviato alla quinta squadra. Nessun tetto serale.
2. **Formula sponsor:** `2000 + 150*N + max(0, -C)`; pioggia **150*N** contestuale, inclusi falliti.
3. **Catalogo:** usare `catalogo_banco_v02.json` come sorgente dei testi; 64 voci; importi e probabilità esclusivamente nel motore.
4. **UX:** flussi di creazione/puntata e visualizzazione incasso del prototipo `MazzoBet.html` **validati**; non aggiungere complessità non richiesta.
5. **Esito:** schermata obbligatoria per il creatore **confermata**; altri non scommettitori possono esitare nella finestra di 15 minuti.
6. **RadioCorsa:** notifiche in-app live ancora da provare; banner/feed esistenti mantenuti.
7. **Scadenze:** le sole opzioni sono **+30m, +1h, +2h, custom**; l'opzione **LIVE 20 MIN presente nel prototipo va eliminata**. **[SUPERATO in v0.8: LIVE 20 MIN è stato reintrodotto come scorciatoia rapida, vedi §5.]**

### C.2 Ordine di implementazione raccomandato [TECNICO PROPOSTO]

**Fase 1 — Fondamenta:** repo, frontend React/Vite mobile-first, Node/TypeScript, Supabase Cloud, schema/seed 24 squadre, selezione squadra senza PIN e sessione persistente; ambiente test separato; Caddy e servizio VPS. Riutilizzare il prototipo come riferimento visuale, non copiarne la logica client-side come fonte autoritativa.

**Fase 2 — Economia e mercati:** ledger transazionale con Carletti interi, saldo e cassa derivabili; API idempotenti; creazione mercato 100, Carletti quote intere 110–1000, puntata unica minimo 10, Carletti blocchi concorrenti, scadenze e rimborsi.

**Fase 3 — Risultati:** esito creator/terzi, ESITA ORA, 15m, schermata obbligatoria, 3m di contestazione, ribaltamento e rettifiche nette, classifica coerente.

**Fase 4 — Banco:** bancarotta, riammissione 500, Carletti colletta a cascata, scheduler Banco 8–14m, scheduler sponsor 8–45m e formula v0.7; tutti i timer persistenti e recuperabili senza doppie esecuzioni.

**Fase 5 — Narrazione e prova generale:** import/validazione catalogo v0.2, messaggi persistiti, Supabase Realtime, toast live RadioCorsa, test con più dispositivi, chiusura serata e simulazione carico.

### C.3 Contratto minimo di qualità

- Tutti gli importi interi in Carletti, quote intere in centesimi; nessun saldo modificabile dal browser.
- Unicità `(team_id, market_id)` e chiavi di idempotenza per tutte le azioni economiche.
- Ogni operazione che modifica più wallet è atomica; ledger e saldo/cassa sempre riconciliabili.
- Server autorevole su scadenze e permessi; orario `Europe/Rome`, gestire cambio giorno/ora legale.
- Scheduler Banco e sponsor persistenti, avviati una sola volta al raggiungimento di 5 squadre; lock contro worker duplicati.
- I testi narrativi non possono cambiare retroattivamente e non determinano mai gli importi.
- Nessun account, PIN, denaro reale, cash-out, pannello admin complesso o nuove meccaniche fuori scope.

### C.4 Decisioni rimaste esplicitamente aperte

1. **Chiusura manuale della serata:** **[RISOLTO v0.8]** vedi §13: due tempi, ricorsi già aperti rispettati, mercati non esitati rimborsati, classifica congelata.
2. **Esito fraudolento da terzi:** resta un rischio sociale accettato provvisoriamente, mitigato soltanto dal ricorso degli scommettitori.
3. **Doppio dispositivo della stessa squadra:** avviso «Stai entrando come X», nessun blocco; token/log proposti, non autenticazione forte.
4. **Toast live RadioCorsa:** durata, sovrapposizione e priorità da validare su smartphone reale.
5. **Colletta a cascata:** preservare regole approvate e verificare simulazioni prima di introdurre protezioni aggiuntive.

**Regola per gli sviluppatori:** se una decisione non è descritta, proporre il minimo comportamento coerente e segnalarlo; **non inventare funzionalità** né recuperare regole obsolete da v0.5/v0.6 o dal prototipo HTML.

## Appendice D — Delta v0.7 → v0.8 e stato dell'implementazione (21 ottobre 2026)

### D.1 Stato per fase (rispetto a C.2)

| Fase | Stato |
| --- | --- |
| 1 — Fondamenta | **Fatta** per frontend, server, schema e seed 24 squadre, accesso senza PIN con token dispositivo. **Non fatti:** repository Git, ambiente di produzione separato, VPS/Caddy. |
| 2 — Economia e mercati | **Fatta.** Ledger a partita doppia, puntata unica, creazione 100, Carletti scadenze, rimborsi. |
| 3 — Risultati | **Fatta.** Esito creatore/terzi, ESITA ORA, 15', schermata obbligatoria, ricorso 3' con rettifica netta. |
| 4 — Banco | **Fatta.** Bancarotta, riammissione 500, Carletti colletta a cascata, Banco 8–14', sponsor 8–45', timer persistenti. **Impatto della colletta da decidere (D.4).** |
| 5 — Narrazione e prova generale | **Parziale.** Catalogo caricato e validato, notizie salvate già renderizzate, toast live (da provare su telefono). **Non fatti:** Supabase Realtime (oggi polling ogni 3 s), prova con più telefoni veri. Simulazione di carico fatta una volta (D.4). |
| Chiusura serata | **Fatta** (§13). |

### D.2 Modifiche normative rispetto alla v0.7

1. **LIVE 20 MIN reintrodotto** come scorciatoia rapida (preselezionata) in creazione; restano +30 min, +1 h, +2 h e orario libero (§5). Bollino «LIVE» per durata ≤ 30 min, «A SCADENZA» oltre (§4).
2. **«Cambia squadra»** spostato dalla Home al fondo della tab Scommesse, con conferma (§2).
3. **Card mercato:** countdown grande con «CHIUDE TRA»; orario di chiusura sulla riga dell'autore (§4).
4. **Chiusura serata in due tempi**, pausa che ferma Banco e sponsor, sola lettura a serata chiusa, classifica finale immutabile (§13).
5. **Nuove regole di dettaglio** che il PRD non fissava, ora decise (D.3).

### D.3 Interpretazioni adottate dove il PRD non era esplicito [da confermare]

- **Banco ordinario:** l'importo 100 Carletti–250 è **unico per evento** e uguale per tutte le squadre colpite. Il bonus può colpire anche squadre in bancarotta; il malus solo squadre con saldo ≥ 10 Carletti; senza squadre eleggibili al malus l'evento diventa bonus.
- **Malus senza tetto:** può portare il saldo sotto zero.
- **Colletta:** preleva sempre esattamente 25 Carletti anche a chi ha 10 Carletti–24 (saldo negativo possibile). Cascata senza limite di giri, si ferma con meno di 3 paganti; se i paganti sono meno di 3 già al primo giro non c'è alcun prelievo e la notizia è «bancarotta». La notizia «cascata» compare dal secondo giro in poi.
- **Ledger:** terzo conto «mint» per i 1.000 Carletti iniziali (fuori dalla «Cassa del Banco»); conto «sponsor» che finanzia la cassa distinto dai Carletti delle squadre.
- **Serializzazione:** ogni azione economica di una serata prende un lock per serata (evita deadlock nelle catene).
- **Timer:** colonne sulla serata; avviati alla quinta squadra; fattore di velocità `time_scale` (default 1) usato solo per le simulazioni.
- **Catalogo:** caricato nel database all'avvio del server dopo validazione (id univoci, campi presenti, segnaposto ammessi); se non valido resta quello già presente.
- **Eventi editoriali implementati:** bancarotta, colletta, colletta_cascata, riammissione, ricorso_accolto, mercato_annullato, più bonus, malus e sponsor.
- **Ricorso:** il pulsante sparisce dopo che la squadra ha già contestato; dopo il ribaltamento nessun altro ricorso.
- **Limite richieste** per dispositivo (150/minuto) e non per IP: a una cena i telefoni condividono lo stesso wifi.
- **Aggiornamento dell'app:** polling ogni 3 secondi + aggiornamento dopo ogni azione.

### D.4 Decisioni aperte dopo la simulazione (21/10/2026) — **[RISOLTO in v0.9: opzione A, vedi Appendice E]**

Simulazione: 24 squadre, 60 minuti di serata in 10 reali, un'esecuzione (dettagli in `MazzoBet_Report_Simulazione_60min.md`). **Tecnica:** nessun errore del server, conti sempre coerenti. **Criterio di successo del PRD non soddisfatto** per via della colletta.

| Metrica | Risultato |
| --- | --- |
| Catene di colletta | 41 (media 1,5 giri, max 4) |
| Bancarotte | 71 (23 squadre su 24 almeno una volta, 11 almeno tre) |
| Carletti prelevati | 28.675 Carletti (moneta iniziale: 24.000 Carletti) |
| Cause bancarotta | 38 puntata (37 con saldo azzerato da MAX), 29 colletta, 3 ricorso, 1 malus |
| Banco ordinario | 4,3 interventi/ora; 15 squadre su 24 mai colpite |
| Sponsor | 3 eventi, formula corretta; la ricapitalizzazione per cassa negativa non è mai servita |

**Decisione da prendere (priorità massima):** la combinazione «puntata massima = intero saldo» e «saldo < 10 Carletti = bancarotta immediata» fa scattare la colletta su tutte le squadre a ogni all-in, anche se la scommessa poi si vince. Opzioni:

- **A.** La bancarotta scatta solo con saldo < 10 Carletti **e nessuna puntata in corso** (coerente con «chi fallisce incassa le puntate già piazzate»).
- **B.** Una puntata non può far scendere il saldo sotto 10 Carletti (MAX lascia 10 Carletti).
- **C.** Si tiene la regola ma la colletta non parte se la bancarotta nasce da una propria puntata, oppure c'è un tempo di attesa tra una catena e l'altra.

Da decidere insieme: tetto del prelievo di colletta al saldo disponibile (oggi si può andare in negativo); se serve altro contro la convenienza dell'all-in (riammissione 500 Carletti e debito azzerato); estrazione pesata del Banco per ridurre le squadre mai colpite; riduzione del peso delle risposte di stato (27 KB per aggiornamento, circa 32 MB/ora per telefono). Dopo la decisione rifare la simulazione con lo stesso seed (7) per confrontare.

### D.5 Non implementato

Notizie editoriali «grande vincita» (soglia non definita) e «cassa in rosso / in attivo»; Supabase Realtime; spareggi ulteriori in classifica; visibilità dei saldi negativi; gestione dei dispositivi collegati a una serata già chiusa; ambiente di produzione separato.

### D.6 Struttura del progetto e operatività

- `web/` frontend React + Vite + TypeScript (sviluppo: `npm --prefix web run dev`, porta 5173, proxy `/api` verso il server).
- `server/` Node + TypeScript + Fastify (sviluppo: `npm --prefix server run dev`, porta 3000; richiede `server/.env` con `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY`, mai da committare). Serve anche il frontend compilato (`web/dist`).
- `server/db/` migrazioni SQL 001–008 già applicate al database; `server/db/ops/` snippet operativi (stato, pausa, ripresa, chiusura, chiusura forzata, nuova serata, classifica finale, verifica conti).
- `server/sim/` simulatore di carico e query delle metriche. Prima di simulare: serata pulita e `time_scale = 6`; dopo, chiudere e aprire una nuova serata.
- Database attuale: progetto Supabase `giochi_ufficio`, schema `mazzobet` (**da separare dalla produzione**, §13 invariante 9).
- I test del database eseguiti durante lo sviluppo erano script una tantum non salvati: da trasformare in una suite ripetibile.

### D.7 Rischi sociali accettati (confermati)

Esiti in malafede da non scommettitori (mitigati solo dal ricorso), identità multi-dispositivo senza autenticazione forte, puntate su eventi già accaduti prima dell'esito. Da osservare nella prova generale con persone vere.

## Appendice E — Delta v0.8 → v0.9 e stato dell'implementazione (23 ottobre 2026)

### E.1 Modifiche normative (confermate il 23/10/2026)

1. **Bancarotta con puntate in corso (§8):** saldo < 10 **e** nessuna puntata ancora da risolvere; chi punta tutto fallisce solo se poi perde e resta sotto soglia. (Era l'opzione A di TASKS 1.1.)
2. **Precedenza del creatore (§7):** da T a T+2′ esita solo il creatore; da T+2′ a T+17′ anche chi non ha puntato; a T+17′ senza esito la scommessa è annullata e rimborsata.
3. **Scommessa senza puntate (§7):** si chiude alla scadenza senza esito, contestazione né annullamento.
4. **Compenso di chi esita (§7):** 10% del totale puntato, massimo 250; il creatore incassa C, un altro esitatore `floor(C/2)`; pagato a fine contestazione e solo se l'esito non è ribaltato.
5. **Valuta (§1):** «Carletti» per esteso, senza simbolo; «1 Carletto»; tasto **TUTTI I CARLETTI**.
6. **Controllo sul margine delle quote (§5):** `100·(A+B) ≥ A·B`.
7. **ESITA ORA in un solo passo (§5, §7):** si sceglie SÌ o NO e si chiude subito.
8. **Banco (§9.1, §10):** importi in multipli di 10; testi non ripetuti nella serata; registro con i saldi risultanti; nuovi comunicati «cassa in rosso», «cassa in attivo», «grande vincita» (≥ 500 Carletti).
9. **Parametri in configurazione (§13, invariante 10).**

Dal prompt v0.6 **non** sono state riprese, perché sostituite dal PRD v0.7: lo sponsor a soglia di cassa (resta lo sponsor a timer con la formula `2000 + 150·N + max(0, −C)`) e gli script di fine serata semplificati (restano la chiusura in due tempi e gli snippet di `server/db/ops/`). **Da confermare:** il mantenimento dello sponsor v0.7 e il controllo sul margine, applicati come scelta predefinita.

### E.2 Interpretazioni adottate

- Il compenso si calcola sul totale puntato **al momento dell'esito** (le puntate sono chiuse); con ESITA ORA vale il totale in quel momento.
- Tutte le puntate della scommessa si valutano per la bancarotta **dopo** l'esito; la colletta parte in quel momento.
- Il compenso dell'altro esitatore è `floor(C × 50 / 100)`; con totale 15 il creatore prende 1 e un altro 0.
- «Da esitare» e il badge del tab Scommesse compaiono agli altri solo da T+2′; la schermata obbligatoria del creatore da T, solo se la scommessa ha puntate.
- Restano valide le interpretazioni di Appendice D.3 (importo unico per evento del Banco; malus e colletta senza tetto al saldo).

### E.3 Risultati della seconda simulazione

24 squadre, 60 minuti di serata in 10 reali, seed 7, stesse regole del simulatore salvo le quote valide per il controllo sul margine. Dettagli in `MazzoBet_Report_Simulazione_v09.md`.

| Metrica | v0.8 | v0.9 |
| --- | --- | --- |
| Catene di colletta | 41 | 1 |
| Bancarotte | 71 | 1 |
| Carletti prelevati dalla colletta | 28.675 | 500 |
| Saldo mediano a fine run | 347 | 749 |
| Esitate dal creatore | 17 su 39 | 34 su 35 |
| Compensi pagati | — | 32 (1.591 Carletti) |
| Banco ordinario | 4,3 interventi/ora, 15 squadre mai colpite | 5,0 interventi/ora, 17 mai colpite |

Il criterio di successo del §18 («memorabile e imprevedibile, ma non ingestibile») è ora rispettato in questo scenario. Una sola esecuzione per versione.

### E.4 Ancora aperto

Prelievo della colletta oltre il saldo disponibile (oggi preleva sempre 25); estrazione pesata del Banco (squadre mai colpite); database di produzione separato; esiti in malafede, doppio dispositivo, toast live su telefono vero; spareggi in classifica; messa online sul VPS; Supabase Realtime. Elenco completo e ordinato in `TASKS.md`.

### E.5 Struttura del progetto

Repository Git (`main` = stato della v0.8; lavoro sul ramo `regole-v06`, da unire dopo il tuo via libera). `server/db/` migrazioni 001–010; `server/db/tests/` quattro suite di test SQL ripetibili; `server/tests/concorrenza.mjs` prova di concorrenza sull'API; `server/sim/` simulatore e metriche; `deploy/` Dockerfile, compose per il VPS, blocco Caddy, script di aggiornamento e guida; `docs/delta-v0.6.md` confronto con il prompt v0.6.
