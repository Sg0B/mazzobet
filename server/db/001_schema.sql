-- MazzoBet — schema (PRD v0.7 §14). Tutto in uno schema dedicato, non esposto via API.
-- Importi in Carletti interi, quote in centesimi. Il ledger è a partita doppia e immutabile.

create schema if not exists mazzobet;
revoke all on schema mazzobet from public, anon, authenticated;

create table mazzobet.teams (
  id   smallint primary key,
  name text not null unique
);

insert into mazzobet.teams (id, name) values
  (1,'Parallelo24'),(2,'Saunier Duval'),(3,'Team Sbornia Cycling'),(4,'VeloClub Mosciano'),
  (5,'Team Pomanti'),(6,'S.C. Colleranesco'),(7,'Rabobank'),(8,'Vini la vespa e l’uva'),
  (9,'I Cosacchi'),(10,'Nerito Team'),(11,'Us Postal Service'),(12,'Team Patxi'),
  (13,'Annateresa'),(14,'Team Sbronzi'),(15,'Tubateam'),(16,'Pennello Cinghiale'),
  (17,'Della Rovere Pro Cycling'),(18,'Sanfelice 2023'),(19,'Gli Scalatori'),(20,'Fave Marchisio'),
  (21,'Mercatone Uno'),(22,'Team Festina con la droga'),(23,'Subaru B. Cycling Team'),(24,'Pianograndecc');

create table mazzobet.game_sessions (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  status         text not null default 'active' check (status in ('active','paused','closed')),
  starts_at      timestamptz not null default now(),
  ends_at        timestamptz not null,           -- fine serata (default 03:00 Europe/Rome)
  timezone       text not null default 'Europe/Rome',
  next_market_no int  not null default 1,
  created_at     timestamptz not null default now()
);

create table mazzobet.session_teams (
  session_id     uuid not null references mazzobet.game_sessions(id),
  team_id        smallint not null references mazzobet.teams(id),
  status         text not null default 'in_game' check (status in ('in_game','bankrupt')),
  balance        bigint not null default 0,      -- cache del ledger, aggiornata nella stessa transazione
  entered_at     timestamptz not null default now(),
  bankrupt_until timestamptz,
  bankruptcies   int not null default 0,
  readmissions   int not null default 0,
  correct_picks  int not null default 0,
  primary key (session_id, team_id)
);

-- Dispositivi: token di sessione + log accessi (non è autenticazione forte, PRD §2).
create table mazzobet.team_devices (
  token        uuid primary key default gen_random_uuid(),
  session_id   uuid not null,
  team_id      smallint not null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  user_agent   text,
  foreign key (session_id, team_id) references mazzobet.session_teams(session_id, team_id)
);
create index on mazzobet.team_devices (session_id, team_id);

create table mazzobet.markets (
  id                 bigint generated always as identity primary key,
  session_id         uuid not null references mazzobet.game_sessions(id),
  market_no          int not null,
  creator_team_id    smallint not null,
  question           text not null check (char_length(question) between 8 and 120),
  yes_odds           int not null check (yes_odds between 110 and 1000),
  no_odds            int not null check (no_odds between 110 and 1000),
  status             text not null default 'open' check (status in ('open','closed','resolved','void')),
  outcome            text check (outcome in ('yes','no')),
  yes_pool           bigint not null default 0,
  no_pool            bigint not null default 0,
  scheduled_close_at timestamptz not null,
  actual_closed_at   timestamptz,
  resolve_by         timestamptz,                 -- fine finestra esito (15')
  resolved_at        timestamptz,
  appeal_deadline_at timestamptz,                 -- fine finestra ricorso (3')
  resolved_by_team_id smallint,
  idempotency_key    text,
  created_at         timestamptz not null default now(),
  unique (session_id, market_no),
  unique (session_id, idempotency_key),
  foreign key (session_id, creator_team_id) references mazzobet.session_teams(session_id, team_id)
);
create index on mazzobet.markets (session_id, status, scheduled_close_at);

create table mazzobet.bets (
  id         bigint generated always as identity primary key,
  session_id uuid not null,
  market_id  bigint not null references mazzobet.markets(id),
  team_id    smallint not null,
  side       text not null check (side in ('yes','no')),
  amount     bigint not null check (amount >= 10),
  odds_cents int not null,                         -- quota congelata alla puntata
  result     text check (result in ('win','loss','void')),
  payout     bigint,
  created_at timestamptz not null default now(),
  unique (session_id, team_id, market_id),         -- una puntata per squadra/mercato (PRD §6)
  foreign key (session_id, team_id) references mazzobet.session_teams(session_id, team_id)
);
create index on mazzobet.bets (market_id);

create table mazzobet.ledger_transactions (
  id              uuid primary key default gen_random_uuid(),
  session_id      uuid not null,
  kind            text not null,
  market_id       bigint,
  idempotency_key text not null,
  created_at      timestamptz not null default now(),
  unique (session_id, idempotency_key)
);

-- account: 'team' (portafoglio squadra), 'bank' (cassa del Banco), 'mint' (Carletti iniziali, fuori dalla cassa)
create table mazzobet.ledger_entries (
  id             bigint generated always as identity primary key,
  transaction_id uuid not null references mazzobet.ledger_transactions(id),
  session_id     uuid not null,
  account        text not null check (account in ('team','bank','mint')),
  team_id        smallint,
  amount         bigint not null check (amount <> 0),
  created_at     timestamptz not null default now(),
  check ((account = 'team') = (team_id is not null))
);
create index on mazzobet.ledger_entries (session_id, team_id);
create index on mazzobet.ledger_entries (transaction_id);

-- Ogni transazione deve sommare a zero (controllo a fine transazione).
create function mazzobet.check_tx_balanced() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (select coalesce(sum(amount), 0) from mazzobet.ledger_entries where transaction_id = new.transaction_id) <> 0 then
    raise exception 'ledger_unbalanced';
  end if;
  return null;
end $$;

create constraint trigger ledger_balanced
  after insert on mazzobet.ledger_entries
  deferrable initially deferred
  for each row execute function mazzobet.check_tx_balanced();

-- Il ledger non si modifica né si cancella.
create function mazzobet.forbid_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'ledger_immutable';
end $$;

create trigger ledger_entries_immutable before update or delete on mazzobet.ledger_entries
  for each row execute function mazzobet.forbid_change();
create trigger ledger_transactions_immutable before update or delete on mazzobet.ledger_transactions
  for each row execute function mazzobet.forbid_change();

-- Difesa in profondità: RLS attiva e nessuna policy (lo schema non è comunque esposto).
alter table mazzobet.teams               enable row level security;
alter table mazzobet.game_sessions       enable row level security;
alter table mazzobet.session_teams       enable row level security;
alter table mazzobet.team_devices        enable row level security;
alter table mazzobet.markets             enable row level security;
alter table mazzobet.bets                enable row level security;
alter table mazzobet.ledger_transactions enable row level security;
alter table mazzobet.ledger_entries      enable row level security;

-- Prima serata: finisce alle prossime 03:00 Europe/Rome.
insert into mazzobet.game_sessions (name, ends_at)
select 'Serata 1',
       (case when r.n::time < time '03:00'
             then date_trunc('day', r.n) + interval '3 hours'
             else date_trunc('day', r.n) + interval '1 day 3 hours' end) at time zone 'Europe/Rome'
from (select now() at time zone 'Europe/Rome' as n) r;
