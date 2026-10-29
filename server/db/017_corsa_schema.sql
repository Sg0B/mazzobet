-- Corsa simulata «La Teramana» (PRD v1.2): tabelle.
-- Le definizioni della corsa (notizie, scommesse, ESITI) stanno in tabelle chiuse al pubblico: i telefoni non le leggono mai.
-- Ai telefoni arriva solo ciò che è già uscito (race_feed) e le scommesse già aperte (markets), tramite funzioni del server.
-- Una corsa per serata: lo stato (partenza, pausa) sta in race_runs; l'orologio di gara si calcola sempre dal database.

-- ---------------------------------------------------------------- definizione (caricata dal server dai due JSON)

create table mazzobet.race_defs (
  race_id          text primary key,
  name             text not null,
  edition          int  not null,
  distance_km      numeric not null,
  duration_seconds int  not null check (duration_seconds > 0),
  loaded_at        timestamptz not null default now()
);

create table mazzobet.race_events (
  race_id              text not null references mazzobet.race_defs(race_id) on delete cascade,
  id                   text not null,                 -- PCS001 …
  seq                  int  not null,                 -- posizione nel file, a parità di orario
  at_seconds           int  not null check (at_seconds >= 0),
  km                   numeric not null,
  km_is_event_location boolean not null default false,  -- km del traguardo, non il km corrente (notizie retrospettive)
  km_approximate       boolean not null default false,
  block                int,
  type                 text not null,
  text                 text not null,
  is_puncture          boolean not null default false, -- foratura (per B07), ricavata dal caricamento e confrontata col JSON
  primary key (race_id, id),
  unique (race_id, seq)
);

create table mazzobet.race_markets (
  race_id     text not null references mazzobet.race_defs(race_id) on delete cascade,
  id          text not null,                          -- B01 …
  seq         int  not null,
  category    text,
  question    text not null check (char_length(question) between 8 and 120),
  opens_at    int  not null check (opens_at >= 0),
  closes_at   int  not null,
  yes_odds    int  not null check (yes_odds between 110 and 1000),
  no_odds     int  not null check (no_odds between 110 and 1000),
  winning     text not null check (winning in ('yes','no')),   -- RISERVATO: mai fuori dal database
  settlement  jsonb not null,
  primary key (race_id, id),
  check (closes_at > opens_at)
);

-- ---------------------------------------------------------------- stato per serata

create table mazzobet.race_runs (
  session_id  uuid primary key references mazzobet.game_sessions(id),
  race_id     text not null references mazzobet.race_defs(race_id),
  status      text not null default 'not_started'
              check (status in ('not_started','running','paused','finished','aborted')),
  started_at  timestamptz,
  paused_at   timestamptz,
  paused_secs double precision not null default 0,    -- secondi reali di pausa già conclusi
  speed       numeric not null default 1 check (speed >= 1),   -- SOLO per le prove: nessuna funzione pubblica la cambia
  finished_at timestamptz
);

-- Le notizie già uscite: l'unica parte della cronaca che i telefoni possono leggere.
create table mazzobet.race_feed (
  session_id           uuid not null references mazzobet.game_sessions(id),
  event_id             text not null,
  seq                  int  not null,
  at_seconds           int  not null,
  km                   numeric not null,
  km_is_event_location boolean not null,
  km_approximate       boolean not null,
  type                 text not null,
  text                 text not null,
  published_at         timestamptz not null default now(),
  primary key (session_id, event_id)
);
create index on mazzobet.race_feed (session_id, at_seconds, seq);

alter table mazzobet.race_defs    enable row level security;
alter table mazzobet.race_events  enable row level security;
alter table mazzobet.race_markets enable row level security;
alter table mazzobet.race_runs    enable row level security;
alter table mazzobet.race_feed    enable row level security;

-- ---------------------------------------------------------------- scommesse della corsa dentro markets

alter table mazzobet.markets alter column creator_team_id drop not null;     -- le scommesse della corsa non hanno creatore
alter table mazzobet.markets add column race_market_id text;                 -- B01 … (null = scommessa normale)
alter table mazzobet.markets add column race_awaiting boolean not null default false;   -- B06: chiusa, in attesa di conferma ufficiale
create unique index markets_race_unique on mazzobet.markets (session_id, race_market_id) where race_market_id is not null;
alter table mazzobet.markets add constraint markets_creator_or_race
  check (creator_team_id is not null or race_market_id is not null);
