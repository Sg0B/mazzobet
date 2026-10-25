# MazzoBet — Prompt per Claude Code: notifiche push web (v01)

Contesto: MazzoBet è una web app (React/Vite/TS, server Node/Fastify, Supabase schema `mazzobet`, VPS con Caddy in HTTPS). Serve un sistema di notifiche push web, minimo e non invasivo, per una sola serata con 24 squadre. Non si pubblica su nessuno store.

Prima di scrivere codice: leggi il repo, fai una breve analisi (file da toccare, rischi, domande) e aspetta il mio OK. Non toccare dati di produzione né il progetto Supabase condiviso senza dirmelo: le migration vanno scritte come file e applicate solo dopo la mia conferma.

## 1. Regole: SOLO due tipi di notifica

Non aggiungere nessun altro tipo (niente notifiche per nuove scommesse, Banco, bancarotta, riammissione, contestazioni, risultati).

**Notifica A — al creatore: "da esitare"**
- Quando: una scommessa scade (scatta `expiry`) e ha almeno una puntata. Le scommesse senza puntate si chiudono e non generano notifica.
- A chi: solo alla squadra creatrice.
- Testo: titolo `Da esitare`, corpo `La scommessa n. {numero} è scaduta. Esitala ora.`
- Se il creatore ha più scommesse scadute nello stesso minuto: UNA sola notifica con corpo `Hai {n} scommesse da esitare.` Usa lo stesso `tag` per sostituire la precedente, non per accumulare.

**Notifica B — ai non puntatori: "esita al posto del creatore"**
- Quando: passati i 2 minuti di precedenza del creatore (T+2 min dalla scadenza), se la scommessa è ancora non esitata e ha puntate.
- A chi: alle squadre che NON hanno puntato su quella scommessa, che non sono la creatrice e che non sono in bancarotta. Chi ha puntato non la riceve mai.
- Testo: titolo `Scommessa senza esito`, corpo `Nessuno ha esitato la n. {numero}. Esitala e prendi fino a {Y} Carletti.` dove `Y = floor(C/2)` con tetto 125 e `C = min(floor(10% del totale puntato), 250)`, cioè lo stesso calcolo del compenso già implementato. Non duplicare la formula: riusa la funzione/SQL esistente.
- Raggruppamento: se più scommesse entrano nella finestra nello stesso minuto, UNA notifica `Ci sono {n} scommesse da esitare.` con lo stesso `tag`.
- Una squadra riceve al massimo UNA notifica B ogni 2 minuti (limite per squadra).

**Controlli all'invio (per entrambe)**
- Subito prima di inviare, rileggi lo stato: se la scommessa è già esitata, in contestazione, annullata o chiusa, NON inviare.
- Ogni (scommessa, squadra, tipo) si notifica una sola volta, anche se il worker riparte. Salva i flag/timestamp nel DB (es. tabella `push_log` con chiave unica su `market_id, team_id, kind`).
- La notifica B non parte oltre la finestra di esito (T+17 min).
- Nessun contenuto riservato: il testo non rivela mai l'esito né le quote.

## 2. Parte tecnica

**Client (web)**
- Rendi l'app una PWA installabile: `manifest.webmanifest` (nome "MazzoBet", `display: standalone`, `start_url: /`, icone 192/512, theme color coerente con la grafica) e un service worker.
- Service worker: gestisce `push` (mostra la notifica con titolo, corpo, `tag`, `data.url`) e `notificationclick` (apre o porta in primo piano l'app sulla schermata della scommessa, o sulla home se manca l'URL). Non cachare le chiamate API: nessuna cache offline, solo ricezione push.
- Iscrizione: pulsante/interruttore "Avvisi" nel profilo/impostazioni della squadra. Il permesso del browser si chiede SOLO dopo un tocco dell'utente, mai al caricamento.
- Invito leggero (scelta mia, non obbligatorio): al primo accesso una card chiudibile "Vuoi ricevere un avviso quando devi esitare una scommessa?" con un pulsante "Attiva avvisi" e un "Non ora" che la nasconde (ricorda la scelta in localStorage dentro try/catch, l'app deve funzionare anche senza).
- iPhone: se il dispositivo è iOS e l'app NON è aperta da schermata Home, mostra 3 righe di istruzioni illustrate: "Condividi → Aggiungi alla schermata Home → riapri MazzoBet dall'icona e premi Attiva avvisi". Sugli altri dispositivi non mostrare nulla di tutto questo. Rileva `display-mode: standalone` / `navigator.standalone`.
- Stati chiari nell'interfaccia: avvisi attivi / disattivati / bloccati dal browser (spiega come sbloccarli) / non supportati.
- **Fallback senza permesso (sempre attivi)**: numero di scommesse da esitare nel titolo della scheda `(2) MazzoBet`, banner fisso in Home `Hai {n} scommesse da esitare` con link diretto, vibrazione breve quando ne compare una nuova mentre l'app è aperta. Se esiste già qualcosa di simile, riusalo.

**Server**
- Libreria `web-push` con chiavi VAPID. Chiave privata e subject (`mailto:`) SOLO in `server/.env` / variabili d'ambiente, mai nel repo; aggiungi le variabili a `server/.env.example` con valori finti. La chiave pubblica arriva al client da un endpoint o da una variabile `VITE_`. Spiegami come generare le chiavi (`npx web-push generate-vapid-keys`) e dove metterle sul VPS.
- Tabella `mazzobet.push_subscriptions`: `id`, `team_id`, `endpoint` (unico), `p256dh`, `auth`, `user_agent`, `created_at`, `last_ok_at`, `disabled_at`. Una squadra può avere più dispositivi. RLS/permessi coerenti con il resto dello schema: la lettura dell'endpoint non deve essere accessibile ad altri giocatori.
- Endpoint `POST /api/push/subscribe` e `POST /api/push/unsubscribe`, autenticati come le altre rotte e legati alla squadra della sessione.
- Worker nel server (intervallo 5–10 s) che cerca scommesse che hanno raggiunto le soglie A e B, applica i controlli del §1, invia con `TTL` breve (15 min) e `urgency: high`. Niente pg_cron né servizi esterni nuovi. L'orario si legge dal DB, non dall'orologio del server.
- Se il push service risponde 404 o 410, marca l'iscrizione come disattivata. Un errore di invio non deve mai bloccare né rallentare il gioco: logga e vai avanti.
- Parametri in config (con default): `PUSH_ENABLED` (true/false per spegnere tutto), `PUSH_B_DELAY_SEC` (120), `PUSH_B_MAX_AGE_MIN` (17), `PUSH_B_PER_TEAM_COOLDOWN_SEC` (120), `PUSH_GROUP_WINDOW_SEC` (60).

## 3. Test da eseguire e riferire

1. Squadra A crea una scommessa, B punta, scade: A riceve la notifica A; B no.
2. Scommessa scaduta senza puntate: nessuna notifica.
3. A la esita entro 2 minuti: nessuna notifica B a nessuno.
4. A non la esita: dopo 2 minuti ricevono la B le squadre che non hanno puntato, non A e non chi ha puntato; il valore Y coincide col compenso reale mostrato dall'interfaccia.
5. Una squadra in bancarotta non riceve la B.
6. Due scommesse scadute nello stesso minuto: una sola notifica raggruppata.
7. Riavvio del server a metà finestra: nessun duplicato (flag nel DB).
8. Notifica toccata: l'app si apre sulla scommessa giusta, da app chiusa e da app aperta.
9. Iscrizione revocata dal browser: l'endpoint viene disattivato senza errori visibili.
10. Android Chrome e iPhone con app aggiunta alla Home: notifica ricevuta a schermo bloccato. Dimmi cosa NON hai potuto provare da solo, la prova su telefono vero la faccio io.
11. `PUSH_ENABLED=false`: nessun invio e il gioco funziona normalmente.

## 4. Consegna

- Migration SQL come file nuovo (numerazione esistente), non applicata fino al mio OK.
- Documento breve `docs/notifiche.md`: come generare e installare le chiavi VAPID, come attivare e disattivare, cosa mostrare ai giocatori, limiti noti (iPhone: serve l'app sulla Home; "non disturbare" blocca le notifiche; arrivo non garantito al secondo).
- Il gioco deve restare giocabile al 100% anche se nessuno attiva le notifiche.
- Alla fine: elenco dei file toccati, cosa è stato testato, cosa resta da provare sui telefoni.
