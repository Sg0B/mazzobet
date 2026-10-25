-- Pagina /tv (schermo della sala) e annuncio della Regia.
-- Applicata a giochi_ufficio il 26/10/2026 (migration mazzobet_014_tv).
--
-- mb_get_tv()       lettura pubblica in sola lettura per lo schermo: classifiche, scommesse, esiti, RadioCorsa, Banco.
--                   Nessun token, nessun dato che i giocatori non vedano già; chiamabile solo dal server (service_role).
-- mb_admin_set_tv() annuncio dalla Regia che compare sullo schermo per un tempo scelto (o sparisce subito).
-- Le classifiche passano in una funzione interna usata sia dai telefoni sia dalla TV.

alter table mazzobet.game_sessions add column tv_message text, add column tv_message_until timestamptz;

-- ---------------------------------------------------------------- classifiche: corpo condiviso

create function mazzobet.rankings(p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_s uuid := p_session; v_out jsonb;
  v_min   int := mazzobet.cfg('min_esitate')::int;
  v_qmin  int := mazzobet.cfg('striscia_quota_min')::int;
  v_pmin  bigint := mazzobet.cfg('striscia_puntata_min')::bigint;
begin
  with
  base as (
    select st.team_id, t.name, st.balance, st.bankruptcies
      from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id
     where st.session_id = v_s),
  picks as (
    select team_id,
           count(*) filter (where result = 'win') as won,
           count(*) filter (where result in ('win','loss')) as done,
           coalesce(sum(amount) filter (where result is distinct from 'void'), 0) as staked,
           coalesce(sum(amount) filter (where result is null), 0) as in_play
      from mazzobet.bets where session_id = v_s group by team_id),
  ev as (
    select b.team_id, (b.result = 'loss') as is_loss, m.resolved_at, m.id as mid
      from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id
     where b.session_id = v_s and b.result in ('win','loss')
       and (b.result = 'loss'
            or ((v_qmin = 0 or b.odds_cents >= v_qmin) and (v_pmin = 0 or b.amount >= v_pmin)))),
  seq as (
    select team_id, is_loss,
           sum(is_loss::int) over (partition by team_id order by resolved_at, mid rows unbounded preceding) as grp
      from ev),
  losses as (select team_id, count(*) filter (where is_loss) as l from seq group by team_id),
  runs as (select team_id, grp, count(*) as n from seq where not is_loss group by team_id, grp),
  streak as (
    select l.team_id,
           coalesce((select max(r.n) from runs r where r.team_id = l.team_id), 0) as best,
           coalesce((select r.n from runs r where r.team_id = l.team_id and r.grp = l.l), 0) as cur
      from losses l),
  lastbk as (select team_id, max(at) as last_at from mazzobet.bankruptcy_events where session_id = v_s group by team_id),
  m as (
    select b.team_id, b.name, b.balance, b.bankruptcies, lb.last_at,
           coalesce(p.won, 0) as won, coalesce(p.done, 0) as done, coalesce(p.staked, 0) as staked,
           b.balance + coalesce(p.in_play, 0) as wealth,
           coalesce(s.best, 0) as best, coalesce(s.cur, 0) as cur
      from base b
      left join picks p using (team_id) left join streak s using (team_id) left join lastbk lb using (team_id))
  select jsonb_build_object(
    'minEsitate', v_min, 'stricciaQuotaMin', v_qmin, 'stricciaPuntataMin', v_pmin,
    'patrimonio', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'value', wealth, 'balance', balance) order by pos, name)
        from (select *, rank() over (order by wealth desc) as pos from m) x), '[]'::jsonb),
    'pronostici', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'won', won, 'done', done,
          'pct', case when done > 0 then round(100.0 * won / done) end) order by pos nulls last, name)
        from (select *, case when done >= v_min then rank() over (order by (done >= v_min) desc,
                                                              won::numeric / nullif(done, 0) desc nulls last, won desc) end as pos
                from m) x), '[]'::jsonb),
    'striscia', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'best', best, 'cur', cur) order by pos, name)
        from (select *, rank() over (order by best desc, cur desc) as pos from m) x), '[]'::jsonb),
    'puntate', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'value', staked) order by pos, name)
        from (select *, rank() over (order by staked desc) as pos from m) x), '[]'::jsonb),
    'bancarotte', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'value', bankruptcies) order by pos, name)
        from (select *, rank() over (order by bankruptcies desc, last_at desc nulls last) as pos
                from m where bankruptcies > 0) x), '[]'::jsonb)
  ) into v_out from (select 1) one;
  return v_out;
end $$;

create or replace function public.mb_get_rankings(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint;
begin
  select * into v_s, v_t from mazzobet.who_ro(p_token);
  return mazzobet.rankings(v_s);
end $$;

-- ---------------------------------------------------------------- schermo della sala

create function public.mb_get_tv() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid; v_out jsonb;
begin
  select id into v from mazzobet.game_sessions
   order by (status in ('active','paused','closing')) desc, created_at desc limit 1;
  if v is null then return jsonb_build_object('now', now(), 'session', null); end if;

  select jsonb_build_object(
    'now', now(),
    'session', (select jsonb_build_object('name', g.name, 'status', g.status, 'endsAt', g.ends_at) from mazzobet.game_sessions g where g.id = v),
    'announcement', (select case when g.tv_message is not null and g.tv_message_until > now()
                                 then jsonb_build_object('text', g.tv_message, 'until', g.tv_message_until) end
                       from mazzobet.game_sessions g where g.id = v),
    'config', jsonb_build_object('bankruptThreshold', mazzobet.cfg('bancarotta_soglia')),
    'rankings', mazzobet.rankings(v),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('teamId', st.team_id, 'name', t.name, 'balance', st.balance, 'status', st.status)
                                        order by st.balance desc, t.name)
        from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id where st.session_id = v), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(jsonb_build_object(
          'no', m.market_no, 'question', m.question, 'by', t.name, 'yesOdds', m.yes_odds, 'noOdds', m.no_odds,
          'expiresAt', m.scheduled_close_at, 'yesPool', m.yes_pool, 'noPool', m.no_pool,
          'bets', (select count(*) from mazzobet.bets b where b.market_id = m.id)) order by m.scheduled_close_at)
        from (select * from mazzobet.markets where session_id = v and status = 'open' order by scheduled_close_at limit 8) m
        join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'waiting', coalesce((select jsonb_agg(jsonb_build_object(
          'no', m.market_no, 'question', m.question, 'by', t.name, 'resolveBy', m.resolve_by,
          'yesPool', m.yes_pool, 'noPool', m.no_pool) order by m.resolve_by)
        from (select * from mazzobet.markets where session_id = v and status = 'closed' order by resolve_by limit 6) m
        join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'results', coalesce((select jsonb_agg(jsonb_build_object(
          'no', m.market_no, 'question', m.question, 'by', t.name, 'outcome', m.outcome, 'flipped', m.flipped,
          'byAdmin', m.resolved_by_admin, 'yesPool', m.yes_pool, 'noPool', m.no_pool, 'at', m.resolved_at,
          'best', (select jsonb_build_object('name', bt.name, 'payout', b.payout)
                     from mazzobet.bets b join mazzobet.teams bt on bt.id = b.team_id
                    where b.market_id = m.id and b.result = 'win' order by b.payout desc limit 1)) order by m.resolved_at desc)
        from (select * from mazzobet.markets where session_id = v and status = 'resolved' order by resolved_at desc limit 6) m
        join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'news', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'at', n.at, 'kind', n.kind, 'title', n.title, 'text', n.body) order by n.id desc)
        from (select * from mazzobet.news where session_id = v order by id desc limit 20) n), '[]'::jsonb),
    'bank', jsonb_build_object(
        'cash', (select coalesce(sum(amount), 0) from mazzobet.ledger_entries where session_id = v and account = 'bank'),
        'inPlay', (select coalesce(sum(yes_pool + no_pool), 0) from mazzobet.markets where session_id = v and status in ('open','closed')),
        'open', now() >= to_timestamp(mazzobet.cfg('banco_inizio')::double precision),
        'events', coalesce((select jsonb_agg(jsonb_build_object(
              'id', e.id, 'at', e.at, 'kind', e.kind, 'amount', e.amount,
              'teams', (select coalesce(jsonb_agg(t.name order by t.name), '[]'::jsonb) from mazzobet.teams t where t.id = any (coalesce(e.teams, '{}')))) order by e.id desc)
            from (select * from mazzobet.bank_events where session_id = v order by id desc limit 5) e), '[]'::jsonb))
  ) into v_out;
  return v_out;
end $$;

-- ---------------------------------------------------------------- annuncio dalla Regia

create function public.mb_admin_set_tv(p_text text, p_minutes int default 10) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_t text := btrim(coalesce(p_text, ''));
begin
  if v is null then raise exception 'no_session'; end if;
  if char_length(v_t) > 140 or p_minutes is null or p_minutes < 1 or p_minutes > 240 then raise exception 'bad_param'; end if;
  if v_t = '' then
    update mazzobet.game_sessions set tv_message = null, tv_message_until = null where id = v;
    perform mazzobet.alog(v, 'annuncio_tv_tolto', '{}'::jsonb);
  else
    update mazzobet.game_sessions set tv_message = v_t, tv_message_until = now() + make_interval(mins => p_minutes) where id = v;
    perform mazzobet.alog(v, 'annuncio_tv', jsonb_build_object('testo', v_t, 'minuti', p_minutes));
  end if;
  return public.mb_admin_state();
end $$;

-- Lo stato della Regia mostra anche l'annuncio in corso.
create or replace function public.mb_admin_state() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  return jsonb_build_object(
    'now', now(),
    'sessions', mazzobet.admin_status(),
    'session', (select jsonb_build_object('id', g.id, 'name', g.name, 'status', g.status, 'endsAt', g.ends_at,
                                          'bankPaused', g.bank_paused, 'bankNextAt', g.bank_next_at, 'sponsorNextAt', g.sponsor_next_at)
                  from mazzobet.game_sessions g where g.id = v),
    'tvMessage', (select case when g.tv_message is not null and g.tv_message_until > now()
                              then jsonb_build_object('text', g.tv_message, 'until', g.tv_message_until) end
                    from mazzobet.game_sessions g where g.id = v),
    'bankStart', to_timestamp(mazzobet.cfg('banco_inizio')::double precision),
    'bankOpen', now() >= to_timestamp(mazzobet.cfg('banco_inizio')::double precision),
    'params', jsonb_build_object(
        'saldo_iniziale', mazzobet.cfg('saldo_iniziale'),
        'riammissione_saldo', mazzobet.cfg('riammissione_saldo'),
        'finestra_esito_min', (mazzobet.cfg('precedenza_creatore_sec') + mazzobet.cfg('finestra_esito_sec')) / 60,
        'precedenza_creatore_min', mazzobet.cfg('precedenza_creatore_sec') / 60,
        'banco_importo_min', mazzobet.cfg('banco_importo_min'),
        'banco_importo_max', mazzobet.cfg('banco_importo_max'),
        'colletta_importo', mazzobet.cfg('colletta_importo')),
    'teams', coalesce((select jsonb_agg(jsonb_build_object(
          'id', t.id, 'name', t.name, 'entered', st.team_id is not null,
          'balance', st.balance, 'status', st.status,
          'devices', (select count(*) from mazzobet.team_devices d where d.session_id = v and d.team_id = t.id)) order by t.id)
        from mazzobet.teams t left join mazzobet.session_teams st on st.team_id = t.id and st.session_id = v), '[]'::jsonb),
    'markets', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'no', m.market_no, 'question', m.question, 'by', t.name, 'byTeamId', m.creator_team_id,
          'status', m.status, 'outcome', m.outcome, 'flipped', m.flipped, 'byAdmin', m.resolved_by_admin,
          'expiresAt', m.scheduled_close_at, 'creatorOnlyUntil', m.creator_only_until, 'resolveBy', m.resolve_by,
          'yesPool', m.yes_pool, 'noPool', m.no_pool) order by m.market_no desc)
        from (select * from mazzobet.markets where session_id = v order by market_no desc limit 40) m
        join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object(
          'id', l.id, 'at', l.at, 'action', l.action, 'detail', l.detail, 'marketId', l.market_id, 'teamId', l.team_id,
          'marketNo', (select market_no from mazzobet.markets where id = l.market_id), 'team', (select name from mazzobet.teams where id = l.team_id))
        order by l.id desc)
        from (select * from mazzobet.admin_log order by id desc limit 60) l), '[]'::jsonb)
  );
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
