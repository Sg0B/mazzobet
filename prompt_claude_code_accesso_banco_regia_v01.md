# MazzoBet — Prompt per Claude Code: accesso squadre, orario Banco, saldo iniziale, esito dalla Regia (v01)

Contesto: il gioco si apre la mattina del 13/11/2026 e dura fino alle 03:00 del 14/11 (Europe/Rome). Di giorno i giocatori sono al lavoro o in viaggio, la sera c'è la cena. Il Banco (bonus, malus, sponsor) deve partire solo alla sera. Il repo è stato pubblico: nessun segreto nel codice.

Prima di scrivere codice: leggi il repo, fai una breve analisi (file da toccare, rischi, domande) e aspetta il mio OK. Le migration vanno scritte come file e applicate solo dopo la mia conferma. Se la Regia (pannello admin) è già in lavorazione, integra queste funzioni lì e non duplicarla.

## 1. Accesso squadre con PIN

- Link unico di ingresso, uguale per tutti. Al primo accesso: elenco delle 24 squadre, quelle già occupate sono segnate come tali e non selezionabili. Il giocatore sceglie la sua squadra e imposta un PIN di 4 cifre (chiedilo due volte).
- Salva il PIN solo hashato (bcrypt o argon2, con salt), mai in chiaro. Limita i tentativi: dopo 5 errori consecutivi blocco di 1 minuto per quella squadra, con messaggio chiaro.
- Dopo l'accesso il dispositivo resta riconosciuto (token di sessione lungo, valido fino a fine serata): il PIN si chiede solo su un nuovo dispositivo o dopo "Esci". Più dispositivi per la stessa squadra sono consentiti (stesso PIN).
- Una squadra occupata nell'elenco mostra "Già in gioco. Se è la tua, inserisci il PIN." Chi sbaglia squadra può tornare indietro.
- Regia: pulsante "Resetta squadra" che cancella PIN e sessioni di quella squadra e la rende di nuovo libera. Il saldo e lo storico NON si toccano.
- Un giocatore nuovo parte con il saldo iniziale configurato (vedi §3), anche se entra a metà giornata.

## 2. Accesso alla Regia

- Accesso con un codice separato, che conosco solo io. Il codice sta in una variabile d'ambiente del server (`ADMIN_CODE`), mai nel repo né nel frontend; aggiungila a `server/.env.example` con un valore finto.
- Controllo solo lato server. Ogni azione della Regia richiede il codice o una sessione admin valida, con gli stessi limiti di tentativi del §1.
- Ogni azione della Regia viene scritta in un log (chi, quando, cosa, scommessa o squadra coinvolta), visibile in Regia.
- Deve funzionare bene da telefono.

## 3. Parametri configurabili dalla Regia (con default)

Tutti questi valori vanno in configurazione, modificabili da Regia senza deploy:

| Parametro | Default | Note |
| --- | --- | --- |
| `saldo_iniziale` | 1500 | Il valore finale lo decido dopo la simulazione. Non scriverlo fisso nel codice |
| `riammissione_saldo` | 500 | Oggi è fisso. Rendilo parametro |
| `banco_inizio` | 2026-11-13 20:00 Europe/Rome | Il Banco non parte prima di questo orario |
| `finestra_esito_min` | 17 | Minuti dopo la scadenza prima dell'annullamento, modificabile dalla Regia (di giorno 60 o più) |
| `precedenza_creatore_min` | 2 | Invariato |

- `banco_inizio`: prima di quell'ora NON si attivano Banco, bonus/malus, sponsor e piogge, né il timer 8–14 min. La soglia delle 5 squadre resta valida ma si applica solo dopo `banco_inizio`. Vale anche per le notifiche collegate, se già implementate.
- Dalla Regia: cambiare `banco_inizio` e premere "Avvia Banco adesso". RadioCorsa può annunciare l'apertura del Banco (testo a tua scelta, nel tono del catalogo esistente).
- Modificare `finestra_esito_min` vale per le scommesse già scadute ma non ancora annullate: calcola l'annullamento sul valore corrente, non su un timestamp salvato in precedenza. Segnalami se il codice attuale non lo permette.
- La collette per bancarotta e la riammissione continuano a funzionare anche prima di `banco_inizio` (non dipendono dal Banco). Gli importi del Banco (100–250) e delle collette (25) devono essere parametri: li scaleremo dopo la simulazione.

## 4. Esito dalla Regia

- Dalla Regia posso esitare qualsiasi scommessa scaduta e non ancora esitata (SÌ o NO), da qualunque punto della finestra, anche durante la precedenza del creatore.
- Costo e compenso per me: nessuno. L'esito della Regia non muove Carletti a mio favore.
- Il creatore riceve comunque il compenso C come se avesse esitato lui (stessa formula esistente), senza finestra di contestazione. **Decisione da confermare con me prima di implementare.**
- L'esito della Regia è definitivo: nessuna finestra di contestazione, i pagamenti delle puntate avvengono subito.
- Nel feed e nel dettaglio della scommessa deve comparire "Esitata dalla Regia".
- Una scommessa già annullata per tempo scaduto non è riaprirsi da sola. Aggiungi in Regia anche "Annulla con rimborso" (restituisce le puntate, il costo di creazione non si restituisce, come già previsto) e "Rettifica saldo" con motivo obbligatorio, entrambi nel log.

## 5. Test da eseguire e riferire

1. Primo accesso: scelta squadra e PIN, squadra segnata occupata per gli altri.
2. PIN sbagliato 5 volte: blocco di 1 minuto, poi di nuovo possibile.
3. Dispositivo già riconosciuto: nessuna richiesta di PIN. Nuovo dispositivo: PIN richiesto.
4. Reset squadra dalla Regia: la squadra torna libera, saldo e storico invariati.
5. Codice Regia sbagliato o assente: nessuna azione eseguita, anche chiamando le API a mano.
6. Prima di `banco_inizio`: nessun evento Banco/sponsor anche con più di 5 squadre. Dopo: il Banco parte con la regola delle 5 squadre.
7. "Avvia Banco adesso" funziona e viene registrato nel log.
8. Cambio di `finestra_esito_min` da 17 a 60 su una scommessa già scaduta: non viene annullata a 17 minuti.
9. Esito dalla Regia: puntate pagate subito, creatore compensato (se confermato), nessun movimento per la Regia, etichetta "Esitata dalla Regia" visibile.
10. Cambio di `saldo_iniziale`: i nuovi giocatori partono dal nuovo valore, quelli già entrati restano come sono.
11. Il codice Regia non compare in nessun file del repo (grep) né nel bundle frontend.

## 6. Consegna

- Migration come file nuovi, non applicate fino al mio OK.
- `docs/accesso-regia.md`: come impostare `ADMIN_CODE`, come si resettano le squadre, come cambiare i parametri, cosa fare se un giocatore perde il PIN.
- Alla fine: elenco dei file toccati, cosa è stato testato, cosa resta da provare sui telefoni.
