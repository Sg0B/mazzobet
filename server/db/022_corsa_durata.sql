-- Corsa simulata: durata scelta dalla Regia prima del via (per le prove con gli amici senza aspettare 3 ore).
-- Parametro `corsa_durata_min` (default 180 = tempo reale, valori da 5 a 180). Al via la velocità diventa 180 / durata
-- (es. 18 minuti = ×10): tempo di gara, aperture, chiusure e notizie scorrono più veloci in modo identico per tutti.
-- Si può cambiare solo prima del via. Il valore resta valido anche per le serate dopo: la Regia lo mostra sempre, evidenziato se non è 180.

insert into mazzobet.config (key, value, note) values ('corsa_durata_min', 180, 'minuti: durata reale della corsa, 180 = tempo normale')
on conflict (key) do nothing;

create or replace function mazzobet.race_clock(p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_def mazzobet.race_defs; v_run mazzobet.race_runs;
begin
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then return jsonb_build_object('loaded', false); end if;
  select * into v_run from mazzobet.race_runs where session_id = p_session;
  return jsonb_build_object('loaded', true, 'name', v_def.name, 'edition', v_def.edition, 'distanceKm', v_def.distance_km,
    'durationSeconds', v_def.duration_seconds, 'status', coalesce(v_run.status, 'not_started'), 'speed', coalesce(v_run.speed, 1),
    'elapsed', case when v_run.session_id is null then 0 else mazzobet.race_elapsed(p_session) end);
end $$;

create or replace function mazzobet.race_admin(p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_clock jsonb := mazzobet.race_clock(p_session);
begin
  if not (v_clock->>'loaded')::boolean then return v_clock; end if;
  return v_clock || jsonb_build_object(
    'durationMin', mazzobet.cfg('corsa_durata_min'),
    'published', (select count(*) from mazzobet.race_feed where session_id = p_session),
    'totalEvents', (select count(*) from mazzobet.race_events e join mazzobet.race_defs d on d.race_id = e.race_id
                     where d.race_id = (select race_id from mazzobet.race_defs order by loaded_at desc limit 1)),
    'bets', (select count(*) from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id
              where m.session_id = p_session and m.race_market_id is not null));
end $$;

create function public.mb_admin_race_set_duration(p_minutes int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_old numeric := mazzobet.cfg('corsa_durata_min');
begin
  if v is null then raise exception 'no_session'; end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 180 then raise exception 'bad_param'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  if exists (select 1 from mazzobet.race_runs where session_id = v and status <> 'not_started') then raise exception 'race_already_started'; end if;
  update mazzobet.config set value = p_minutes where key = 'corsa_durata_min';
  perform mazzobet.alog(v, 'corsa_durata', jsonb_build_object('prima', v_old, 'dopo', p_minutes));
  return public.mb_admin_state();
end $$;

create or replace function public.mb_admin_race_start() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_def mazzobet.race_defs; v_run mazzobet.race_runs; v_speed numeric;
begin
  if v is null then raise exception 'no_session'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then raise exception 'race_not_loaded'; end if;
  insert into mazzobet.race_runs (session_id, race_id) values (v, v_def.race_id) on conflict (session_id) do nothing;
  select * into v_run from mazzobet.race_runs where session_id = v for update;
  if v_run.status <> 'not_started' then raise exception 'race_already_started'; end if;
  -- durata scelta dalla Regia prima del via (180 = tempo reale); sotto i 180 minuti la corsa scorre più veloce
  v_speed := greatest(1, v_def.duration_seconds / (mazzobet.cfg('corsa_durata_min') * 60));
  update mazzobet.race_runs set status = 'running', started_at = now(), speed = v_speed where session_id = v;
  perform mazzobet.alog(v, 'corsa_avvio', jsonb_build_object('corsa', v_def.race_id, 'durata_min', mazzobet.cfg('corsa_durata_min'), 'velocita', v_speed));
  perform mazzobet.race_tick(v);   -- esce subito la notizia di partenza e si apre la prima scommessa
  return public.mb_admin_race_state();
end $$;

create or replace function public.mb_race_state(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_def mazzobet.race_defs; v_run mazzobet.race_runs;
begin
  select * into v_s, v_t from mazzobet.who_ro(p_token);
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then return jsonb_build_object('now', now(), 'loaded', false); end if;
  select * into v_run from mazzobet.race_runs where session_id = v_s;
  return jsonb_build_object(
    'now', now(), 'loaded', true, 'name', v_def.name, 'edition', v_def.edition, 'distanceKm', v_def.distance_km,
    'durationSeconds', v_def.duration_seconds, 'speed', coalesce(v_run.speed, 1),
    'status', coalesce(v_run.status, 'not_started'),
    'elapsed', case when v_run.session_id is null then 0 else mazzobet.race_elapsed(v_s) end,
    'feed', coalesce((select jsonb_agg(jsonb_build_object(
          'id', f.event_id, 'at', f.at_seconds, 'km', f.km, 'kmEvent', f.km_is_event_location,
          'kmApprox', f.km_approximate, 'type', f.type, 'text', f.text) order by f.at_seconds desc, f.seq desc)
        from mazzobet.race_feed f where f.session_id = v_s), '[]'::jsonb),
    -- solo le scommesse già aperte; closesAt (secondi di gara) serve al conto alla rovescia
    'markets', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'raceId', m.race_market_id, 'no', m.market_no, 'question', m.question,
          'yesOdds', m.yes_odds, 'noOdds', m.no_odds, 'status', m.status, 'awaiting', m.race_awaiting,
          'opensAt', rm.opens_at, 'closesAt', rm.closes_at,
          'outcome', m.outcome,
          'my', (select jsonb_build_object('side', b.side, 'amount', b.amount, 'result', b.result, 'payout', b.payout)
                   from mazzobet.bets b where b.market_id = m.id and b.team_id = v_t)) order by rm.seq)
        from mazzobet.markets m join mazzobet.race_markets rm on rm.race_id = v_def.race_id and rm.id = m.race_market_id
       where m.session_id = v_s and m.race_market_id is not null), '[]'::jsonb));
end $$;

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
