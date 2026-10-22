# MazzoBet: implementazione delle regole v0.6

Incolla questo testo in Claude Code, nella cartella del progetto MazzoBet. Metti nel repository anche il file `catalogo_banco_v02.json` (cartella `content/`), che contiene tutti i testi di RadioCorsa.

---

## 0. Contesto e metodo di lavoro

Lavori su MazzoBet, gioco sociale di scommesse con valuta virtuale (Carletti) per una cena di 24 squadre. Il PRD e il codice nel repository sono già stati modificati dopo la v0.5. **Non sovrascrivere nulla alla cieca**: questo documento elenca le regole decise nelle ultime sessioni di progettazione e dove c'è conflitto con il codice attuale vale questo documento.

Chi ti usa non ha formazione da programmatore. Spiega in italiano semplice, evita il gergo quando puoi e dopo ogni area dimmi come verificare a mano che funziona.

Regole di metodo:
1. Lavora su un branch nuovo (`regole-v06`), con un commit per area. Non toccare il branch principale.
2. Usa solo il progetto Supabase di test. Non eseguire migrazioni sul database di produzione. Ogni migrazione è un file versionato. Non cancellare né azzerare dati esistenti.
3. Mantieni i tre pilastri: immediatezza, aspetto da app di scommesse, Banco narrativo senza LLM a runtime. Resta fuori dalla V1: denaro reale, cash-out, console admin, quote dinamiche, punteggio attività del Banco.
4. Tutta la logica economica sta nel server/database, mai nel browser. Ogni variazione di saldo è una voce immutabile del ledger, con chiave di idempotenza.
5. Tutti i parametri numerici stanno nella configurazione (sezione 3), non nel codice.
6. L'ora autorevole è quella del server, fuso Europe/Rome.
7. Dopo un riavvio del server tutti i timer (cicli del Banco, finestre di esito, contestazioni, pagamenti dei compensi, blocchi di bancarotta, sponsor) si recuperano dallo stato nel database senza duplicare pagamenti.

## 1. Fase 0: audit prima di scrivere codice

1. Leggi PRD, schema del database, funzioni e interfaccia attuali.
2. Scrivi `docs/delta-v0.6.md` con una tabella: **area | stato attuale | regola richiesta | azione | rischio**. Segnala i punti in cui il codice fa già meglio di quanto scritto qui, e le regole che qui sono in conflitto tra loro.
3. Mostrami un riassunto e chiedimi conferma **una volta sola**. Poi procedi per aree senza fermarti a ogni passo, tranne per decisioni che cambiano le regole del gioco.

## 2. Regole da implementare

### 2.1 Linguaggio e valuta
- Nell'interfaccia e nei messaggi si dice **"scommessa"**, mai "mercato". Ogni scommessa ha un numero progressivo ("Scommessa n. 42"), unico per sessione di gioco, assegnato alla creazione. I nomi interni nel codice possono restare invariati.
- La valuta si chiama **Carletti**, **senza simbolo**. Cerca e togli `₡` in tutto il progetto (interfaccia, errori, notifiche, dati di esempio). Importi come "1.000 Carletti" (punto per le migliaia). Singolare "1 Carletto": serve una funzione unica che sceglie la forma.
- La parola "Carletti" compare in saldo, pulsanti, conferme, errori, avvisi, RadioCorsa e pannello di creazione. Nelle righe di classifica e dei movimenti si mostra il solo numero, con "Carletti" nel titolo della sezione o della colonna.
- Il pulsante MAX nel pannello di puntata diventa **"TUTTI I CARLETTI"**.

### 2.2 Creazione di una scommessa
- Costo di creazione 100 Carletti, addebitato al creatore. Serve un saldo disponibile di almeno 100 e nessuna bancarotta in corso. Il creatore non può puntare sulla propria scommessa.
- Due tipi di chiusura: **LIVE** (esattamente 20 minuti dalla pubblicazione) e **A SCADENZA** (orario scelto). Per A SCADENZA: scorciatoie +30 min, +1 h, +2 h e orario custom. Validazioni lato server: scadenza nel futuro e non oltre il limite di fine serata (configurazione, default 03:00 Europe/Rome).
- **Quote**: da 1,10 a 10,00, due decimali, salvate come interi in centesimi (110-1000). Quota SÌ e quota NO sono fisse per tutta la vita della scommessa.
- **Controllo sul margine** alla pubblicazione, solo con interi: con A e B quote in centesimi, la pubblicazione è ammessa se `100 * (A + B) >= A * B`. Questo equivale a 1/qSÌ + 1/qNO ≥ 1,00 e blocca le quote regalo come 5,00 e 5,00. Messaggio d'errore chiaro in italiano.
- Nel pannello di creazione, una riga: "Se esiti tu la scommessa ricevi il 10% delle puntate (max 250 Carletti). Se la esita un altro, non ricevi nulla."
- **ESITA ORA**: il creatore, finché la scommessa è aperta, può scegliere SÌ o NO e chiudere subito. Le puntate si chiudono, l'esito è registrato e parte la contestazione di 3 minuti.

### 2.3 Puntate
- Una sola puntata per squadra per scommessa, su un solo lato. Non annullabile né modificabile. Vincolo di unicità (squadra, scommessa) nel database.
- Puntata minima 10 Carletti, massima pari al saldo disponibile. Importi rapidi 25 / 50 / 100 / 250 più "TUTTI I CARLETTI".
- Vincita = `floor(puntata * quota_in_centesimi / 100)`. È l'unica regola di arrotondamento in tutta l'app (puntata 10 a quota 1,10 incassa 11).
- Il saldo mostra separatamente i Carletti disponibili e quelli impegnati in puntate non risolte.

### 2.4 Esito, tempi, contestazione, compenso
Sia **T** la scadenza (per ESITA ORA, T è il momento in cui il creatore preme il pulsante).

| Momento | Chi può esitare |
| --- | --- |
| Prima di T | Solo il creatore, con ESITA ORA |
| Da T a T+2 minuti | Solo il creatore |
| Da T+2 a T+17 minuti | Il creatore e le squadre che non hanno puntato. Vale la prima risposta |
| T+17 minuti, nessun esito | **Annullamento**: tutte le puntate rimborsate, nessun compenso, i 100 Carletti di creazione non tornano |

Esempio: scommessa live creata alle 22:00 → scade alle 22:20 → solo creatore fino alle 22:22 → tutti i non scommettitori fino alle 22:37 → annullamento alle 22:37.

- Le squadre in bancarotta possono esitare e incassare come le altre. L'esito registrato all'ultimo secondo vale e la contestazione prosegue oltre T+17.
- **Scommessa senza puntate**: alla scadenza si chiude come "senza puntate", senza schermata di esito, contestazione né annullamento. I 100 Carletti restano spesi.
- **Schermata obbligatoria "ESITA LA SCOMMESSA!"** solo per il creatore, con la riga "Esita ora e incassi C Carletti" (C è il compenso, vedi sotto). Più scommesse da esitare si presentano in sequenza.
- **Sezione "Da esitare"** nel tab Scommesse, visibile alle squadre che non hanno puntato solo da T+2 minuti. Ogni scheda mostra "Esita per X Carletti" con X = `floor(C/2)`, nascosto se vale 0. Badge numerico sul tab quando ci sono scommesse da esitare.
- **Contestazione**: dopo l'esito, 3 minuti. Possono contestare tutte le squadre che hanno puntato, vincitrici o perdenti, con un pulsante discreto. Il creatore non vota. Se i ricorsi raggiungono la maggioranza assoluta dei distinti scommettitori (`floor(N/2) + 1`), l'esito si ribalta automaticamente, una sola volta, senza secondo appello. Nessuna soglia minima: anche un solo scommettitore può ribaltare. Soglia e conteggio non sono mostrati.
- **Ribaltamento = rettifica netta**: un solo movimento di ledger per scommettitore, con la differenza tra pagamento vecchio e nuovo, in una transazione atomica e idempotente. Un saldo può diventare negativo. Classifica dei pronostici ricalcolata sull'esito finale.
- **Compenso di chi esita**, calcolato su T (quando le puntate sono chiuse e il totale è definitivo):
  - `C = min( floor(totale_puntato * compenso_percentuale / 100), compenso_tetto )`, con il totale puntato su entrambi i lati.
  - Esita il creatore: incassa C. Esita un'altra squadra: incassa `floor(C/2)` e il creatore non incassa nulla.
  - Pagamento **3 minuti dopo l'esito, a fine contestazione, e solo se l'esito non è stato ribaltato**. Se è ribaltato non viene pagato nessun compenso.
  - È pagato dal Banco: le vincite non cambiano e non c'è nessuna commissione sulle vincite. Una causale di ledger "compenso esito", una sola voce per scommessa.

### 2.5 Bancarotta e riammissione
- **Bancarotta** quando il saldo disponibile scende **sotto 10 Carletti** E la squadra non ha puntate ancora da risolvere. (Vedi sezione 7, punto A.) Scatta in automatico, senza azione del giocatore.
- Blocco di 5 minuti. Poi il giocatore preme **RICHIEDI RIAMMISSIONE**: il debito è azzerato, il saldo diventa 500 Carletti, il contatore delle riammissioni sale di 1.
- Se il saldo torna a 10 o più prima o dopo i 5 minuti (bonus, vincita, compenso), la squadra torna attiva senza riammissione e senza incrementare il contatore.
- In bancarotta la squadra non può puntare né creare. Le sue puntate già fatte si risolvono normalmente. Resta in gara e può ricevere bonus.
- La riammissione non innesca alcun prelievo sulle altre squadre.

### 2.6 Colletta per il gregario caduto
- **Innesco**: ogni volta che una squadra entra in bancarotta, per qualsiasi causa, a prescindere dalla futura riammissione. È un evento a parte, fuori dal ciclo del Banco.
- **Importo fisso 25 Carletti per giro**, prelevato da ogni squadra in gara che non è in bancarotta e ha saldo disponibile di almeno 10 (i "paganti"). Più fallimenti nello stesso giro valgono un solo prelievo. I Carletti vanno al Banco (entrata della cassa). La squadra fallita non riceve nulla.
- **Cascata senza limite di giri**: chi scende sotto 10 per il prelievo entra in bancarotta e genera un nuovo giro di 25 Carletti sui paganti rimasti, finché nessuno fallisce di nuovo.
- **Valvola**: se i paganti di un giro sono meno di 3, la catena si ferma.
- Le squadre già in bancarotta in attesa non pagano e non ricevono nulla.
- Tutta la catena è una sola transazione, a giri, con un identificativo di catena e una voce di ledger per ogni pagante e giro. Usa lo stesso lock degli altri eventi economici (Banco, ribaltamenti), con ordine deterministico.
- **Un solo comunicato RadioCorsa per catena**, con la prima squadra fallita e l'elenco di chi cade dopo (template `colletta` e `colletta_cascata` del catalogo).

### 2.7 Il Banco ordinario
- **Elimina** il punteggio attività, la soglia di 25 punti e l'intervallo minimo di 5 minuti. Resta solo un **timer casuale tra 8 e 14 minuti**.
- Il ciclo parte quando entra la **5ª squadra**. Il primo intervento arriva dopo 8-14 minuti; dopo ogni intervento parte un nuovo ciclo, senza code. Gira sul server anche senza browser aperti.
- Ogni intervento estrae **da 1 a 3 squadre** tra quelle entrate in gara (comprese quelle in bancarotta), con **un unico importo per tutti i destinatari**, tra 100 e 250 Carletti (multipli di 10).
- **55% bonus / 45% malus.** I malus escludono le squadre con saldo disponibile sotto 10; se nessuna è eleggibile, l'evento diventa un bonus. Le squadre mai entrate sono escluse da bonus e malus.
- I testi arrivano da `content/catalogo_banco_v02.json`: scegli un tipo di evento e poi un testo, evitando di ripetere lo stesso testo nella stessa sessione. `{nomeSquadre}` è l'elenco già formattato ("A", "A e B", "A, B e C").
- Registra ogni intervento: ora, innesco, tipo, destinatari, importi e saldi risultanti.

### 2.8 Cassa del Banco, sponsor e pioggia
- **Cassa del Banco**: il Banco è la controparte di ogni movimento nel ledger. La cassa si ricava dal ledger, senza saldo fisico. Solo informativa: il Banco resta illimitato, nessun vincolo di solvibilità.
  - Entrate: puntate, 100 di creazione, malus, colletta, sponsor.
  - Uscite: vincite, bonus, riammissioni a 500, rimborsi, compensi esito, pioggia.
- **Sponsor**: quando la cassa scende sotto la soglia configurabile (iniziale −2.000), uno sponsor versa al Banco 4.000 o 8.000 (estratto) e compare il comunicato. Pausa minima tra due sponsor e massimo per serata in configurazione. Voce di ledger con causale "sponsor".
- **Pioggia**: 1-2 minuti dopo lo sponsor, il Banco accredita lo stesso importo (estratto tra 100 e 150) a tutte le squadre in gara non in bancarotta. L'importo non dipende dalla cifra dello sponsor. Fuori dal ciclo 8-14 minuti. Usa `testoCassa` e `testoPioggia` dello sponsor nel catalogo.
- Quando la cassa passa da positiva a negativa e viceversa: comunicato `cassa_in_rosso` / `cassa_in_attivo`.

### 2.9 Classifiche e statistiche
- Classifica per patrimonio. Classifica dei pronostici corretti: un solo pronostico per scommessa, escluse le annullate e quelle senza puntate, contato sull'esito definitivo dopo la contestazione. **Spareggio**: a parità di patrimonio vince chi ha più pronostici corretti.
- Conteggi di bancarotte e riammissioni per squadra.
- Sezione statistiche con **"Cassa del Banco"** e **"di cui puntate in corso"**.
- Il tab Scommesse mostra, per ogni scommessa creata dalla squadra, il compenso potenziale mentre è aperta e quello ricevuto a esito chiuso.

### 2.10 Accesso
- Nessun PIN. Se la squadra scelta è già associata a un altro dispositivo, schermata "Stai entrando come X" con conferma, con tono del Banco. Nessun blocco. Salva un token di sessione per dispositivo, per vedere i doppi accessi nel log.

### 2.11 Fine serata e strumenti
- Nessuna console admin nella V1. Crea nella cartella `ops/` due script SQL documentati: (1) mette in pausa o riattiva il Banco; (2) chiude la sessione: rimborsa le puntate delle scommesse ancora aperte, congela la classifica. Spiegami come eseguirli da Supabase.

### 2.12 RadioCorsa e testi
- Ogni bonus/malus, bancarotta, riammissione, ribaltamento, colletta, cassa in rosso/in attivo e annullamento genera un comunicato. Le **grandi vincite** (soglia in configurazione, default 500 Carletti di vincita) possono generarne uno. Le puntate normali no.
- Il banner della Home mostra le ultime 3-4 notizie in rotazione; il tab RadioCorsa mostra la cronologia.
- Variabili del catalogo: `nomeSquadre`, `nomeSquadra`, `importo`, `numeroScommessa`, `nomeSponsor`, `importoSponsor`, `numeroSquadre`, `importoPerSquadra`, `elencoCaduti`. Gli importi nei testi sono sempre numeri seguiti dalla parola "Carletti".

## 3. Parametri di configurazione (valori iniziali)

| Parametro | Valore |
| --- | --- |
| saldo_iniziale | 1000 |
| costo_creazione | 100 |
| puntata_minima | 10 |
| quota_min / quota_max (centesimi) | 110 / 1000 |
| limite_fine_serata | 03:00 Europe/Rome |
| durata_live_minuti | 20 |
| precedenza_creatore_minuti | 2 |
| finestra_esito_aperta_minuti | 15 |
| contestazione_minuti | 3 |
| compenso_percentuale / compenso_tetto | 10 / 250 |
| quota_esito_altro_percentuale | 50 |
| bancarotta_soglia | 10 |
| bancarotta_blocco_minuti | 5 |
| riammissione_saldo | 500 |
| banco_squadre_per_avvio | 5 |
| banco_intervallo_min / max (minuti) | 8 / 14 |
| banco_destinatari_min / max | 1 / 3 |
| banco_importo_min / max | 100 / 250 |
| banco_probabilita_bonus | 55 |
| colletta_importo | 25 |
| colletta_min_paganti | 3 |
| sponsor_soglia_cassa | −2000 |
| sponsor_importi | 4000, 8000 |
| sponsor_pausa_minuti / sponsor_max_serata | 30 / 3 (valori miei da tarare) |
| pioggia_ritardo_secondi | 60-120 |
| pioggia_importo_min / max | 100 / 150 |
| grande_vincita_soglia | 500 |

## 4. Scenari di test con numeri

Scrivi test automatici (database e logica) per tutti questi casi, usando un orologio simulato per i tempi.

1. **Pagamento**: puntata 10 a quota 1,10 → incassa 11. Puntata 33 a quota 1,95 → `floor(64,35)` = 64.
2. **Controllo quote**: (2,00 e 2,00) ammessa. (2,50 e 2,50) bloccata. (1,10 e 10,00) ammessa. (1,00) e (10,01) rifiutate.
3. **Doppia puntata**: la stessa squadra sulla stessa scommessa due volte → la seconda rifiutata, anche con due richieste simultanee.
4. **Concorrenza**: due puntate simultanee che insieme superano il saldo → una sola passa.
5. **Tempi**: scommessa live creata alle 22:00 → solo il creatore fino alle 22:22; chiunque non abbia puntato dalle 22:22; alle 22:37 senza esito si annulla con rimborsi e senza compenso.
6. **Compenso**: totale 3.450 → C = 250 (tetto); se esita un altro, 125. Totale 905 → C = 90, altro 45. Totale 15 → C = 1, altro 0 (niente "Esita per"). Scommessa ribaltata → nessun compenso. Annullata → nessun compenso.
7. **Ribaltamento**: un solo movimento per scommettitore con la differenza, anche con richieste concorrenti. Un secondo ribaltamento è rifiutato.
8. **Scommessa senza puntate**: si chiude alla scadenza, nessuna schermata di esito.
9. **Bancarotta**: saldo 9 senza puntate pendenti → bancarotta. Saldo 0 con una puntata ancora aperta → **non** in bancarotta. Squadra in bancarotta con un bonus che la porta a 10 o più → torna attiva senza riammissione.
10. **Colletta con cascata**: la squadra X (saldo 3) va in bancarotta; paganti A (20), B (30), C (40), D (200), E (300). Giro 1: tutti pagano 25 → A −5, B 5, C 15, D 175, E 275 (cadono A e B). Giro 2: pagano C, D, E (3 paganti, valvola rispettata) → C −10, D 150, E 250 (cade C). Giro 3: restano D ed E (2 paganti) → la catena si ferma. Fallite: X, A, B, C. Un solo comunicato.
11. **Banco**: malus mai assegnato a chi ha saldo sotto 10; se nessuna squadra è eleggibile l'evento diventa un bonus. Importo unico per tutti i destinatari. Ciclo che parte alla 5ª squadra.
12. **Sponsor**: con cassa sotto −2.000 arriva lo sponsor, poi la pioggia; rispetta pausa minima e massimo per serata.
13. **Riavvio**: chiudi e riavvia il server durante una finestra di esito, una contestazione e un blocco di bancarotta; nessun pagamento viene duplicato e i timer ripartono.

## 5. Ordine di implementazione consigliato

1. Valuta, terminologia e numero progressivo delle scommesse (modifica a basso rischio).
2. Economia: quote in centesimi, controllo del margine, arrotondamento, ledger con la cassa del Banco.
3. Esito: tempi e fasi, "Da esitare", ESITA ORA, contestazione, rettifica netta, compenso.
4. Bancarotta (nuova soglia e regola sulle puntate pendenti) e colletta con cascata.
5. Banco ordinario con il catalogo.
6. Sponsor, pioggia e statistiche di cassa.
7. Classifiche, spareggi e schermate.
8. Script `ops/`, aggiornamento del PRD a v0.6 e `docs/delta-v0.6.md`.

## 6. Consegna finale

Quando hai finito:
- Riassunto in italiano semplice di ciò che è cambiato, area per area.
- Elenco dei test eseguiti e dei risultati.
- Una lista di passi per provare a mano le novità dall'app (con 3-4 squadre di prova).
- Le istruzioni per mandare tutto su GitHub e fare il deploy sul VPS, senza toccare il database di produzione prima del mio via libera.
- Le regole che non hai potuto applicare e perché.

## 7. Decisioni prese da Claude in chat, da confermare con me

A. **Bancarotta e puntate aperte.** Il PRD diceva che si fallisce quando il saldo arriva a zero. Con "TUTTI I CARLETTI" e con la colletta questo è un problema: chi punta tutto avrebbe saldo 0 subito, finirebbe in bancarotta con la scommessa ancora in corso e farebbe pagare 25 Carletti a tutti. Regola scelta: si fallisce solo se il saldo disponibile è sotto 10 **e** la squadra non ha puntate ancora da risolvere. Quando l'ultima puntata si risolve e il saldo è ancora sotto 10, scatta la bancarotta in quel momento. Se nel codice attuale è diverso, segnalamelo nel report.
B. Sponsor: la pioggia segue sempre lo sponsor, soglia −2.000, pioggia estratta tra 100 e 150.
C. Pausa minima tra sponsor 30 minuti e massimo 3 a serata.
D. Soglia per il comunicato "grande vincita": 500 Carletti.
E. Importi del Banco ordinario in multipli di 10.
