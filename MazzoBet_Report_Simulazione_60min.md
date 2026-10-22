# MazzoBet — Report simulazione di carico e di serata

**Data:** 21 ottobre 2026 · **Esecuzione:** 24 squadre simulate, **60 minuti di serata in 10 minuti reali** (velocità ×6), seed 7
**Strumenti:** `server/sim/sim.mjs` (agenti sull'API vera), `server/sim/metriche.sql` (metriche dal database)
**Dati grezzi:** `server/sim/out/sim-2026-10-20T23-42-04-007Z.json` (lato client) e la serata «Simulazione 60 min» nel database (ledger immutabile)

> **Nota:** le metriche del database sono state estratte alla fine della simulazione, prima di chiudere la serata di prova. Dopo la chiusura i 15 mercati ancora aperti sono stati annullati e rimborsati, quindi interrogando oggi quella serata la cassa del Banco e alcuni conteggi sono diversi.

## Sintesi

| Area | Esito |
| --- | --- |
| Tecnica (carico, conti, concorrenza) | **Regge.** Nessun errore del server, nessun deadlock, conti sempre coerenti. |
| Banco ordinario | **Nei limiti attesi**, ma 15 squadre su 24 non sono mai state colpite. |
| Sponsor | **Corretto** (formula giusta 3 volte su 3). |
| Esiti e ricorsi | **Funzionano.** I tempi non sono realistici (agenti troppo reattivi). |
| **Colletta a cascata** | **Fuori controllo in questo scenario.** 41 catene, ₡28.675 prelevati (più dei ₡24.000 iniziali), 23 squadre su 24 in bancarotta almeno una volta. |

**Criterio di successo del PRD** («il Banco è memorabile e imprevedibile, ma non rende il gioco ingestibile»): **non soddisfatto** per colpa della colletta, non del Banco ordinario. La causa principale è una combinazione di due regole approvate: la puntata **MAX** azzera il saldo e il saldo sotto ₡10 è bancarotta immediata, quindi **chi punta tutto fa scattare la colletta su tutte le altre squadre**, anche se poi vince la scommessa. Serve una decisione (sezione «Decisioni da prendere»).

## Come è stata fatta la simulazione (e cosa non dimostra)

- **24 agenti**, uno per squadra, che usano l'API come i telefoni: aggiornano lo stato ogni ~3 secondi, creano scommesse, puntano, esitano, contestano, chiedono la riammissione.
- **Tre profili di comportamento** (una mia ipotesi, da tarare): 12 prudenti (puntate ₡10–50), 8 normali (₡25–250), 4 «giocatori d'azzardo» (metà delle puntate sono MAX).
- **Velocità ×6** su tutti i tempi di gioco (esito 15', ricorso 3', blocco bancarotta 5', timer del Banco e sponsor). Le **durate** in minuti di serata sono quelle del PRD; la **reattività** degli agenti (30–90 secondi simulati tra una decisione e l'altra) è molto più alta di quella di persone a cena.
- **Una sola esecuzione**: i numeri sono indicativi, non statistiche. Con 5 interventi del Banco e 3 sponsor il campione è piccolo.
- **Non misurabile da una simulazione:** tempo per puntare o creare con le dita, leggibilità delle notizie, invasività percepita dei toast, uso su rete mobile reale. Servono telefoni veri.

## Carico e prestazioni

| Metrica | Valore |
| --- | --- |
| Richieste totali | 5.191 in 10 minuti (media 8,7/s, **picco 26/s**) |
| Di cui aggiornamenti di stato | 4.596 (89%) |
| Risposte con errore del server o di rete | **0** |
| `GET /state` | mediana 48 ms · p95 61 ms · p99 162 ms · max 1,47 s |
| Puntata | mediana 43 ms · p95 63 ms · p99 241 ms · max 1,08 s |
| Creazione scommessa | mediana 45 ms · p95 118 ms |
| Esito / ricorso | mediana 45 / 44 ms · p95 78 / 62 ms |
| Dimensione di una risposta di stato | **mediana 27 KB, max 46 KB** (54 mercati, 100 movimenti, 50 notizie) |

- **Peso dei dati:** con aggiornamento ogni 3 secondi, ogni telefono scarica circa 9 KB/s, cioè **~32 MB all'ora** a persona. La risposta non è compressa e cresce con il numero di mercati (il PRD prevede fino a ~500). Va ridotta (compressione, meno dati per ogni aggiornamento o Realtime).
- **Rifiuti «normali»:** 14 tentativi di esito su 53 (26%) hanno perso la gara con un altro esitatore («Esito già registrato»), 4 puntate per saldo insufficiente, 2 per bancarotta, 2 ricorsi dopo il ribaltamento. L'interfaccia deve mostrare questi messaggi in modo chiaro.
- **Problema trovato e già corretto durante la prova:** il limite di richieste era per indirizzo IP (120/minuto). A una cena tutti i telefoni condividono lo stesso wifi, quindi 24 telefoni sarebbero stati bloccati. Ora il limite è per dispositivo.

## Integrità dei conti

| Controllo | Esito |
| --- | --- |
| Ledger a somma zero | ✅ |
| Saldo di ogni squadra = somma dei suoi movimenti | ✅ |
| Bancarotte non processate | ✅ nessuna |
| Doppi addebiti, deadlock, errori 5xx | ✅ nessuno |

Movimenti registrati: 391 puntate, 158 vincite, 54 creazioni, 1.147 prelievi di colletta, 72 accrediti della pioggia sponsor, 35 rettifiche per ricorso, 25 riammissioni, 3 bonus e 8 malus del Banco.

## Banco ordinario (PRD §9.1)

| Metrica | Valore | Atteso |
| --- | --- | --- |
| Interventi | 5 in 1,17 ore di serata → **4,3 all'ora** | ~4–7 all'ora |
| Bonus / malus | 2 / 3 | 55% / 45% |
| Destinatari medi, importo medio | 2,2 squadre, ₡156 | 1–3 squadre, ₡100–250 |
| **Squadre mai colpite** | **15 su 24 (62%)** | da minimizzare |
| Colpi per squadra | da 0 a 2 | |
| Bancarotte causate da un malus | 1 (su 71) | |

**Lettura:** il ritmo è quello previsto e il Banco ordinario da solo non è invasivo. Con circa 5 interventi a serata quasi due squadre su tre non vengono mai toccate: conferma il rischio n. 14 del PRD (estrazione pesata).

## Colletta a cascata (PRD §9.2)

| Metrica | Valore |
| --- | --- |
| Catene | **41** in 1,17 ore |
| Bancarotte totali | **71** (1,7 per catena, max 6 in una catena) |
| Giri per catena | media 1,5 · max 4 (1 giro: 27, 2: 8, 3: 4, 4: 2) |
| Paganti medi per giro | 18,2 |
| **Carletti prelevati** | **₡28.675** (la moneta iniziale di tutte le squadre è ₡24.000) |
| Squadre con almeno 1 bancarotta | **23 su 24** |
| Squadre con 3 o più bancarotte | **11** (massimo 9 per una squadra) |
| Riammissioni | 25, costo per il Banco ₡12.544 |
| Saldi negativi a fine run | 3 (minimo −₡114) |

**Cause delle 71 bancarotte (ultimo movimento prima del fallimento):**

| Causa | Bancarotte |
| --- | --- |
| Puntata | **38** (di cui **37 con puntata che azzera il saldo**, cioè MAX) |
| Prelievo della colletta | 29 |
| Rettifica per ricorso | 3 |
| Malus del Banco | 1 |

38 catene su 41 sono state innescate da una puntata. Il circolo vizioso: un MAX porta a bancarotta e colletta su tutti, la colletta spinge altre squadre sotto ₡10, queste chiedono la riammissione a ₡500 (soldi nuovi dal Banco) e così via.

**Effetto sulla classifica** (mediana ₡347 contro ₡1.000 iniziali, prime 3 squadre con il 42% della ricchezza): in questo campione i 4 giocatori d'azzardo hanno chiuso con una media di ₡1.400 contro ₡204 dei prudenti e ₡580 dei normali. È un'ipotesi da verificare, non una prova: chi fallisce non perde nulla (debito azzerato e ₡500 gratis) e a pagare sono gli altri, quindi **puntare tutto conviene**.

## Sponsor (PRD §9.3)

| Metrica | Valore |
| --- | --- |
| Eventi | 3 in 1,17 ore (2,6 all'ora; atteso ~2,3) |
| Contributo | ₡5.600 ciascuno = 2.000 + 150 × 24 ✅ |
| **Formula corretta su tutti gli eventi** | ✅ |
| Cassa del Banco prima di ogni sponsor | +10.439 · +19.909 · +28.358 |
| Cassa del Banco nel run | minimo ₡100, massimo ₡34.365, finale ₡28.693 |
| Accrediti della pioggia | 72 (₡150 a testa), 13 a squadre in bancarotta |
| Squadre uscite dalla bancarotta grazie alla pioggia | **13 su 13** |

**Lettura:** la parte «ricapitalizzazione se la cassa è negativa» non è mai servita: tra puntate perse e colletta la cassa è sempre stata molto positiva (la colletta svuota le squadre e riempie il Banco). La pioggia invece salva tutte le squadre fallite che raggiunge.

## Esiti e ricorsi (PRD §7)

| Metrica | Valore |
| --- | --- |
| Scommesse create | 54 (~46 all'ora di serata) |
| Puntate | 391 (7,4 per scommessa, media ₡129) |
| Esitate | 39 (**17 dal creatore, 22 da altre squadre**) |
| Annullate per mancato esito | 0 (gli agenti rispondono sempre in tempo) |
| «Da esitare» contemporanei (massimo) | 3 |
| Tempo dall'esito richiesto all'esito dato | mediana 40 s, p95 74 s di serata (**non realistico**) |
| Ricorsi | 38 su 18 scommesse |
| Esiti sbagliati inseriti dal simulatore | 5 (5%) |
| Verdetti ribaltati | 4 |
| Rettifiche nette registrate | 35 (una per scommettitore) |

**Lettura:** meccanica corretta, nessuna doppia erogazione. Più della metà degli esiti è arrivata da squadre diverse dal creatore, quindi la schermata obbligatoria del creatore spesso si chiude da sola: è coerente con «la prima risposta vale», ma va provato con persone vere. Il percorso «mercato annullato a 15 minuti» non è stato esercitato.

## Decisioni da prendere

1. **Puntata MAX e bancarotta (la più importante).** Il PRD approva sia «puntata massima = intero saldo» sia «saldo sotto ₡10 = bancarotta». Insieme producono colletta ad ogni all-in. Opzioni coerenti con lo spirito del gioco:
   - **A.** La bancarotta scatta solo se il saldo è sotto ₡10 **e non ci sono puntate in corso** (il PRD già dice che chi fallisce incassa le puntate pendenti).
   - **B.** Una puntata non può far scendere il saldo sotto ₡10 (il tasto MAX lascia ₡10).
   - **C.** Si tiene la regola ma la colletta non parte se la bancarotta nasce da una propria puntata, oppure ha un tempo di attesa tra una catena e l'altra.
2. **Prelievo della colletta:** oggi preleva ₡25 anche a chi ha ₡10–24 e lo porta in negativo (3 squadre in negativo, minimo −₡114). Proposta: prelevare al massimo il saldo.
3. **Convenienza dell'all-in:** con la riammissione a ₡500 e il debito azzerato, fallire non costa niente. Valutare dopo la decisione 1 se serve altro.
4. **Banco ordinario:** estrazione pesata per ridurre le squadre mai colpite (rischio n. 14), oppure accettarlo.
5. **Peso dei dati:** compressione e riduzione dei dati di ogni aggiornamento prima della serata vera (non è una decisione di prodotto, ma va fatto).

Dopo la decisione 1 conviene **rifare la stessa simulazione con lo stesso seed** per confrontare i numeri.
