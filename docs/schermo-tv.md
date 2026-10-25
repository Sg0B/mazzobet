# Schermo della sala (/tv)

Pagina in sola lettura per la smart TV (o un telefono in mirroring): **https://mazzobet.sourlemon.cloud/tv**. Non serve nessun codice e non si può toccare niente da lì.

## Come si apre

- **Smart TV:** apri il browser della TV e scrivi l'indirizzo. Per non digitarlo ogni volta, mettilo nei preferiti.
- **Telefono in mirroring (MirrorLink, Chromecast, AirPlay):** apri `/tv` sul telefono e proiettalo. Disattiva lo spegnimento automatico dello schermo, altrimenti si ferma.
- **Computer collegato via HDMI:** il più affidabile. Apri `/tv` e premi F11.
- Toccando o cliccando la pagina si attiva e si disattiva il **schermo intero**. Il cursore non si vede.

## Cosa mostra

Una scena alla volta, ogni 12 secondi circa, a rotazione:

1. **Classifica Carletti**: patrimonio (saldo più puntate in corso) di tutte le squadre, con il saldo sotto se diverso e l'indicazione «in bancarotta». Primo, secondo e terzo evidenziati.
2. **Chi indovina di più**: solo se almeno una squadra ha il minimo di scommesse esitate.
3. **Le altre classifiche**: striscia vincente, più puntato, bancarotte (prime 5 ciascuna).
4. **Scommesse in corso**: le prossime a scadere, con conto alla rovescia, quote, puntate e totale; sotto quelle in attesa di esito.
5. **Ultimi esiti**: SÌ/NO, chi ha creato la scommessa, miglior vincita.
6. **Il Banco**: cassa (indicativa), Carletti in gioco, ultimi bonus, malus e sponsor.

Le scene senza dati vengono saltate. Sempre visibili: titolo e nome della serata, ora, **codice QR e indirizzo** per entrare in gioco da telefono, e in basso **RadioCorsa** che scorre.

**Eventi a tutto schermo:** ogni comunicato nuovo di RadioCorsa (bancarotta, colletta, bonus, malus, sponsor, grande vincita, apertura del Banco) compare per 8 secondi in grande sopra tutto. Se ne arrivano più d'uno, si mettono in fila (al massimo gli ultimi 4). Al primo caricamento della pagina non compare niente di vecchio.

**Annuncio della Regia:** un banner giallo in alto, per il tempo scelto.

A serata chiusa la pagina resta accesa e mostra la classifica finale con la scritta «SERATA CONCLUSA».

## Annuncio dalla Regia

In **/regia → Schermo**: scrivi il testo (al massimo 140 caratteri), i minuti (1–240, di solito 10) e premi **MANDA SULLO SCHERMO**. Sparisce da solo allo scadere; «Togli l'annuncio» lo toglie subito. Un annuncio nuovo sostituisce il precedente. Ogni annuncio finisce nel Log.

## Come funziona e cosa è pubblico

- La TV legge `/api/tv`, che **non usa token**: mostra solo ciò che i giocatori già vedono tra loro (saldi, classifiche, scommesse, esiti, comunicati). **Non mostra chi ha puntato su cosa** e non ha nessun comando.
- Il server tiene la risposta per 3 secondi e la pagina chiede i dati ogni 5: una TV accesa tutta sera pesa quanto un giocatore.
- Chiunque abbia l'indirizzo può aprirla. Se non lo vuoi, non appendere il QR dove passa il pubblico: il QR sullo schermo porta all'app, non alla TV.
- Se cade la rete resta l'ultima schermata con la scritta «connessione instabile», poi riprende da sola.

## Per aggiornare il VPS

La TV richiede la migration `014_tv.sql` (da applicare a giochi_ufficio prima del deploy) e il solito deploy:

```bash
cd /home/lemon/mazzobet && sh deploy/aggiorna.sh
```

## Prove automatiche

```bash
npm i --no-save @electric-sql/pglite
node server/tests/pglite/tv.mjs
```

Provano la lettura per lo schermo, l'annuncio (limiti, scadenza, rimozione), l'uguaglianza con le classifiche dei telefoni e i permessi.
