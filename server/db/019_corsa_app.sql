-- Corsa simulata (fase 2): la corsa compare nello stato dell'app, nella Regia e sulla TV.
-- Le scommesse della corsa non hanno creatore: prima venivano scartate dal join, ora entrano con «by» vuoto.
-- Nessun esito e nessuna notizia futura passa da queste funzioni: solo orologio, scommesse già aperte e ultime notizie uscite.

-- Orologio di gara per i telefoni (leggero: la cronaca completa sta in mb_race_state).
create function mazzobet.race_clock(p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_def mazzobet.race_defs; v_run mazzobet.race_runs;
begin
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then return jsonb_build_object('loaded', false); end if;
  select * into v_run from mazzobet.race_runs where session_id = p_session;
  return jsonb_build_object('loaded', true, 'name', v_def.name, 'edition', v_def.edition, 'distanceKm', v_def.distance_km,
    'durationSeconds', v_def.duration_seconds, 'status', coalesce(v_run.status, 'not_started'),
    'elapsed', case when v_run.session_id is null then 0 else mazzobet.race_elapsed(p_session) end);
end $$;

-- Pannello per lo schermo: orologio e ultime notizie (solo quelle già uscite).
create function mazzobet.race_tv(p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_clock jsonb := mazzobet.race_clock(p_session);
begin
  if not (v_clock->>'loaded')::boolean or v_clock->>'status' = 'not_started' then return v_clock; end if;
  return v_clock || jsonb_build_object('feed', coalesce((select jsonb_agg(jsonb_build_object(
      'id', f.event_id, 'at', f.at_seconds, 'km', f.km, 'kmEvent', f.km_is_event_location,
      'kmApprox', f.km_approximate, 'type', f.type, 'text', f.text) order by f.at_seconds desc, f.seq desc)
    from (select * from mazzobet.race_feed where session_id = p_session order by at_seconds desc, seq desc limit 8) f), '[]'::jsonb));
end $$;

-- Pannello per la Regia: orologio, numero di notizie uscite e puntate raccolte.
create function mazzobet.race_admin(p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_clock jsonb := mazzobet.race_clock(p_session);
begin
  if not (v_clock->>'loaded')::boolean then return v_clock; end if;
  return v_clock || jsonb_build_object(
    'published', (select count(*) from mazzobet.race_feed where session_id = p_session),
    'totalEvents', (select count(*) from mazzobet.race_events e join mazzobet.race_defs d on d.race_id = e.race_id
                     where d.race_id = (select race_id from mazzobet.race_defs order by loaded_at desc limit 1)),
    'bets', (select count(*) from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id
              where m.session_id = p_session and m.race_market_id is not null));
end $$;

-- ---------------------------------------------------------------- stato dei telefoni

create or replace function public.mb_get_state(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_out jsonb;
begin
  select * into v_s, v_t from mazzobet.who_ro(p_token);
  select jsonb_build_object(
    'now', now(),
    'session', (select jsonb_build_object('id', id, 'status', status, 'endsAt', ends_at)
                  from mazzobet.game_sessions where id = v_s),
    'config', jsonb_build_object(
        'betMin', mazzobet.cfg('puntata_minima'), 'createFee', mazzobet.cfg('costo_creazione'),
        'oddsMin', mazzobet.cfg('quota_min'), 'oddsMax', mazzobet.cfg('quota_max'),
        'feePct', mazzobet.cfg('compenso_percentuale'), 'feeCap', mazzobet.cfg('compenso_tetto'),
        'feeOtherPct', mazzobet.cfg('compenso_altro_percentuale'),
        'creatorPriorityMin', mazzobet.cfg('precedenza_creatore_sec') / 60,
        'resolveWindowMin', mazzobet.cfg('finestra_esito_sec') / 60,
        'appealMin', mazzobet.cfg('contestazione_sec') / 60,
        'bankruptThreshold', mazzobet.cfg('bancarotta_soglia'), 'readmitBalance', mazzobet.cfg('riammissione_saldo')),
    'race', mazzobet.race_clock(v_s),
    'me', (select jsonb_build_object('teamId', st.team_id, 'name', t.name, 'balance', st.balance,
                                     'status', st.status, 'bankruptUntil', st.bankrupt_until,
                                     'readmissions', st.readmissions, 'correct', st.correct_picks)
             from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id
            where st.session_id = v_s and st.team_id = v_t),
    'markets', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'no', m.market_no, 'question', m.question,
          'byTeamId', m.creator_team_id, 'by', t.name,
          'raceId', m.race_market_id, 'awaiting', m.race_awaiting,
          'opensAt', (select rm.opens_at from mazzobet.race_markets rm join mazzobet.race_runs rr on rr.race_id = rm.race_id and rr.session_id = m.session_id where rm.id = m.race_market_id),
          'closesAt', (select rm.closes_at from mazzobet.race_markets rm join mazzobet.race_runs rr on rr.race_id = rm.race_id and rr.session_id = m.session_id where rm.id = m.race_market_id),
          'yesOdds', m.yes_odds, 'noOdds', m.no_odds,
          'createdAt', m.created_at, 'expiresAt', m.scheduled_close_at,
          'status', m.status, 'resolveBy', m.resolve_by, 'creatorOnlyUntil', m.creator_only_until,
          'outcome', m.outcome, 'flipped', m.flipped, 'byAdmin', m.resolved_by_admin,
          'appealUntil', m.appeal_deadline_at, 'yesPool', m.yes_pool, 'noPool', m.no_pool,
          'feeCreator', least(floor((m.yes_pool + m.no_pool) * mazzobet.cfg('compenso_percentuale') / 100), mazzobet.cfg('compenso_tetto')),
          'feeOther', floor(least(floor((m.yes_pool + m.no_pool) * mazzobet.cfg('compenso_percentuale') / 100), mazzobet.cfg('compenso_tetto'))
                            * mazzobet.cfg('compenso_altro_percentuale') / 100),
          'feeAmount', m.fee_amount, 'feeTeamId', m.fee_team_id, 'feePaid', m.fee_paid_at is not null,
          'my', (select jsonb_build_object('side', b.side, 'amount', b.amount, 'result', b.result, 'payout', b.payout,
                                           'appealed', exists (select 1 from mazzobet.appeals a where a.market_id = m.id and a.team_id = v_t))
                   from mazzobet.bets b where b.market_id = m.id and b.team_id = v_t))
        order by m.market_no desc)
        from (select * from mazzobet.markets where session_id = v_s order by market_no desc limit 200) m
        left join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object(
          'id', le.id, 'at', le.created_at, 'kind', lt.kind, 'marketNo', mk.market_no, 'amount', le.amount)
        order by le.id desc)
        from (select * from mazzobet.ledger_entries
               where session_id = v_s and team_id = v_t order by id desc limit 100) le
        join mazzobet.ledger_transactions lt on lt.id = le.transaction_id
        left join mazzobet.markets mk on mk.id = lt.market_id), '[]'::jsonb),
    'news', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'at', n.at, 'kind', n.kind, 'title', n.title, 'text', n.body)
                                       order by n.id desc)
        from (select * from mazzobet.news where session_id = v_s order by id desc limit 50) n), '[]'::jsonb),
    'leaderboard', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', st.team_id, 'name', t.name, 'balance', st.balance, 'correct', st.correct_picks,
          'bankruptcies', st.bankruptcies, 'readmissions', st.readmissions))
        from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id
        where st.session_id = v_s), '[]'::jsonb),
    'bank', jsonb_build_object(
        'cash', (select coalesce(sum(amount), 0) from mazzobet.ledger_entries
                  where session_id = v_s and account = 'bank'),
        'inPlay', (select coalesce(sum(yes_pool + no_pool), 0) from mazzobet.markets
                    where session_id = v_s and status in ('open','closed')))
  ) into v_out;
  return v_out;
end $$;

-- ---------------------------------------------------------------- schermo (TV)

create or replace function public.mb_get_tv() returns jsonb
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
    'race', mazzobet.race_tv(v),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('teamId', st.team_id, 'name', t.name, 'balance', st.balance, 'status', st.status)
                                        order by st.balance desc, t.name)
        from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id where st.session_id = v), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(jsonb_build_object(
          'no', m.market_no, 'question', m.question, 'by', coalesce(t.name, 'La Teramana'), 'race', m.race_market_id is not null, 'yesOdds', m.yes_odds, 'noOdds', m.no_odds,
          'expiresAt', m.scheduled_close_at, 'yesPool', m.yes_pool, 'noPool', m.no_pool,
          'bets', (select count(*) from mazzobet.bets b where b.market_id = m.id)) order by m.scheduled_close_at)
        from (select * from mazzobet.markets where session_id = v and status = 'open' order by scheduled_close_at limit 8) m
        left join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'waiting', coalesce((select jsonb_agg(jsonb_build_object(
          'no', m.market_no, 'question', m.question, 'by', coalesce(t.name, 'La Teramana'), 'race', m.race_market_id is not null, 'resolveBy', m.resolve_by,
          'yesPool', m.yes_pool, 'noPool', m.no_pool) order by m.resolve_by)
        from (select * from mazzobet.markets where session_id = v and status = 'closed' order by resolve_by limit 6) m
        left join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'results', coalesce((select jsonb_agg(jsonb_build_object(
          'no', m.market_no, 'question', m.question, 'by', coalesce(t.name, 'La Teramana'), 'race', m.race_market_id is not null, 'outcome', m.outcome, 'flipped', m.flipped,
          'byAdmin', m.resolved_by_admin, 'yesPool', m.yes_pool, 'noPool', m.no_pool, 'at', m.resolved_at,
          'best', (select jsonb_build_object('name', bt.name, 'payout', b.payout)
                     from mazzobet.bets b join mazzobet.teams bt on bt.id = b.team_id
                    where b.market_id = m.id and b.result = 'win' order by b.payout desc limit 1)) order by m.resolved_at desc)
        from (select * from mazzobet.markets where session_id = v and status = 'resolved' order by resolved_at desc limit 6) m
        left join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
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

-- ---------------------------------------------------------------- Regia

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
    'race', mazzobet.race_admin(v),
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
          'id', m.id, 'no', m.market_no, 'question', m.question, 'by', coalesce(t.name, 'La Teramana'), 'raceId', m.race_market_id, 'byTeamId', m.creator_team_id,
          'status', m.status, 'outcome', m.outcome, 'flipped', m.flipped, 'byAdmin', m.resolved_by_admin,
          'expiresAt', m.scheduled_close_at, 'creatorOnlyUntil', m.creator_only_until, 'resolveBy', m.resolve_by,
          'yesPool', m.yes_pool, 'noPool', m.no_pool) order by m.market_no desc)
        from (select * from mazzobet.markets where session_id = v order by market_no desc limit 40) m
        left join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
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
