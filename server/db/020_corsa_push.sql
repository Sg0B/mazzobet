-- Corsa simulata (fase 3): notifiche push per le scommesse della corsa.
--   C «Scommessa aperta» · D «Sta per chiudere» (2 min prima, 1 min per le finali) · E «Hai vinto».
-- Si aggiungono ai due tipi già esistenti (A, B), che restano identici.

alter table mazzobet.push_log drop constraint push_log_kind_check;
alter table mazzobet.push_log add constraint push_log_kind_check check (kind in ('A','B','C','D','E'));

create or replace function public.mb_push_due(p_cooldown_sec int default 120) returns jsonb
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


  -- ------------------------------------------------------------ corsa simulata: solo scommesse della corsa, solo a corsa in movimento
  -- C «Scommessa aperta»: a chi è in gara e non ha ancora puntato; più scommesse aperte insieme = una sola notifica.
  -- D «Sta per chiudere»: 2 minuti prima (1 minuto per le finali B08–B10, che restano aperte 3 minuti), solo a chi non ha puntato.
  -- E «Hai vinto»: importo totale delle vincite della squadra sulle scommesse della corsa appena esitate.
  -- Niente esiti e niente quote nel testo. Una volta sola per (scommessa, squadra, tipo).

  -- C
  for r in
    with elig as (
      select m.id, m.market_no, m.race_market_id, m.question, st.team_id
        from mazzobet.markets m
        join mazzobet.race_runs rr on rr.session_id = m.session_id and rr.status = 'running'
        join mazzobet.session_teams st on st.session_id = m.session_id
       where m.session_id = v and m.race_market_id is not null and m.status = 'open'
         and st.status = 'in_game'
         and not exists (select 1 from mazzobet.bets b where b.market_id = m.id and b.team_id = st.team_id)
         and exists (select 1 from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = st.team_id and s.disabled_at is null)
         and not exists (select 1 from mazzobet.push_log l where l.market_id = m.id and l.team_id = st.team_id and l.kind = 'C')
    ), claimed as (
      insert into mazzobet.push_log (market_id, team_id, kind)
      select id, team_id, 'C' from elig on conflict do nothing returning market_id, team_id
    )
    select c.team_id, count(*)::int as n, min(e.market_no) as market_no, min(e.id) as market_id,
           min(e.race_market_id) as race_id, min(e.question) as question
      from claimed c join elig e on e.id = c.market_id and e.team_id = c.team_id
     group by c.team_id
  loop
    select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into v_subs
      from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = r.team_id and s.disabled_at is null;
    v_out := v_out || jsonb_build_object('teamId', r.team_id, 'kind', 'C', 'n', r.n, 'marketNo', r.market_no, 'marketId', r.market_id,
                                         'raceId', r.race_id, 'question', r.question, 'subs', v_subs);
  end loop;

  -- D
  for r in
    with elig as (
      select m.id, m.market_no, m.race_market_id, st.team_id,
             case when rm.seq >= 8 then 60 else 120 end as lead_sec
        from mazzobet.markets m
        join mazzobet.race_runs rr on rr.session_id = m.session_id and rr.status = 'running'
        join mazzobet.race_markets rm on rm.race_id = rr.race_id and rm.id = m.race_market_id
        join mazzobet.session_teams st on st.session_id = m.session_id
       where m.session_id = v and m.status = 'open'
         and mazzobet.race_elapsed(v) >= rm.closes_at - (case when rm.seq >= 8 then 60 else 120 end)
         and mazzobet.race_elapsed(v) < rm.closes_at
         and st.status = 'in_game'
         and not exists (select 1 from mazzobet.bets b where b.market_id = m.id and b.team_id = st.team_id)
         and exists (select 1 from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = st.team_id and s.disabled_at is null)
         and not exists (select 1 from mazzobet.push_log l where l.market_id = m.id and l.team_id = st.team_id and l.kind = 'D')
    ), claimed as (
      insert into mazzobet.push_log (market_id, team_id, kind)
      select id, team_id, 'D' from elig on conflict do nothing returning market_id, team_id
    )
    select c.team_id, count(*)::int as n, min(e.market_no) as market_no, min(e.id) as market_id,
           min(e.race_market_id) as race_id, min(e.lead_sec) as lead_sec
      from claimed c join elig e on e.id = c.market_id and e.team_id = c.team_id
     group by c.team_id
  loop
    select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into v_subs
      from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = r.team_id and s.disabled_at is null;
    v_out := v_out || jsonb_build_object('teamId', r.team_id, 'kind', 'D', 'n', r.n, 'marketNo', r.market_no, 'marketId', r.market_id,
                                         'raceId', r.race_id, 'minutes', r.lead_sec / 60, 'subs', v_subs);
  end loop;

  -- E
  for r in
    with won as (
      select b.market_id, b.team_id, b.payout, m.market_no
        from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id
       where m.session_id = v and m.race_market_id is not null and b.result = 'win'
         and exists (select 1 from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = b.team_id and s.disabled_at is null)
         and not exists (select 1 from mazzobet.push_log l where l.market_id = b.market_id and l.team_id = b.team_id and l.kind = 'E')
    ), claimed as (
      insert into mazzobet.push_log (market_id, team_id, kind)
      select market_id, team_id, 'E' from won on conflict do nothing returning market_id, team_id
    )
    select c.team_id, count(*)::int as n, sum(w.payout)::bigint as amount, min(w.market_no) as market_no, min(w.market_id) as market_id
      from claimed c join won w on w.market_id = c.market_id and w.team_id = c.team_id
     group by c.team_id
  loop
    select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into v_subs
      from mazzobet.push_subscriptions s where s.session_id = v and s.team_id = r.team_id and s.disabled_at is null;
    v_out := v_out || jsonb_build_object('teamId', r.team_id, 'kind', 'E', 'n', r.n, 'amount', r.amount,
                                         'marketNo', r.market_no, 'marketId', r.market_id, 'subs', v_subs);
  end loop;

  return v_out;
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
