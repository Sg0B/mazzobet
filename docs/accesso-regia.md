# Banco di Regia

Pagina di servizio per chi conduce la serata: **https://mazzobet.sourlemon.cloud/regia**. Non compare da nessuna parte nell'app dei giocatori. Funziona da telefono.

> Questa è la parte «Regia» del prompt accesso/Regia. L'accesso delle squadre con il PIN è descritto più sotto («PIN delle squadre»).

## Impostare il codice (`ADMIN_CODE`)

Il codice è una variabile d'ambiente del server: non sta nel repository, né nel frontend, né nel database.

1. Scegli un codice tuo di **almeno 12 caratteri** (il server rifiuta quelli sotto 8 e il valore di esempio).
2. Sul VPS, in `/home/lemon/mazzobet/.env` aggiungi la riga `ADMIN_CODE=il-tuo-codice` (come per la chiave di Supabase: non incollarlo in chat).
3. Ricrea il contenitore perché legga il nuovo `.env`:

```bash
cd /home/lemon/mazzobet && docker compose -f deploy/docker-compose.yml up -d --force-recreate
```

4. Apri `/regia`, scrivi il codice e premi ENTRA. Il telefono lo ricorda finché non premi **Esci**.

Se il codice non è impostato o è troppo corto, la Regia risponde «non configurata» e nessuna azione è possibile. Sul PC, per le prove locali, vale lo stesso in `server/.env` (vedi `server/.env.example`).

**Se il codice trapela:** cambialo nel `.env` del VPS e rifai il comando di sopra. Tutti i telefoni con il vecchio codice vengono respinti.

## Sicurezza (volutamente leggera)

- Il codice viene controllato **sul server a ogni azione**: chiamare le API a mano senza codice non fa nulla.
- Nessuna sessione con scadenza: il browser rimanda il codice a ogni richiesta.
- Dopo 10 codici sbagliati in un minuto, quell'indirizzo viene fermato per il resto del minuto (anche con il codice giusto).
- Ogni azione viene scritta nel **Log** (quando, che cosa, scommessa o squadra coinvolta).

## Cosa si può fare

| Scheda | Azioni |
| --- | --- |
| **Serata** | Contatori (squadre, scommesse aperte, in attesa, in contestazione, cassa del Banco). **Reset totale** (scrivere `RESET`). Chiudi serata. Chiusura forzata (solo dopo «Chiudi serata»). |
| **Banco** | Stato (aperto, in pausa, prossimi interventi). **Avvia Banco adesso.** Orario di apertura. Pausa e ripresa. |
| **Squadre** | Elenco con saldo, bancarotta e numero di dispositivi. **Resetta** squadra. **Rettifica saldo** con motivo obbligatorio. |
| **Scommesse** | Da gestire e chiuse. **Esita SÌ / NO** (definitivo). **Annulla con rimborso.** |
| **Parametri** | Saldo iniziale, saldo di riammissione, tempo totale per esitare, precedenza del creatore, importi minimo e massimo del Banco, colletta. |
| **Log** | Ultime 60 azioni. |

### Reset di una squadra

Scollega **tutti i dispositivi** di quella squadra, **cancella il suo PIN** e la rende di nuovo libera. **Saldo, storico, puntate e scommesse create restano.** Chi la sceglie di nuovo ritrova tutto, comprese le scommesse ancora in corso.

### Reset totale (serata nuova)

Chiude la serata corrente (le puntate in corso vengono **rimborsate**, il costo di creazione no) e ne apre una nuova: nessuna squadra entrata, saldi e scommesse da zero. I telefoni che erano dentro tornano alla scelta della squadra.

L'opzione «Riporta l'apertura del Banco al 13/11 alle 20:00» è attiva di default: nelle serate di prova il Banco resta spento tra un reset e l'altro e i saldi non si gonfiano. La sera del 13/11 l'orario è comunque già passato, quindi non cambia nulla.

### Esito dalla Regia

- Vale per qualsiasi scommessa non ancora esitata (anche ancora aperta o durante la precedenza del creatore).
- **Definitivo**: nessuna contestazione. Le puntate vincenti sono pagate subito.
- Il **creatore riceve subito il compenso C** come se avesse esitato lui (10% del totale puntato, massimo 250). La Regia non incassa nulla e non muove Carletti a proprio favore.
- Ai giocatori compare «Esitata dalla Regia» nel dettaglio della scommessa.
- **Annulla con rimborso** restituisce le puntate; il costo di creazione non torna. Una scommessa già esitata o già annullata non si può riaprire.
- **Rettifica saldo**: si sceglie «+ Aggiungi» o «− Togli» e si scrivono solo le cifre (la tastiera numerica del telefono non ha il segno meno); serve il motivo (almeno 3 caratteri) e il saldo non può andare sotto zero. Il movimento compare nello storico del giocatore come «Rettifica della Regia».

### Il Banco e il suo orario

- Finché non è passato `banco_inizio` (di default **13/11/2026 ore 20:00**, ora italiana) **non partono** Banco, bonus, malus, sponsor e piogge, anche con più di 5 squadre. Dopo parte con la regola delle 5 squadre.
- La **colletta per bancarotta e la riammissione** funzionano sempre, anche prima.
- «Avvia Banco adesso» imposta l'apertura a questo istante e toglie la pausa; i timer partono entro pochi secondi, il primo intervento dopo 8–14 minuti.
- Quando il Banco apre, RadioCorsa pubblica un annuncio (tre testi a rotazione, nel tono del catalogo). Non viene pubblicato se la serata è iniziata a Banco già aperto.
- Spostando l'orario nel futuro mentre il Banco è in funzione, il Banco si ferma e riparte da lì.

### Parametri

Valgono subito e senza deploy. Per i giocatori esistenti non cambia il saldo: **«Saldo iniziale» vale solo per chi entra dopo.**

- **Tempo totale per esitare**: minuti dalla scadenza (precedenza del creatore inclusa), default 17. Vale anche per le scommesse **già scadute** e non ancora annullate: l'annullamento si calcola sul valore corrente a ogni controllo (ogni 5 secondi). Di giorno si può portare a 60 o più.
- **Precedenza del creatore**: default 2 minuti; il tempo totale resta lo stesso.
- I valori fuori dai limiti sono rifiutati.

## Serate di prova e simulazioni

- Per i test con amici: tra una prova e l'altra usa **Reset totale** (con l'opzione del Banco spenta). Per provare il Banco: «Avvia Banco adesso».
- La simulazione (`server/sim/`) e i test del database (`server/db/tests/`) presuppongono il Banco aperto: prima di lanciarli esegui nell'editor SQL di Supabase `update mazzobet.config set value = 0 where key = 'banco_inizio';`, poi **ripristina** con la Regia («Imposta orario» al 13/11 20:00) o con un reset totale.

## Prove automatiche

```bash
npm i --no-save @electric-sql/pglite
node server/tests/pglite/regia.mjs
node server/tests/pglite/db-tests.mjs
```

Caricano lo schema reale (migration 001–015) in un Postgres in memoria: non toccano nessun database vero. `regia.mjs` prova orario del Banco, scadenze, esito dalla Regia, rimborsi, rettifiche, reset e permessi.

## PIN delle squadre

- La prima volta che una squadra viene scelta, chi entra imposta un **PIN di 4 cifre** (due volte). Da quel momento la squadra compare «già in gioco» per gli altri.
- Il PIN è salvato solo come **hash scrypt con sale** (calcolato dal server), mai in chiaro. Il telefono resta riconosciuto fino a fine serata (token): il PIN si chiede solo su un telefono nuovo o dopo «Esci». Più telefoni per la stessa squadra con lo stesso PIN sono consentiti.
- **5 PIN sbagliati di fila → squadra bloccata per 1 minuto** (messaggio con i secondi rimasti; l'evento finisce nel Log). Un PIN giusto azzera il conteggio.
- **Un giocatore perde il PIN:** Regia → Squadre → **Resetta**. Saldo e storico restano; la squadra torna libera e chi la sceglie imposta un PIN nuovo (attenzione: chiunque la scelga per primo, quindi fallo con il giocatore davanti).
- Le squadre già entrate prima della migration 015 non hanno PIN: il primo che le sceglie dopo l'aggiornamento lo imposta.
- Prova: `node server/tests/pglite/pin.mjs` (avvia il server vero con un finto Supabase che inoltra a Postgres in memoria).

## Limiti noti

- Il codice resta nel browser (localStorage) di chi lo inserisce, e viaggia in HTTPS a ogni richiesta.
- Non c'è un elenco delle sessioni attive né un modo di «disconnettere» un singolo telefono della Regia: per tutti, si cambia il codice.
- Il PIN non è un segreto forte: chi ha in mano il telefono già sbloccato di un collega ha già il suo token. Vale per questo gioco, non per altro.
- Il blocco dopo 5 PIN sbagliati è **per squadra**: chi sbaglia apposta può bloccare una squadra per un minuto, ripetutamente. Il dispositivo già riconosciuto non viene fermato.
