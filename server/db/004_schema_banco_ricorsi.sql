-- Fase 3–4: ricorsi, notizie, catalogo, Banco, sponsor, bancarotte a catena.

alter table mazzobet.markets add column flipped boolean not null default false;

alter table mazzobet.game_sessions
  add column bank_next_at    timestamptz,            -- prossimo intervento ordinario (8–14')
  add column sponsor_next_at timestamptz,            -- prossimo sponsor (8–45')
  add column bank_paused     boolean not null default false;

-- Il conto 'sponsor' finanzia la cassa del Banco, distinto dai Carletti accreditati alle squadre.
alter table mazzobet.ledger_entries drop constraint ledger_entries_account_check;
alter table mazzobet.ledger_entries add constraint ledger_entries_account_check
  check (account in ('team','bank','mint','sponsor'));

create table mazzobet.appeals (
  id         bigint generated always as identity primary key,
  session_id uuid not null,
  market_id  bigint not null references mazzobet.markets(id),
  team_id    smallint not null,
  created_at timestamptz not null default now(),
  unique (market_id, team_id),
  foreign key (session_id, team_id) references mazzobet.session_teams(session_id, team_id)
);

-- Notizie RadioCorsa/Almanacco: titolo e testo già renderizzati (il catalogo può cambiare senza alterare la cronologia).
create table mazzobet.news (
  id         bigint generated always as identity primary key,
  session_id uuid not null references mazzobet.game_sessions(id),
  at         timestamptz not null default now(),
  kind       text not null check (kind in ('bonus','malus','giuria','bank','sponsor')),
  title      text not null,
  body       text not null,
  ref        text
);
create index on mazzobet.news (session_id, id desc);

-- Catalogo editoriale (sola fonte dei testi; importi e probabilità stanno nel motore).
create table mazzobet.catalog_entries (
  id    text primary key,
  kind  text not null check (kind in ('bonus','malus','sponsor','radiocorsa')),
  event text,                                         -- evento (radiocorsa) o nome sponsor
  title text not null,
  body  text not null,                                -- testo; per gli sponsor: testoCassa
  body2 text                                          -- solo sponsor: testoPioggia
);

create table mazzobet.bank_events (
  id         bigint generated always as identity primary key,
  session_id uuid not null references mazzobet.game_sessions(id),
  kind       text not null check (kind in ('bonus','malus','sponsor')),
  at         timestamptz not null default now(),
  teams      smallint[],
  amount     bigint,
  detail     jsonb
);

create table mazzobet.collection_chains (
  id            bigint generated always as identity primary key,
  session_id    uuid not null references mazzobet.game_sessions(id),
  first_team_id smallint not null,
  started_at    timestamptz not null default now(),
  rounds        int not null default 0,
  ended_at      timestamptz
);

create table mazzobet.collection_rounds (
  chain_id bigint not null references mazzobet.collection_chains(id),
  round_no int not null,
  payers   int not null,
  amount   bigint not null default 25,
  fallen   smallint[] not null,
  primary key (chain_id, round_no)
);

-- Ogni ingresso in bancarotta; chain_id vuoto = ancora da processare.
create table mazzobet.bankruptcy_events (
  id         bigint generated always as identity primary key,
  session_id uuid not null references mazzobet.game_sessions(id),
  team_id    smallint not null,
  at         timestamptz not null default now(),
  chain_id   bigint references mazzobet.collection_chains(id)
);
create index on mazzobet.bankruptcy_events (session_id) where chain_id is null;

alter table mazzobet.appeals           enable row level security;
alter table mazzobet.news              enable row level security;
alter table mazzobet.catalog_entries   enable row level security;
alter table mazzobet.bank_events       enable row level security;
alter table mazzobet.collection_chains enable row level security;
alter table mazzobet.collection_rounds enable row level security;
alter table mazzobet.bankruptcy_events enable row level security;
