-- Corsa simulata «La Teramana» (PRD v1.2): orologio di gara, notizie, scommesse, liquidazione, pausa e interruzione.
-- Tutto si basa sull'orologio di gara del DATABASE (partenza − pausa), mai su orologi dei telefoni né su timer in memoria:
-- dopo un riavvio del server il primo passo recupera in ordine ciò che è maturato, senza duplicati.
-- Le scommesse della corsa sono righe di `markets` con race_market_id e senza creatore; i pagamenti usano lo stesso
-- ledger (chiave unica win:<puntata>) delle scommesse normali.

-- ---------------------------------------------------------------- orologio di gara

-- Secondi di gara trascorsi (con la pausa tolta). Fermo in pausa, a corsa finita o interrotta.
create function mazzobet.race_elapsed(p_session uuid) returns double precision
language sql stable set search_path = '' as $$
  select case r.status
    when 'running'  then least(d.duration_seconds, greatest(0, (extract(epoch from now() - r.started_at) - r.paused_secs) * r.speed))
    when 'paused'   then least(d.duration_seconds, greatest(0, (extract(epoch from r.paused_at - r.started_at) - r.paused_secs) * r.speed))
    when 'aborted'  then least(d.duration_seconds, greatest(0, (extract(epoch from r.paused_at - r.started_at) - r.paused_secs) * r.speed))
    when 'finished' then d.duration_seconds::double precision
    else 0::double precision end
  from mazzobet.race_runs r join mazzobet.race_defs d on d.race_id = r.race_id
 where r.session_id = p_session
$$;

-- ---------------------------------------------------------------- liquidazione di una scommessa della corsa

-- Una sola volta: se la scommessa non è più aperta/chiusa, non fa nulla. Chiude le puntate se erano ancora aperte.
-- Nessun compenso, nessun ricorso, nessuna contestazione.
create function mazzobet.race_settle(p_market bigint, p_outcome text) returns void
language plpgsql set search_path = '' as $$
declare v_m mazzobet.markets; v_bet record; v_pay bigint; v_best bigint := 0; v_best_team smallint; v_name text;
begin
  select * into v_m from mazzobet.markets where id = p_market for update;
  if not found or v_m.race_market_id is null then raise exception 'market_not_found'; end if;
  if v_m.status not in ('open','closed') then return; end if;
  if p_outcome not in ('yes','no') then raise exception 'invalid_side'; end if;

  update mazzobet.markets
     set status = 'resolved', outcome = p_outcome, resolved_at = now(),
         actual_closed_at = coalesce(actual_closed_at, now()),
         appeal_deadline_at = now() - interval '1 second',
         race_awaiting = false
   where id = p_market;

  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    if v_bet.side = p_outcome then
      v_pay := floor(v_bet.amount * v_bet.odds_cents / 100.0);
      perform mazzobet.transfer(v_m.session_id, 'win', 'win:' || v_bet.id, p_market, 'bank', null, 'team', v_bet.team_id, v_pay);
      update mazzobet.bets set result = 'win', payout = v_pay where id = v_bet.id;
      update mazzobet.session_teams set correct_picks = correct_picks + 1
       where session_id = v_m.session_id and team_id = v_bet.team_id;
      if v_pay > v_best then v_best := v_pay; v_best_team := v_bet.team_id; end if;
    else
      update mazzobet.bets set result = 'loss', payout = 0 where id = v_bet.id;
    end if;
  end loop;

  for v_bet in select team_id from mazzobet.bets where market_id = p_market order by team_id loop
    perform mazzobet.check_bankruptcy(v_m.session_id, v_bet.team_id);
  end loop;

  if v_best >= mazzobet.cfg('grande_vincita_soglia') then
    select name into v_name from mazzobet.teams where id = v_best_team;
    perform mazzobet.post_news(v_m.session_id, 'radiocorsa', 'grande_vincita',
            jsonb_build_object('nomeSquadra', v_name, 'importo', mazzobet.fmt(v_best)), 'bank', 'bigwin:' || p_market);
  end if;
  perform mazzobet.settle(v_m.session_id);
end $$;

-- ---------------------------------------------------------------- un passo della corsa

-- In quest'ordine: notizie maturate, aperture, chiusure, liquidazioni, fine corsa. Idempotente: si può chiamare quando si vuole.
create function mazzobet.race_tick(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_run mazzobet.race_runs; v_def mazzobet.race_defs; v_e double precision; v_rm record; v_no int; v_out text;
  v_km numeric;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_session::text, 0));
  select * into v_run from mazzobet.race_runs where session_id = p_session for update;
  if not found or v_run.status <> 'running' then return; end if;
  if (select status from mazzobet.game_sessions where id = p_session) <> 'active' then return; end if;
  select * into v_def from mazzobet.race_defs where race_id = v_run.race_id;
  v_e := mazzobet.race_elapsed(p_session);

  -- 1. notizie maturate (anche più d'una dopo un'interruzione del server): escono tutte, l'ordine è at_seconds poi seq
  insert into mazzobet.race_feed (session_id, event_id, seq, at_seconds, km, km_is_event_location, km_approximate, type, text)
  select p_session, e.id, e.seq, e.at_seconds, e.km, e.km_is_event_location, e.km_approximate, e.type, e.text
    from mazzobet.race_events e
   where e.race_id = v_run.race_id and e.at_seconds <= v_e
   order by e.at_seconds, e.seq
  on conflict do nothing;

  -- 2. aperture: la riga di `markets` nasce solo ora, con le quote fisse del palinsesto
  for v_rm in select rm.* from mazzobet.race_markets rm
               where rm.race_id = v_run.race_id and rm.opens_at <= v_e
                 and not exists (select 1 from mazzobet.markets m where m.session_id = p_session and m.race_market_id = rm.id)
               order by rm.opens_at, rm.seq loop
    update mazzobet.game_sessions set next_market_no = next_market_no + 1 where id = p_session
     returning next_market_no - 1 into v_no;
    insert into mazzobet.markets (session_id, market_no, creator_team_id, question, yes_odds, no_odds,
                                  scheduled_close_at, idempotency_key, race_market_id)
    values (p_session, v_no, null, v_rm.question, v_rm.yes_odds, v_rm.no_odds,
            now() + make_interval(secs => greatest(0, v_rm.closes_at - v_e) / v_run.speed),
            'race:' || v_rm.id, v_rm.id);
  end loop;

  -- 3. chiusure: da qui mb_place_bet rifiuta (lo controlla comunque da sé sull'orologio di gara)
  update mazzobet.markets m
     set status = 'closed', actual_closed_at = now()
    from mazzobet.race_markets rm
   where m.session_id = p_session and m.race_market_id = rm.id and rm.race_id = v_run.race_id
     and m.status = 'open' and rm.closes_at <= v_e;

  -- 4. liquidazioni, dopo che la notizia che decide è già nella cronaca pubblicata
  for v_rm in select rm.*, m.id as market_id, m.race_awaiting as awaiting
                from mazzobet.race_markets rm
                join mazzobet.markets m on m.session_id = p_session and m.race_market_id = rm.id
               where rm.race_id = v_run.race_id and m.status in ('open','closed')
               order by rm.seq loop
    v_out := null;
    if v_rm.settlement->>'mode' = 'on_published_result' then
      if exists (select 1 from mazzobet.race_feed f where f.session_id = p_session and f.event_id = v_rm.settlement->>'event_id') then
        v_out := v_rm.winning;
      end if;
    elsif v_rm.settlement->>'mode' = 'official_result_after_provisional' then
      if exists (select 1 from mazzobet.race_feed f where f.session_id = p_session and f.event_id = v_rm.settlement->>'official_event_id') then
        v_out := v_rm.winning;
      elsif not v_rm.awaiting
        and exists (select 1 from mazzobet.race_feed f where f.session_id = p_session and f.event_id = v_rm.settlement->>'provisional_event_id') then
        update mazzobet.markets set race_awaiting = true, status = 'closed', actual_closed_at = coalesce(actual_closed_at, now())
         where id = v_rm.market_id;
      end if;
    elsif v_rm.settlement->>'mode' = 'first_matching_event_or_deadline' then
      v_km := (v_rm.settlement->>'no_if_no_matching_event_by_km')::numeric;
      if exists (select 1 from mazzobet.race_feed f join mazzobet.race_events e on e.race_id = v_run.race_id and e.id = f.event_id
                  where f.session_id = p_session and e.is_puncture and e.at_seconds >= v_rm.opens_at and e.km <= v_km) then
        v_out := 'yes';
      elsif exists (select 1 from mazzobet.race_feed f where f.session_id = p_session and not f.km_is_event_location and f.km > v_km) then
        v_out := 'no';
      end if;
    end if;
    if v_out is not null then perform mazzobet.race_settle(v_rm.market_id, v_out); end if;
  end loop;

  -- 5. fine corsa: ultima notizia uscita e tutte le scommesse liquidate
  if v_e >= v_def.duration_seconds
     and not exists (select 1 from mazzobet.race_events e where e.race_id = v_run.race_id
                      and not exists (select 1 from mazzobet.race_feed f where f.session_id = p_session and f.event_id = e.id))
     and not exists (select 1 from mazzobet.race_markets rm where rm.race_id = v_run.race_id
                      and not exists (select 1 from mazzobet.markets m where m.session_id = p_session and m.race_market_id = rm.id and m.status not in ('open','closed')))
  then
    update mazzobet.race_runs set status = 'finished', finished_at = now() where session_id = p_session;
  end if;
end $$;

-- Interruzione (chiusura o reset della serata): la corsa si ferma e le puntate non decise tornano ai giocatori.
create function mazzobet.race_abort(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare v_r record; v_n int;
begin
  update mazzobet.race_runs set status = 'aborted', paused_at = coalesce(paused_at, now())
   where session_id = p_session and status in ('running','paused');
  get diagnostics v_n = row_count;
  if v_n > 0 then
    for v_r in select id from mazzobet.markets
                where session_id = p_session and race_market_id is not null and status in ('open','closed') order by id loop
      perform mazzobet.void_market(v_r.id);
    end loop;
    perform mazzobet.alog(p_session, 'corsa_interrotta', '{}'::jsonb);
  end if;
end $$;

-- ---------------------------------------------------------------- scadenze normali: le scommesse della corsa non ne hanno

create or replace function mazzobet.refresh_deadlines(p_session uuid) returns void
language sql set search_path = '' as $$
  update mazzobet.markets m
     set creator_only_until = m.scheduled_close_at + mazzobet.dur(p_session, mazzobet.cfg('precedenza_creatore_sec')::double precision),
         resolve_by = m.scheduled_close_at + mazzobet.dur(p_session, (mazzobet.cfg('precedenza_creatore_sec') + mazzobet.cfg('finestra_esito_sec'))::double precision)
   where m.session_id = p_session and m.status = 'closed' and m.race_market_id is null
$$;

-- mb_tick = quello della 011, con tre aggiunte segnate «CORSA»: non chiude/svuota/annulla le scommesse della corsa
-- (le governa solo race_tick), fa girare un passo della corsa, e interrompe la corsa se la serata sta chiudendo.
create or replace function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_sess uuid; v_m record; v_gs record; v_open boolean; v_start timestamptz; v_n int;
  v_closed int := 0; v_void int := 0; v_bank int := 0; v_sponsor int := 0; v_final int := 0;
  v_prec double precision := mazzobet.cfg('precedenza_creatore_sec')::double precision;
  v_win double precision := mazzobet.cfg('finestra_esito_sec')::double precision;
begin
  for v_sess in select id from mazzobet.game_sessions where status in ('active','paused','closing') loop
    perform pg_advisory_xact_lock(hashtextextended(v_sess::text, 0));

    for v_m in select m.id, exists (select 1 from mazzobet.bets b where b.market_id = m.id) as has_bets
                 from mazzobet.markets m
                where m.session_id = v_sess and m.status = 'open' and m.scheduled_close_at <= now()
                  and m.race_market_id is null                                   -- CORSA
                order by m.id loop
      if v_m.has_bets then
        update mazzobet.markets
           set status = 'closed', actual_closed_at = scheduled_close_at,
               creator_only_until = scheduled_close_at + mazzobet.dur(v_sess, v_prec),
               resolve_by = scheduled_close_at + mazzobet.dur(v_sess, v_prec + v_win)
         where id = v_m.id;
      else
        update mazzobet.markets set status = 'empty', actual_closed_at = scheduled_close_at, resolved_at = now() where id = v_m.id;
      end if;
      v_closed := v_closed + 1;
    end loop;

    perform mazzobet.refresh_deadlines(v_sess);

    for v_m in select id from mazzobet.markets
                where session_id = v_sess and status = 'closed' and resolve_by <= now()
                  and race_market_id is null                                     -- CORSA
                order by id loop
      perform mazzobet.void_market(v_m.id);
      v_void := v_void + 1;
    end loop;

    perform mazzobet.pay_fees(v_sess);

    select status, bank_next_at, sponsor_next_at, bank_paused, bank_open_announced, created_at into v_gs
      from mazzobet.game_sessions where id = v_sess;

    if v_gs.status = 'closing' then perform mazzobet.race_abort(v_sess);          -- CORSA
    else perform mazzobet.race_tick(v_sess);                                      -- CORSA
    end if;

    v_start := to_timestamp(mazzobet.cfg('banco_inizio')::double precision);
    v_open := now() >= v_start;

    if not v_open then
      if v_gs.bank_next_at is not null or v_gs.sponsor_next_at is not null then
        update mazzobet.game_sessions set bank_next_at = null, sponsor_next_at = null where id = v_sess;
        v_gs.bank_next_at := null; v_gs.sponsor_next_at := null;
      end if;
    elsif v_gs.status <> 'closing' then
      if not v_gs.bank_open_announced then
        update mazzobet.game_sessions set bank_open_announced = true where id = v_sess;
        if v_gs.created_at < v_start then
          insert into mazzobet.news (session_id, kind, title, body, ref)
          select v_sess, 'bank', t.title, t.body, 'bank_open:' || v_sess
            from (values
              ('SI APRE IL BANCO', 'Il Banco è ufficialmente aperto. D''ora in poi bonus, malus e sponsor possono colpire senza preavviso: Carletti in tasca e gambe in sella.'),
              ('SEGNALE DI PARTENZA', 'La direzione di corsa dà il via al Banco: bonus, malus e sponsor sono in strada. Buona fortuna, gregari.'),
              ('ORA DI CENA, ORA DI BANCO', 'Il Banco prende servizio. Da qui a fine serata qualcuno riceverà, qualcuno pagherà e nessuno potrà dire di non essere stato avvisato.')
            ) as t(title, body) order by random() limit 1;
        end if;
      end if;
      if v_gs.bank_next_at is null then
        select count(*) into v_n from mazzobet.session_teams where session_id = v_sess;
        if v_n >= mazzobet.cfg('banco_squadre_per_avvio') then
          update mazzobet.game_sessions
             set bank_next_at = mazzobet.next_bank_at(v_sess), sponsor_next_at = mazzobet.next_sponsor_at(v_sess)
           where id = v_sess;
          select bank_next_at, sponsor_next_at into v_gs.bank_next_at, v_gs.sponsor_next_at
            from mazzobet.game_sessions where id = v_sess;
        end if;
      end if;
      if not v_gs.bank_paused then
        if v_gs.bank_next_at is not null and v_gs.bank_next_at <= now() then
          perform mazzobet.run_bank_event(v_sess);
          update mazzobet.game_sessions set bank_next_at = mazzobet.next_bank_at(v_sess) where id = v_sess;
          v_bank := v_bank + 1;
        end if;
        if v_gs.sponsor_next_at is not null and v_gs.sponsor_next_at <= now() then
          perform mazzobet.run_sponsor_event(v_sess);
          update mazzobet.game_sessions set sponsor_next_at = mazzobet.next_sponsor_at(v_sess) where id = v_sess;
          v_sponsor := v_sponsor + 1;
        end if;
      end if;
    end if;

    perform mazzobet.settle(v_sess);
    if v_gs.status = 'closing' and mazzobet.try_finalize(v_sess) then v_final := v_final + 1; end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void, 'bank', v_bank, 'sponsor', v_sponsor, 'finalized', v_final);
end $$;

-- ---------------------------------------------------------------- puntare sulla corsa

-- mb_place_bet = quello della 010, con il solo controllo della corsa in più (segnato «CORSA»).
create or replace function public.mb_place_bet(p_token uuid, p_market bigint, p_side text, p_amount bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_m mazzobet.markets; v_bet mazzobet.bets;
  v_row mazzobet.session_teams; v_odds int; v_id bigint;
  v_rs text; v_close int;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;

  select * into v_bet from mazzobet.bets where market_id = p_market and team_id = v_t;
  if found then
    if v_bet.side = p_side and v_bet.amount = p_amount then
      return jsonb_build_object('betId', v_bet.id, 'replay', true);
    end if;
    raise exception 'already_bet';
  end if;

  if (select status from mazzobet.game_sessions where id = v_s) = 'closed' then raise exception 'session_closed'; end if;

  if v_m.race_market_id is not null then                                           -- CORSA
    select r.status, rm.closes_at into v_rs, v_close
      from mazzobet.race_runs r join mazzobet.race_markets rm on rm.race_id = r.race_id and rm.id = v_m.race_market_id
     where r.session_id = v_s;
    if v_rs = 'paused' then raise exception 'race_paused'; end if;
    if v_rs is distinct from 'running' or v_m.status <> 'open' or mazzobet.race_elapsed(v_s) >= v_close then
      raise exception 'market_closed';                                             -- chiude l'orologio di gara del server
    end if;
  elsif v_m.status <> 'open' or v_m.scheduled_close_at <= now() then raise exception 'market_closed';
  end if;

  if v_m.creator_team_id = v_t then raise exception 'own_market'; end if;
  if p_side not in ('yes','no') then raise exception 'invalid_side'; end if;
  if p_amount is null or p_amount < mazzobet.cfg('puntata_minima') then raise exception 'invalid_amount'; end if;

  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'in_game' then raise exception 'bankrupt'; end if;
  if v_row.balance < p_amount then raise exception 'insufficient_funds'; end if;

  v_odds := case p_side when 'yes' then v_m.yes_odds else v_m.no_odds end;
  insert into mazzobet.bets (session_id, market_id, team_id, side, amount, odds_cents)
  values (v_s, p_market, v_t, p_side, p_amount, v_odds) returning id into v_id;
  update mazzobet.markets
     set yes_pool = yes_pool + case when p_side = 'yes' then p_amount else 0 end,
         no_pool  = no_pool  + case when p_side = 'no'  then p_amount else 0 end
   where id = p_market;

  perform mazzobet.transfer(v_s, 'bet', 'bet:' || v_id, p_market, 'team', v_t, 'bank', null, p_amount);
  perform mazzobet.settle(v_s);
  return jsonb_build_object('betId', v_id, 'replay', false);
end $$;

-- ---------------------------------------------------------------- esito, ricorso e rettifiche: mai sulle scommesse della corsa

-- Le funzioni di prima passano in schema mazzobet (invariate); quelle pubbliche rifiutano le scommesse della corsa.
alter function public.mb_resolve(uuid, bigint, text) set schema mazzobet;
alter function public.mb_appeal(uuid, bigint) set schema mazzobet;
alter function public.mb_admin_resolve(bigint, text) set schema mazzobet;

create function public.mb_resolve(p_token uuid, p_market bigint, p_outcome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from mazzobet.markets where id = p_market and race_market_id is not null) then raise exception 'not_resolvable'; end if;
  return mazzobet.mb_resolve(p_token, p_market, p_outcome);
end $$;

create function public.mb_appeal(p_token uuid, p_market bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from mazzobet.markets where id = p_market and race_market_id is not null) then raise exception 'not_appealable'; end if;
  return mazzobet.mb_appeal(p_token, p_market);
end $$;

create function public.mb_admin_resolve(p_market bigint, p_outcome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from mazzobet.markets where id = p_market and race_market_id is not null) then raise exception 'not_resolvable'; end if;
  return mazzobet.mb_admin_resolve(p_market, p_outcome);
end $$;

-- ---------------------------------------------------------------- caricamento della definizione (dal server, dopo la validazione)

create function public.mb_race_load(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id text := p->'race'->>'race_id'; v_ev int; v_mk int;
begin
  if v_id is null then raise exception 'bad_param'; end if;
  if exists (select 1 from mazzobet.race_runs where race_id = v_id and status <> 'not_started') then
    return jsonb_build_object('skipped', true, 'reason', 'corsa già partita: la definizione non si cambia');
  end if;
  insert into mazzobet.race_defs (race_id, name, edition, distance_km, duration_seconds)
  values (v_id, p->'race'->>'name', (p->'race'->>'edition')::int, (p->'race'->>'distance_km')::numeric, (p->'race'->>'duration_seconds')::int)
  on conflict (race_id) do update set name = excluded.name, edition = excluded.edition,
    distance_km = excluded.distance_km, duration_seconds = excluded.duration_seconds, loaded_at = now();
  delete from mazzobet.race_events  where race_id = v_id;
  delete from mazzobet.race_markets where race_id = v_id;
  insert into mazzobet.race_events (race_id, id, seq, at_seconds, km, km_is_event_location, km_approximate, block, type, text, is_puncture)
  select v_id, e->>'id', (e->>'seq')::int, (e->>'at_seconds')::int, (e->>'km')::numeric,
         coalesce((e->>'km_is_event_location')::boolean, false), coalesce((e->>'km_approximate')::boolean, false),
         (e->>'block')::int, e->>'type', e->>'text', coalesce((e->>'is_puncture')::boolean, false)
    from jsonb_array_elements(p->'events') e;
  get diagnostics v_ev = row_count;
  insert into mazzobet.race_markets (race_id, id, seq, category, question, opens_at, closes_at, yes_odds, no_odds, winning, settlement)
  select v_id, m->>'id', (m->>'seq')::int, m->>'category', m->>'question', (m->>'opens_at')::int, (m->>'closes_at')::int,
         (m->>'yes_odds')::int, (m->>'no_odds')::int, m->>'winning', m->'settlement'
    from jsonb_array_elements(p->'markets') m;
  get diagnostics v_mk = row_count;
  return jsonb_build_object('skipped', false, 'events', v_ev, 'markets', v_mk);
end $$;

-- ---------------------------------------------------------------- comandi della Regia (solo server)

create function public.mb_admin_race_state() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_def mazzobet.race_defs; v_run mazzobet.race_runs;
begin
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then return jsonb_build_object('now', now(), 'loaded', false); end if;
  select * into v_run from mazzobet.race_runs where session_id = v;   -- v nullo o corsa mai avviata: campi nulli
  return jsonb_build_object(
    'now', now(), 'loaded', true, 'name', v_def.name, 'edition', v_def.edition,
    'durationSeconds', v_def.duration_seconds,
    'status', coalesce(v_run.status, 'not_started'),
    'elapsed', case when v_run.session_id is null then 0 else mazzobet.race_elapsed(v) end,
    'published', case when v is null then 0 else (select count(*) from mazzobet.race_feed where session_id = v) end,
    'totalEvents', (select count(*) from mazzobet.race_events where race_id = v_def.race_id),
    'markets', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'raceId', m.race_market_id, 'no', m.market_no, 'question', m.question, 'status', m.status,
          'awaiting', m.race_awaiting, 'outcome', m.outcome,
          'bets', (select count(*) from mazzobet.bets b where b.market_id = m.id),
          'yesPool', m.yes_pool, 'noPool', m.no_pool) order by m.market_no)
        from mazzobet.markets m where m.session_id = v and m.race_market_id is not null), '[]'::jsonb));
end $$;

create function public.mb_admin_race_start() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_def mazzobet.race_defs; v_run mazzobet.race_runs;
begin
  if v is null then raise exception 'no_session'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then raise exception 'race_not_loaded'; end if;
  insert into mazzobet.race_runs (session_id, race_id) values (v, v_def.race_id) on conflict (session_id) do nothing;
  select * into v_run from mazzobet.race_runs where session_id = v for update;
  if v_run.status <> 'not_started' then raise exception 'race_already_started'; end if;
  update mazzobet.race_runs set status = 'running', started_at = now() where session_id = v;
  perform mazzobet.alog(v, 'corsa_avvio', jsonb_build_object('corsa', v_def.race_id));
  perform mazzobet.race_tick(v);   -- esce subito la notizia di partenza e si apre la prima scommessa
  return public.mb_admin_race_state();
end $$;

create function public.mb_admin_race_pause(p_paused boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_run mazzobet.race_runs; v_gap interval;
begin
  if v is null then raise exception 'no_session'; end if;
  if p_paused is null then raise exception 'bad_param'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  select * into v_run from mazzobet.race_runs where session_id = v for update;
  if not found then raise exception 'race_not_running'; end if;
  if p_paused then
    if v_run.status <> 'running' then raise exception 'race_not_running'; end if;
    update mazzobet.race_runs set status = 'paused', paused_at = now() where session_id = v;
    perform mazzobet.alog(v, 'corsa_pausa', '{}'::jsonb);
  else
    if v_run.status <> 'paused' then raise exception 'race_not_paused'; end if;
    v_gap := now() - v_run.paused_at;
    update mazzobet.race_runs set status = 'running', paused_secs = paused_secs + extract(epoch from v_gap), paused_at = null
     where session_id = v;
    -- i conti alla rovescia non perdono tempo: le scommesse aperte si spostano della durata della pausa
    update mazzobet.markets set scheduled_close_at = scheduled_close_at + v_gap
     where session_id = v and race_market_id is not null and status = 'open';
    perform mazzobet.alog(v, 'corsa_ripresa', jsonb_build_object('pausaSec', round(extract(epoch from v_gap))));
  end if;
  return public.mb_admin_race_state();
end $$;

-- Passo ogni secondo dal server (la corsa deve uscire puntuale; mb_tick la fa girare comunque ogni 5 secondi).
create function public.mb_race_tick() returns int
language plpgsql security definer set search_path = '' as $$
declare v uuid; n int := 0;
begin
  for v in select r.session_id from mazzobet.race_runs r join mazzobet.game_sessions g on g.id = r.session_id
            where r.status = 'running' and g.status = 'active' loop
    perform mazzobet.race_tick(v);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- lettura per i telefoni: solo ciò che è già uscito

create function public.mb_race_state(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_def mazzobet.race_defs; v_run mazzobet.race_runs;
begin
  select * into v_s, v_t from mazzobet.who_ro(p_token);
  select * into v_def from mazzobet.race_defs order by loaded_at desc limit 1;
  if v_def.race_id is null then return jsonb_build_object('now', now(), 'loaded', false); end if;
  select * into v_run from mazzobet.race_runs where session_id = v_s;
  return jsonb_build_object(
    'now', now(), 'loaded', true, 'name', v_def.name, 'edition', v_def.edition, 'distanceKm', v_def.distance_km,
    'durationSeconds', v_def.duration_seconds,
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

-- ---------------------------------------------------------------- permessi: solo il server (service_role)

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
