-- Regole del prompt v0.6 (confermate il 23/10/2026): schema.
-- Parametri in tabella di configurazione, compenso di chi esita, precedenza del creatore,
-- scommesse senza puntate, testi non ripetuti, cassa in rosso.

-- Tutti i parametri numerici di gioco (una sola riga per parametro, valida per ogni serata).
-- Le durate sono in secondi di serata; il fattore game_sessions.time_scale le accelera per le simulazioni.
create table mazzobet.config (
  key   text primary key,
  value numeric not null,
  note  text
);
alter table mazzobet.config enable row level security;

insert into mazzobet.config (key, value, note) values
  ('saldo_iniziale', 1000, 'Carletti al primo ingresso di una squadra'),
  ('costo_creazione', 100, 'Carletti per pubblicare una scommessa (non rimborsati)'),
  ('puntata_minima', 10, 'Carletti'),
  ('quota_min', 110, 'centesimi (1,10)'),
  ('quota_max', 1000, 'centesimi (10,00)'),
  ('durata_min_mercato_sec', 60, 'durata minima di una scommessa'),
  ('precedenza_creatore_sec', 120, 'dopo la scadenza esita solo il creatore'),
  ('finestra_esito_sec', 900, 'poi esitano anche i non scommettitori; senza esito: annullamento'),
  ('contestazione_sec', 180, 'finestra di ricorso dopo l''esito'),
  ('compenso_percentuale', 10, '% del totale puntato (entrambi i lati)'),
  ('compenso_tetto', 250, 'Carletti, massimo del compenso'),
  ('compenso_altro_percentuale', 50, 'quota del compenso se esita una squadra diversa dal creatore'),
  ('bancarotta_soglia', 10, 'saldo sotto cui si fallisce (senza puntate da risolvere)'),
  ('bancarotta_blocco_sec', 300, 'blocco prima di poter chiedere la riammissione'),
  ('riammissione_saldo', 500, 'saldo dopo la riammissione'),
  ('banco_squadre_per_avvio', 5, 'squadre entrate per far partire Banco e sponsor'),
  ('banco_intervallo_min_sec', 480, 'Banco ordinario: intervallo minimo'),
  ('banco_intervallo_max_sec', 840, 'Banco ordinario: intervallo massimo'),
  ('banco_destinatari_min', 1, null),
  ('banco_destinatari_max', 3, null),
  ('banco_importo_min', 100, null),
  ('banco_importo_max', 250, null),
  ('banco_importo_passo', 10, 'gli importi sono multipli di questo valore'),
  ('banco_probabilita_bonus', 55, '% di bonus (il resto sono malus)'),
  ('colletta_importo', 25, 'Carletti per giro'),
  ('colletta_min_paganti', 3, 'valvola: sotto questo numero di paganti la catena si ferma'),
  ('sponsor_base', 2000, 'contributo sponsor: base'),
  ('sponsor_per_squadra', 150, 'contributo sponsor: per squadra entrata'),
  ('sponsor_intervallo_min_sec', 480, null),
  ('sponsor_intervallo_max_sec', 2700, null),
  ('pioggia_importo', 150, 'Carletti a ciascuna squadra entrata, per ogni sponsor'),
  ('grande_vincita_soglia', 500, 'vincita da cui può nascere un comunicato');

create function mazzobet.cfg(p_key text) returns numeric
language sql stable set search_path = '' as $$ select value from mazzobet.config where key = p_key $$;

-- Scommesse: nuovo stato «empty» (chiusa alla scadenza senza puntate), precedenza del creatore, compenso di chi esita.
alter table mazzobet.markets drop constraint markets_status_check;
alter table mazzobet.markets add constraint markets_status_check
  check (status in ('open','closed','resolved','void','empty'));
alter table mazzobet.markets
  add column creator_only_until timestamptz,   -- fino a qui può esitare solo il creatore
  add column fee_amount  bigint not null default 0,   -- compenso fissato all'esito
  add column fee_team_id smallint,                    -- chi lo incassa (chi ha esitato)
  add column fee_paid_at timestamptz;                 -- pagato a fine contestazione, solo se non ribaltato

-- Notizie: id del testo di catalogo usato (per non ripetere lo stesso testo nella serata).
alter table mazzobet.news add column catalog_id text;

-- Cassa del Banco: segno corrente, per i comunicati «in rosso» / «in attivo».
alter table mazzobet.game_sessions add column cash_negative boolean not null default false;
create index on mazzobet.ledger_entries (session_id, account);
