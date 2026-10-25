# MazzoBet — Prompt per Claude Code: nuove classifiche e saldo del Banco in RadioCorsa (v01)

Contesto: MazzoBet è una web app (React/Vite/TS, server Node/Fastify, Supabase schema `mazzobet`, VPS con Caddy). Il gioco è fatto di scommesse virtuali in Carletti, con 24 squadre. Voglio più classifiche nel tab Classifiche e il saldo del Banco spostato nel tab RadioCorsa.

Prima di scrivere codice: leggi il repo, fai una breve analisi (file da toccare, rischi, domande) e aspetta il mio OK. Le migration vanno scritte come file e applicate solo dopo la mia conferma. Non toccare i dati di produzione.

## 1. Classifiche

Nel tab Classifiche, accanto a quella attuale, aggiungi quattro classifiche in un selettore a chip o tab scorrevoli. Default: Patrimonio.

1. **Patrimonio**: saldo + puntate ancora aperte. Verifica che sia coerente con la classifica attuale; se è già così, non duplicarla e dimmelo.
2. **Pronostici corretti**: scommesse vinte / scommesse esitate, in percentuale. Mostra "7 su 10 (70%)". Conta solo chi ha almeno 3 scommesse esitate (parametro `min_esitate`, default 3); gli altri compaiono in fondo senza posizione. Ordina per percentuale, a parità per numero di vinte.
3. **Striscia vincente**: record di scommesse vinte di fila nella serata, con la striscia in corso accanto (es. "5 · in corso 2").
   - Le scommesse annullate, rimborsate o annullate dalla Regia non spezzano né allungano la striscia.
   - Vale l'esito finale dopo un'eventuale contestazione.
   - Parametri `striscia_quota_min` (default 1.30) e `striscia_puntata_min` (default 50): una vincita conta per la striscia solo se quota e puntata li raggiungono; con 0 si disattivano. Una vincita non qualificata non spezza una striscia in corso.
4. **Somma puntate**: totale puntato dalla squadra (scommesse aperte ed esitate, escluse quelle rimborsate).
5. **Bancarotte**: numero di bancarotte per squadra, dalla più alta; a parità, chi è caduto più di recente. Includi solo squadre con almeno una bancarotta e, se nessuna, un messaggio neutro ("Nessun gregario caduto, per ora").

Per ogni classifica:
- prime 3 posizioni evidenziate;
- la mia squadra sempre visibile con la posizione, anche se non è in alto;
- formato dei numeri italiano;
- lista scorrevole a 24 righe senza problemi su 360px.

## 2. Dati e prestazioni

- Calcola tutto dal ledger/dati esistenti, con una sola query o RPC che restituisce tutte le classifiche insieme.
- Non ricalcolare a ogni polling da 3 secondi: cache lato server di 5-10 secondi.
- Niente nuove tabelle se non indispensabili. Se servono, migration come file e NON applicarla senza il mio OK.

## 3. Saldo del Banco

- Toglilo dal tab Classifiche (se c'è) e mettilo in cima al tab RadioCorsa, in piccolo e in grigio, con la dicitura "Saldo del Banco (indicativo)".
- Non entra in nessuna classifica, può essere negativo, nessun limite.

## 4. Test da eseguire e riferire

1. Squadra con tutto il saldo in puntate aperte: il Patrimonio la mostra correttamente.
2. Squadra con 1 sola scommessa esitata vinta: non compare in cima ai pronostici corretti.
3. Scommessa annullata nel mezzo di una striscia: la striscia continua.
4. Esito ribaltato in contestazione: classifiche aggiornate.
5. Parametri `striscia_quota_min` e `striscia_puntata_min` a 0: striscia senza filtri.
6. Bancarotte: ordinamento corretto e messaggio neutro quando non ce ne sono.
7. 24 squadre su schermo 360px.
8. Nessun costo visibile sul carico (polling con cache).
9. Saldo del Banco negativo: mostrato normalmente in RadioCorsa.

## 5. Consegna

- Elenco dei file toccati, cosa è stato testato, cosa resta da provare sui telefoni.
- Eventuali migration come file nuovi, non applicate fino al mio OK.
