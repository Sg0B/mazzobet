# MazzoBet — Seconda simulazione: regole v0.9 a confronto con la prima

**Data:** 23 ottobre 2026 · **Configurazione identica alla prima prova:** 24 squadre, 60 minuti di serata in 10 reali (velocità ×6), seed 7, stessi tre profili di comportamento (12 prudenti, 8 normali, 4 giocatori d'azzardo).
**Cosa è cambiato nel gioco:** bancarotta solo senza puntate in corso, precedenza del creatore (2′) e annullamento a T+17′, compenso di chi esita, scommessa senza puntate, controllo sul margine delle quote, Banco in multipli di 10 con testi non ripetuti.
**Dati:** `server/sim/out/sim-2026-10-22T23-29-05-523Z.json` (client) e la serata «Simulazione regole v0.6 bis» nel database (ledger immutabile). Query: `server/sim/metriche.sql`.

> **Come leggere il confronto.** Stessa simulazione, ma il simulatore ha dovuto adattarsi a una regola nuova: le quote casuali che violano il controllo sul margine vengono ora rifiutate, quindi gli agenti sorteggiano solo quote valide (lato opposto ≤ 100·A/(A−100)). È una sola esecuzione per versione: i numeri sono indicativi, non statistiche. Una prova intermedia con quote casuali è stata scartata (54 creazioni su 69 rifiutate dal controllo, e un riavvio del server durante la prova).

## Esito in una riga

**Il problema della colletta è risolto in questo scenario:** da 41 catene e 28.675 Carletti prelevati a **1 catena e 500 Carletti**. Il criterio del PRD («il Banco memorabile e imprevedibile, ma non ingestibile») ora è rispettato. Il Banco ordinario e gli sponsor funzionano come prima; compensi ed esiti si comportano come progettato.

## Confronto delle metriche

| Metrica | Prima (v0.8) | Ora (v0.9) |
| --- | --- | --- |
| **Catene di colletta** | 41 | **1** |
| **Bancarotte totali** | 71 | **1** |
| **Carletti prelevati dalla colletta** | 28.675 (moneta iniziale: 24.000) | **500** |
| Squadre con almeno 1 bancarotta | 23 su 24 | **1 su 24** |
| Squadre con 3 o più bancarotte | 11 | 0 |
| Riammissioni | 25 (costo per il Banco 12.544) | 1 |
| Saldi negativi a fine run | 3 (minimo −114) | **0** |
| Saldo mediano a fine run | 347 | **749** |
| Quota di ricchezza delle prime 3 squadre | 42% | 21,5% |
| Scommesse create / puntate | 54 / 391 | 59 / 413 |
| Puntata media | 129 | 78 |
| Puntate che azzerano il saldo (tutti i Carletti) | 43 | 32 |
| Esitate dal creatore / da altre squadre | 17 / 22 | **34 / 1** |
| Tempo medio all'esito (secondi di serata, agenti molto reattivi) | 43 | 63 |
| Ricorsi / verdetti ribaltati | 38 / 4 | 28 / 3 |
| Banco ordinario: interventi all'ora | 4,3 (5 eventi) | 5,0 (5 eventi) |
| Squadre mai colpite dal Banco | 15 su 24 | 17 su 24 |
| Sponsor | 3, formula corretta | 2, formula corretta |
| Compensi di chi esita | — | 32 pagati, **1.591 Carletti** in totale (media 50) |
| Cassa del Banco a fine run | 28.693 | 19.663 |

**Perché cambia tanto.** Nella prima prova 37 bancarotte su 71 nascevano da una puntata che azzerava il saldo. Ora chi punta tutto resta in gara finché la scommessa è in corso: la bancarotta scatta solo se perde e resta sotto 10 Carletti. In tutta la prova è successo una volta (con un prelievo di 500 Carletti: 20 squadre pagano 25 Carletti), e non si è creata nessuna cascata.

## Altre osservazioni

- **Il creatore esita quasi sempre (34 su 35).** Con la precedenza di 2 minuti la schermata obbligatoria «ESITA LA SCOMMESSA!» ha senso: prima oltre metà degli esiti arrivava da altri. Gli agenti reagiscono molto più in fretta di persone a cena, quindi il caso «nessuno esita, annullata a T+17′» non si è presentato e va provato con gente vera.
- **Compensi:** 1.591 Carletti in un'ora (circa il 6,6% della moneta iniziale), tutti a chi ha esitato; nessun compenso per le scommesse ribaltate. Il costo per il Banco è contenuto.
- **Squadre a saldo basso:** 3 squadre a fine run avevano meno di 10 Carletti con puntate ancora in corso (non in bancarotta, per la nuova regola). I giocatori d'azzardo hanno chiuso con una media di soli 75 Carletti contro 921 dei prudenti e 529 dei normali (campione di 4 squadre): con la nuova regola puntare sempre tutto non conviene più.
- **Banco ordinario:** invariato, con lo stesso limite (poche squadre colpite in un'ora). Resta aperta la scelta se usare un'estrazione pesata.
- **Prestazioni:** 5.167 richieste in 10 minuti (picco 18 al secondo), nessun errore. Aggiornamento di stato: mediana 59 ms, p95 73 ms, p99 124 ms (prima: 48 / 61 / —). Dimensione di una risposta di stato: mediana 23 KB, massimo 42 KB senza compressione (con Caddy `encode` il peso scende molto).
- **Conti:** ledger a somma zero, saldi uguali alla somma dei movimenti, nessuna bancarotta non processata.

## Cosa resta da guardare

1. **Prelievo della colletta oltre il saldo:** non ha avuto occasione di succedere in questa prova (0 saldi negativi), ma la regola «preleva sempre 25» resta com'è: decisione ancora aperta.
2. **Controllo sul margine:** blocca le coppie di quote troppo generose. Nei test un utente che prova 3,00 e 3,00 vede il messaggio e deve abbassare una quota; vale la pena osservarlo su telefono.
3. **Tempi di esito reali** (annullamenti, precedenza del creatore) e **toast delle notizie**: solo con persone vere.
4. Un'unica esecuzione per versione: conviene ripetere con altri seed prima della serata vera.
