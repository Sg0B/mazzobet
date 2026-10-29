# Notifiche push

Per le scommesse normali solo **due tipi** di avviso (A e B), più **tre per la corsa simulata** (C, D, E, sotto). Il gioco resta giocabile al 100% anche se nessuno li attiva.

| Tipo | A chi | Quando | Testo |
| --- | --- | --- | --- |
| **A, «Da esitare»** | Al creatore | La sua scommessa **con puntate** è scaduta. Senza puntate non parte nulla. | «La scommessa n. 12 è scaduta. Esitala ora.» Se ne ha più d'una da esitare: «Hai 3 scommesse da esitare.» |
| **B, «Scommessa senza esito»** | A chi **non** ha puntato, non è il creatore e non è in bancarotta | Finita la precedenza del creatore, e finché dura la finestra di esito | «Nessuno ha esitato la n. 12. Esitala e prendi fino a 5 Carletti.» Se sono più d'una: «Ci sono 3 scommesse da esitare.» |

### Corsa simulata «La Teramana» (migration 020)

Solo per le 10 scommesse della corsa e solo mentre la corsa è in movimento (nessun avviso in pausa, prima della partenza o a corsa interrotta). Si inviano a chi è in gara, ha attivato gli avvisi e **non ha già puntato** su quella scommessa (E va a chi ha vinto).

| Tipo | Quando | Testo |
| --- | --- | --- |
| **C, «Scommessa della corsa»** | La scommessa si apre | La domanda della scommessa. Se se ne aprono più insieme (B03+B04, le finali B08–B10): «Ci sono 3 nuove scommesse sulla corsa. Punta prima che chiudano.» Una sola notifica per squadra. |
| **D, «Sta per chiudere»** | **2 minuti** prima della chiusura; **1 minuto** per le finali B08–B10 (restano aperte solo 3 minuti) | «La scommessa B01 della corsa chiude tra 2 minuti.» Più scommesse insieme: «3 scommesse della corsa chiudono tra 1 minuto.» |
| **E, «Hai vinto!»** | La scommessa è stata esitata dalla cronaca e la squadra ha vinto | «Vincita sulla corsa: +175 Carletti.» (somma se le vincite escono insieme) |

Come per A e B: una volta sola per (scommessa, squadra, tipo), prenotata in `push_log` prima dell'invio; niente esiti e niente quote nel testo; `tag` che sostituisce la notifica precedente dello stesso tipo. I minuti di anticipo (120 s, 60 s per B08–B10) sono nella migration; per cambiarli si riscrive `mb_push_due`. Le notifiche C, D, E non hanno il limite «una ogni 2 minuti» delle B.

Nessuna notifica rivela l'esito o le quote. Il compenso «fino a Y» è lo stesso che l'app mostra per chi esita al posto del creatore.

## Come funziona

- **Tutti gli orari vengono dal database** (`creator_only_until` e `resolve_by` della scommessa, già ricalcolati dai parametri della Regia). Se dalla Regia cambi la finestra di esito da 17 a 60 minuti, anche gli avvisi seguono. Non ci sono copie dei tempi nelle variabili d'ambiente.
- Un worker nel server controlla ogni 5 secondi (`mb_push_due`). Ogni (scommessa, squadra, tipo) viene avvisato **una volta sola**: viene prenotato nella tabella `push_log` prima dell'invio, quindi un riavvio del server non crea doppioni. Se un invio fallisce, non si riprova (il gioco non aspetta).
- **Raggruppamento:** il testo conta tutte le scommesse ancora da esitare, e il `tag` fa sostituire la notifica precedente invece di accumularla. Una squadra riceve **al massimo una B ogni 2 minuti**; le scommesse arrivate nel frattempo escono insieme alla successiva.
- Invio con scadenza di 15 minuti e urgenza alta. Se il servizio push risponde 404 o 410 (iscrizione revocata) l'iscrizione viene disattivata senza errori visibili.
- Le iscrizioni sono per squadra e per serata. **«Resetta squadra» cancella anche le iscrizioni** di quella squadra; un reset totale riparte da zero.

## Impostare le chiavi (una volta sola)

Servono due chiavi VAPID e un indirizzo `mailto:`. **La chiave privata non va mai nel repository né in chat.**

1. Sul tuo computer, dalla cartella `server`:

   ```bash
   npx web-push generate-vapid-keys
   ```

   Stampa una chiave pubblica e una privata.
2. Sul VPS, in `/home/lemon/mazzobet/.env` (lo stesso file della chiave di Supabase), aggiungi:

   ```
   VAPID_PUBLIC_KEY=la-chiave-pubblica
   VAPID_PRIVATE_KEY=la-chiave-privata
   VAPID_SUBJECT=mailto:tuo-indirizzo@esempio.it
   ```
3. Aggiorna e riavvia: `sh deploy/aggiorna.sh`. Nei log del contenitore (`docker logs --tail 20 mazzobet`) **non** deve comparire «Notifiche push spente».

Senza chiavi, o con `PUSH_ENABLED=false`, le notifiche restano spente e l'app non mostra nessuna richiesta di avvisi.

## Attivare e disattivare

| Variabile (`.env` del server) | Default | Effetto |
| --- | --- | --- |
| `PUSH_ENABLED` | `true` | `false` spegne tutto: nessun invio, nessuna richiesta di avvisi ai giocatori. |
| `PUSH_B_PER_TEAM_COOLDOWN_SEC` | `120` | Minimo tra due notifiche B alla stessa squadra. |

Dopo ogni modifica: `docker compose -f deploy/docker-compose.yml up -d` per ricreare il contenitore.

## Cosa vedono i giocatori

- In **Home**, una card «Vuoi ricevere un avviso quando devi esitare una scommessa?» con **Attiva avvisi** e **Non ora**. Il permesso del telefono si chiede **solo dopo il tocco**. Dopo «Non ora» resta una riga «Avvisi disattivati · Attiva». Quando sono attivi: «Avvisi attivi · Disattiva».
- Se il telefono li ha **bloccati**, l'app spiega come sbloccarli (impostazioni del telefono o del sito).
- Senza permesso funzionano comunque i **fallback**: il numero di scommesse da esitare nel titolo della scheda `(2) MazzoBet`, il blocco «Ci sono n scommesse senza esito», la schermata obbligatoria per il creatore, e una vibrazione breve quando ne arriva una nuova con l'app aperta.
- **iPhone:** gli avvisi funzionano solo se l'app è aperta **dall'icona sulla Home**. L'app lo spiega a chi la apre da Safari (Condividi → Aggiungi alla schermata Home → riapri MazzoBet dall'icona → Attiva avvisi).
- Toccando la notifica l'app si apre (o torna in primo piano) sulla scheda **Scommesse**, dove sta la scommessa da esitare.

## Limiti noti

- Su iPhone serve iOS 16.4 o successivo e l'app sulla Home. «Non disturbare» e le modalità Concentrazione bloccano le notifiche.
- L'arrivo **non è garantito al secondo**: dipende dal servizio push di Apple e Google. Per questo l'app ha i fallback e la schermata obbligatoria.
- Un telefono con più iscrizioni (reinstallazioni) riceve la notifica su ognuna finché non vengono disattivate (alla prima risposta 404/410 del servizio).
- La notifica non apre una pagina della singola scommessa (nell'app non esiste): porta alla scheda Scommesse.
- Se l'invio a un telefono fallisce, non viene riprovato: la notifica A o B per quella scommessa e quella squadra è considerata inviata.

## Prove

- `node server/tests/pglite/push.mjs`: logica nel database (chi riceve, quando, una volta sola, bancarotta, raggruppamento, limite per squadra, esito, Regia, finestra scaduta, reset squadra, permessi).
- `node server/tests/pglite/corsa.mjs`: comprende anche C, D, E (apertura, raggruppamento delle finali, anticipo di 2 e 1 minuto, una volta sola, vincita, silenzio in pausa).
- `node server/tests/pglite/push-server.mjs`: server vero con finto Supabase e finto servizio push HTTPS (invio reale con firma VAPID, 410, riavvio senza doppioni, `PUSH_ENABLED=false`).
- **Da provare sui telefoni:** ricezione a schermo bloccato, tocco sulla notifica con app chiusa e aperta, installazione da Home su iPhone, Android (Chrome).
