-- Notifiche push web: solo due tipi.
--   A «Da esitare»              → al creatore, quando la sua scommessa con puntate è scaduta.
--   B «Scommessa senza esito»   → ai non puntatori, passata la precedenza del creatore e finché dura la finestra di esito.
-- Tutti gli orari si leggono dalla scommessa (creator_only_until, resolve_by, già ricalcolati dai parametri della Regia):
-- niente orologio del server, niente copie dei tempi in variabili d'ambiente.
-- Applicata a giochi_ufficio il 27/10/2026 (migration mazzobet_016_push).

-- ---------------------------------------------------------------- tabelle

create table mazzobet.push_subscriptions (
  id          bigint generated always as identity primary key,
  session_id  uuid not null,
  team_id     smallint not null,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  disabled_at timestamptz,
  foreign key (session_id, team_id) references mazzobet.session_teams(session_id, team_id)
);
create index on mazzobet.push_subscriptions (session_id, team_id) where disabled_at is null;
alter table mazzobet.push_subscriptions enable row level security;   -- nessuna policy: solo il server (service_role)

-- Ogni (scommessa, squadra, tipo) si notifica una sola volta, anche se il server riparte.
create table mazzobet.push_log (
  market_id bigint not null references mazzobet.markets(id),
  team_id   smallint not null,
  kind      text not null check (kind in ('A','B')),
  sent_at   timestamptz not null default now(),
  primary key (market_id, team_id, kind)
);
create index on mazzobet.push_log (team_id, kind, sent_at desc);
alter table mazzobet.push_log enable row level security;

-- ---------------------------------------------------------------- compenso di chi esita al posto del creatore

-- Stesso calcolo di mb_resolve / mb_get_state (compenso C del creatore, parte per un'altra squadra).
create function mazzobet.fee_other(p_total bigint) returns bigint
language sql stable set search_path = '' as $$
  select floor(least(floor(p_total * mazzobet.cfg('compenso_percentuale') / 100), mazzobet.cfg('compenso_tetto'))
               * mazzobet.cfg('compenso_altro_percentuale') / 100)::bigint
$$;

-- ---------------------------------------------------------------- iscrizioni

create function public.mb_push_subscribe(p_token uuid, p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'bad_param'; end if;
  insert into mazzobet.push_subscriptions (session_id, team_id, endpoint, p256dh, auth, user_agent)
  values (v_s, v_t, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set session_id = excluded.session_id, team_id = excluded.team_id, p256dh = excluded.p256dh,
        auth = excluded.auth, user_agent = excluded.user_agent, disabled_at = null;
end $$;

create function public.mb_push_unsubscribe(p_token uuid, p_endpoint text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  update mazzobet.push_subscriptions set disabled_at = now()
   where endpoint = p_endpoint and session_id = v_s and team_id = v_t;
end $$;

create function public.mb_push_mark(p_ok bigint[], p_dead bigint[]) returns void
language sql security definer set search_path = '' as $$
  update mazzobet.push_subscriptions set last_ok_at = now() where id = any(coalesce(p_ok, '{}'));
  update mazzobet.push_subscriptions set disabled_at = now() where id = any(coalesce(p_dead, '{}'))
$$;

-- ---------------------------------------------------------------- chi avvisare adesso

-- Cerca e «prenota» (push_log) le notifiche da inviare: ritorna, per squadra, testo e iscrizioni.
-- Rilegge lo stato a ogni chiamata, quindi non esce nulla per scommesse già esitate, in contestazione, annullate, chiuse o senza puntate.
-- Prenotare prima di inviare significa «al massimo una volta»: se l'invio fallisce non si riprova (il gioco non aspetta).
create function public.mb_push_due(p_cooldown_sec int default 120) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v uuid := mazzobet.active_session();
  v_out jsonb := '[]'::jsonb; r record; v_pending int; v_subs jsonb;
begin
  if v is null or (select status from mazzobet.game_sessions where id = v) <> 'active' then return v_out; end if;

  -- A: al creatore, scommessa con puntate scaduta (stato «closed») e ancora da esitare
  for r in
    with due as (
      select m.id, m.market_no, m.creator_team_id as team_id
        from mazzobet.markets m
       where m.session_id = v and m.status = 'closed' and m.resolve_by > now()
         and not exists (select 1 from mazzobet.push_log l where l.market_id = m.id and l.team_id = m.creator_team_id and l.kind = 'A')
         and exists (select 1 from mazzobet.push_subscriptions s
                      where s.session_id = v and s.team_id = m.creator_team_id and s.disabled_at is null)
    ), claimed as (
      insert into mazzobet.push_log (market_id, team_id, kind)
      select id, team_id, 'A' from due on conflict do nothing returning market_id, team_id
    )
    select c.team_id, min(d.market_no) as market_no, min(d.id) as market_id
      from claimed c join due d on d.id = c.market_id and d.team_id = c.team_id
     group by c.team_id
  loop
    select count(*) into v_pending from mazzobet.markets
     where session_id = v and status = 'closed' and resolve_by > now() and creator_team_id = r.team_id;
    select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into v_subs
      from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = r.team_id and s.disabled_at is null;
    v_out := v_out || jsonb_build_object(
      'teamId', r.team_id, 'kind', 'A', 'n', greatest(v_pending, 1), 'marketNo', r.market_no, 'marketId', r.market_id, 'subs', v_subs);
  end loop;

  -- B: ai non puntatori, passata la precedenza del creatore; una sola B per squadra ogni p_cooldown_sec
  for r in
    with elig as (
      select m.id, m.market_no, (m.yes_pool + m.no_pool) as total, st.team_id
        from mazzobet.markets m
        join mazzobet.session_teams st on st.session_id = m.session_id
       where m.session_id = v and m.status = 'closed'
         and m.creator_only_until <= now() and m.resolve_by > now()
         and st.team_id <> m.creator_team_id and st.status = 'in_game'
         and not exists (select 1 from mazzobet.bets b where b.market_id = m.id and b.team_id = st.team_id)
         and exists (select 1 from mazzobet.push_subscriptions s
                      where s.session_id = v and s.team_id = st.team_id and s.disabled_at is null)
    ), ok_teams as (
      select e.team_id from elig e group by e.team_id
       having not exists (select 1 from mazzobet.push_log l
                           where l.team_id = e.team_id and l.kind = 'B'
                             and l.sent_at > now() - make_interval(secs => p_cooldown_sec))
    ), fresh as (
      select e.* from elig e join ok_teams o on o.team_id = e.team_id
       where not exists (select 1 from mazzobet.push_log l where l.market_id = e.id and l.team_id = e.team_id and l.kind = 'B')
    ), claimed as (
      insert into mazzobet.push_log (market_id, team_id, kind)
      select id, team_id, 'B' from fresh on conflict do nothing returning market_id, team_id
    )
    select c.team_id, min(f.market_no) as market_no, min(f.id) as market_id, min(f.total) as total,
           (select count(*) from elig e2 where e2.team_id = c.team_id)::int as n_total
      from claimed c join fresh f on f.id = c.market_id and f.team_id = c.team_id
     group by c.team_id
  loop
    select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into v_subs
      from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = r.team_id and s.disabled_at is null;
    v_out := v_out || jsonb_build_object(
      'teamId', r.team_id, 'kind', 'B', 'n', greatest(r.n_total, 1), 'marketNo', r.market_no, 'marketId', r.market_id,
      'fee', mazzobet.fee_other(r.total), 'subs', v_subs);
  end loop;

  return v_out;
end $$;

-- ---------------------------------------------------------------- «Resetta squadra»: cancella anche le iscrizioni push

create or replace function public.mb_admin_reset_team(p_team smallint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_n int; v_pin int; v_push int;
begin
  if v is null then raise exception 'no_session'; end if;
  if not exists (select 1 from mazzobet.teams where id = p_team) then raise exception 'unknown_team'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  delete from mazzobet.team_devices where session_id = v and team_id = p_team;
  get diagnostics v_n = row_count;
  delete from mazzobet.team_pins where session_id = v and team_id = p_team;
  get diagnostics v_pin = row_count;
  delete from mazzobet.push_subscriptions where session_id = v and team_id = p_team;
  get diagnostics v_push = row_count;
  perform mazzobet.alog(v, 'reset_squadra', jsonb_build_object('dispositivi', v_n, 'pin', v_pin > 0, 'avvisi', v_push), null, p_team);
  return jsonb_build_object('devices', v_n);
end $$;

-- Permessi: solo il server (service_role) può chiamare le funzioni mb_*.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'mb\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
