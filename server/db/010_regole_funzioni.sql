-- Regole del prompt v0.6 (confermate il 23/10/2026): funzioni.
-- Tutti i numeri di gioco arrivano da mazzobet.cfg(...) (tabella mazzobet.config).

-- ---------------------------------------------------------------- helper interni

create or replace function mazzobet.next_bank_at(p_session uuid) returns timestamptz
language sql set search_path = '' as $$
  select now() + mazzobet.dur(p_session,
    mazzobet.cfg('banco_intervallo_min_sec')::double precision
    + floor(random() * (mazzobet.cfg('banco_intervallo_max_sec') - mazzobet.cfg('banco_intervallo_min_sec') + 1)::double precision))
$$;

create or replace function mazzobet.next_sponsor_at(p_session uuid) returns timestamptz
language sql set search_path = '' as $$
  select now() + mazzobet.dur(p_session,
    mazzobet.cfg('sponsor_intervallo_min_sec')::double precision
    + floor(random() * (mazzobet.cfg('sponsor_intervallo_max_sec') - mazzobet.cfg('sponsor_intervallo_min_sec') + 1)::double precision))
$$;

-- Bancarotta (regola 7.A): saldo sotto soglia E nessuna puntata ancora da risolvere (scommessa aperta o in attesa di esito).
-- Chi punta tutto non fallisce finché la scommessa è in corso; se poi perde e resta sotto soglia, fallisce in quel momento.
create function mazzobet.check_bankruptcy(p_session uuid, p_team smallint) returns void
language plpgsql set search_path = '' as $$
declare v_bal bigint; v_status text; v_thr numeric := mazzobet.cfg('bancarotta_soglia');
begin
  select balance, status into v_bal, v_status from mazzobet.session_teams where session_id = p_session and team_id = p_team;
  if v_status = 'in_game' and v_bal < v_thr
     and not exists (select 1 from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id
                      where b.session_id = p_session and b.team_id = p_team and m.status in ('open','closed')) then
    update mazzobet.session_teams
       set status = 'bankrupt', bankruptcies = bankruptcies + 1,
           bankrupt_until = now() + mazzobet.dur(p_session, mazzobet.cfg('bancarotta_blocco_sec')::double precision)
     where session_id = p_session and team_id = p_team;
    insert into mazzobet.bankruptcy_events (session_id, team_id) values (p_session, p_team);
  elsif v_status = 'bankrupt' and v_bal >= v_thr then
    update mazzobet.session_teams set status = 'in_game', bankrupt_until = null
     where session_id = p_session and team_id = p_team;
  end if;
end $$;

create or replace function mazzobet.adjust(p_session uuid, p_team smallint, p_delta bigint) returns void
language plpgsql set search_path = '' as $$
begin
  update mazzobet.session_teams set balance = balance + p_delta where session_id = p_session and team_id = p_team;
  perform mazzobet.check_bankruptcy(p_session, p_team);
end $$;

-- Comunicati quando la cassa del Banco passa sotto zero o torna sopra (a fine operazione, mai a metà).
create function mazzobet.check_cash(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare v_c bigint; v_neg boolean;
begin
  select coalesce(sum(amount), 0) into v_c from mazzobet.ledger_entries where session_id = p_session and account = 'bank';
  select cash_negative into v_neg from mazzobet.game_sessions where id = p_session;
  if v_c < 0 and not v_neg then
    update mazzobet.game_sessions set cash_negative = true where id = p_session;
    perform mazzobet.post_news(p_session, 'radiocorsa', 'cassa_in_rosso', '{}'::jsonb, 'bank', 'cash:red');
  elsif v_c >= 0 and v_neg then
    update mazzobet.game_sessions set cash_negative = false where id = p_session;
    perform mazzobet.post_news(p_session, 'radiocorsa', 'cassa_in_attivo', '{}'::jsonb, 'bank', 'cash:green');
  end if;
end $$;

-- Fine di ogni operazione economica: catene di colletta e controllo della cassa.
create function mazzobet.settle(p_session uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform mazzobet.process_chains(p_session);
  perform mazzobet.check_cash(p_session);
end $$;

-- Testi di catalogo: non si ripete lo stesso testo nella stessa serata (finché ce ne sono di nuovi).
create or replace function mazzobet.post_news(p_session uuid, p_cat text, p_event text, p_vars jsonb, p_news_kind text, p_ref text)
returns void
language plpgsql set search_path = '' as $$
declare v_e mazzobet.catalog_entries; v_title text; v_body text; v_k text;
begin
  select * into v_e from mazzobet.catalog_entries c
   where c.kind = p_cat and (p_event is null or c.event = p_event)
     and c.id not in (select n.catalog_id from mazzobet.news n where n.session_id = p_session and n.catalog_id is not null)
   order by random() limit 1;
  if not found then
    select * into v_e from mazzobet.catalog_entries c
     where c.kind = p_cat and (p_event is null or c.event = p_event) order by random() limit 1;
  end if;
  if found then
    v_title := v_e.title;
    v_body := v_e.body || coalesce(' ' || v_e.body2, '');
  else
    v_title := upper(coalesce(p_event, p_cat));
    v_body := 'Il Banco registra un nuovo evento.';
  end if;
  for v_k in select jsonb_object_keys(p_vars) loop
    v_title := replace(v_title, '{' || v_k || '}', p_vars->>v_k);
    v_body  := replace(v_body,  '{' || v_k || '}', p_vars->>v_k);
  end loop;
  insert into mazzobet.news (session_id, kind, title, body, ref, catalog_id)
  values (p_session, p_news_kind, v_title, v_body, p_ref, v_e.id);
end $$;

create or replace function mazzobet.process_chains(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_chain bigint; v_fallen smallint[]; v_all smallint[]; v_payers smallint[]; v_round int; v_t smallint;
  v_first text; v_rest text[];
  v_amount bigint := mazzobet.cfg('colletta_importo');
  v_min_payers int := mazzobet.cfg('colletta_min_paganti');
  v_thr numeric := mazzobet.cfg('bancarotta_soglia');
begin
  loop
    exit when not exists (select 1 from mazzobet.bankruptcy_events where session_id = p_session and chain_id is null);

    insert into mazzobet.collection_chains (session_id, first_team_id)
    select p_session, team_id from mazzobet.bankruptcy_events
     where session_id = p_session and chain_id is null order by id limit 1
    returning id into v_chain;

    with u as (update mazzobet.bankruptcy_events set chain_id = v_chain
                where session_id = p_session and chain_id is null returning team_id, id)
    select array_agg(team_id order by id) into v_fallen from u;
    v_all := v_fallen;
    v_round := 0;

    loop
      select array_agg(team_id order by team_id) into v_payers from mazzobet.session_teams
       where session_id = p_session and status = 'in_game' and balance >= v_thr;
      exit when coalesce(cardinality(v_payers), 0) < v_min_payers;
      v_round := v_round + 1;
      insert into mazzobet.collection_rounds (chain_id, round_no, payers, amount, fallen)
      values (v_chain, v_round, cardinality(v_payers), v_amount, v_fallen);
      foreach v_t in array v_payers loop
        perform mazzobet.transfer(p_session, 'colletta', 'colletta:' || v_chain || ':' || v_round || ':' || v_t,
                                  null, 'team', v_t, 'bank', null, v_amount);
      end loop;
      with u as (update mazzobet.bankruptcy_events set chain_id = v_chain
                  where session_id = p_session and chain_id is null returning team_id, id)
      select array_agg(team_id order by id) into v_fallen from u;
      exit when v_fallen is null;
      v_all := v_all || v_fallen;
    end loop;

    update mazzobet.collection_chains set rounds = v_round, ended_at = now() where id = v_chain;

    select name into v_first from mazzobet.teams where id = v_all[1];
    if v_round = 0 then
      perform mazzobet.post_news(p_session, 'radiocorsa', 'bancarotta',
                                 jsonb_build_object('nomeSquadra', v_first), 'bank', 'chain:' || v_chain);
    elsif v_round >= 2 then
      select array_agg(t.name order by u.ord) into v_rest
        from unnest(v_all[2:cardinality(v_all)]) with ordinality as u(id, ord)
        join mazzobet.teams t on t.id = u.id;
      perform mazzobet.post_news(p_session, 'radiocorsa', 'colletta_cascata',
                                 jsonb_build_object('nomeSquadra', v_first, 'elencoCaduti', mazzobet.join_names(v_rest)),
                                 'bank', 'chain:' || v_chain);
    else
      perform mazzobet.post_news(p_session, 'radiocorsa', 'colletta',
                                 jsonb_build_object('nomeSquadra', v_first, 'importo', v_amount::text), 'bank', 'chain:' || v_chain);
    end if;
  end loop;
end $$;

create or replace function mazzobet.run_bank_event(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_bonus boolean := random() * 100 < mazzobet.cfg('banco_probabilita_bonus');
  v_thr numeric := mazzobet.cfg('bancarotta_soglia');
  v_eligible smallint[]; v_pick smallint[]; v_n int; v_amount bigint; v_ev bigint; v_t smallint; v_names text[];
  v_dmin int := mazzobet.cfg('banco_destinatari_min'); v_dmax int := mazzobet.cfg('banco_destinatari_max');
  v_imin numeric := mazzobet.cfg('banco_importo_min'); v_imax numeric := mazzobet.cfg('banco_importo_max');
  v_step numeric := mazzobet.cfg('banco_importo_passo');
begin
  if not v_bonus then
    select array_agg(team_id) into v_eligible from mazzobet.session_teams
     where session_id = p_session and status = 'in_game' and balance >= v_thr;
    if v_eligible is null then v_bonus := true; end if;
  end if;
  if v_bonus then
    select array_agg(team_id) into v_eligible from mazzobet.session_teams where session_id = p_session;
  end if;
  if v_eligible is null then return; end if;

  v_n := least(v_dmin + floor(random() * (v_dmax - v_dmin + 1))::int, cardinality(v_eligible));
  select array_agg(t order by t) into v_pick from (select unnest(v_eligible) as t order by random() limit v_n) s;
  v_amount := v_imin + v_step * floor(random() * ((v_imax - v_imin) / v_step + 1));   -- multipli del passo

  insert into mazzobet.bank_events (session_id, kind, teams, amount, detail)
  values (p_session, case when v_bonus then 'bonus' else 'malus' end, v_pick, v_amount, jsonb_build_object('innesco', 'timer'))
  returning id into v_ev;

  foreach v_t in array v_pick loop
    if v_bonus then
      perform mazzobet.transfer(p_session, 'bonus', 'bank_bonus:' || v_ev || ':' || v_t, null, 'bank', null, 'team', v_t, v_amount);
    else
      perform mazzobet.transfer(p_session, 'malus', 'bank_malus:' || v_ev || ':' || v_t, null, 'team', v_t, 'bank', null, v_amount);
    end if;
  end loop;

  -- registro dell'intervento: anche i saldi risultanti dei destinatari
  update mazzobet.bank_events set detail = detail || jsonb_build_object('saldi',
      (select jsonb_object_agg(team_id::text, balance) from mazzobet.session_teams
        where session_id = p_session and team_id = any (v_pick)))
   where id = v_ev;

  select array_agg(name order by name) into v_names from mazzobet.teams where id = any (v_pick);
  perform mazzobet.post_news(p_session, case when v_bonus then 'bonus' else 'malus' end, null,
          jsonb_build_object('nomeSquadre', mazzobet.join_names(v_names), 'importo', mazzobet.fmt(v_amount)),
          case when v_bonus then 'bonus' else 'malus' end, 'bank:' || v_ev);
end $$;

create or replace function mazzobet.run_sponsor_event(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_c bigint; v_n int; v_contrib bigint; v_ev bigint; v_t smallint; v_sponsor text; v_id text;
  v_rain bigint := mazzobet.cfg('pioggia_importo');
begin
  select coalesce(sum(amount), 0) into v_c from mazzobet.ledger_entries where session_id = p_session and account = 'bank';
  select count(*) into v_n from mazzobet.session_teams where session_id = p_session;
  v_contrib := mazzobet.cfg('sponsor_base') + mazzobet.cfg('sponsor_per_squadra') * v_n + greatest(0, -v_c);

  select id, event into v_id, v_sponsor from mazzobet.catalog_entries where kind = 'sponsor' order by random() limit 1;
  v_sponsor := coalesce(v_sponsor, 'Lo sponsor');

  insert into mazzobet.bank_events (session_id, kind, amount, detail)
  values (p_session, 'sponsor', v_contrib,
          jsonb_build_object('sponsor', v_sponsor, 'catalogId', v_id, 'teams', v_n, 'cashBefore', v_c))
  returning id into v_ev;

  perform mazzobet.transfer(p_session, 'sponsor_cash', 'sponsor_cash:' || v_ev, null, 'sponsor', null, 'bank', null, v_contrib);
  for v_t in select team_id from mazzobet.session_teams where session_id = p_session order by team_id loop
    perform mazzobet.transfer(p_session, 'sponsor_rain', 'sponsor_rain:' || v_ev || ':' || v_t, null, 'bank', null, 'team', v_t, v_rain);
  end loop;

  perform mazzobet.post_news(p_session, 'sponsor', v_sponsor,
          jsonb_build_object('nomeSponsor', v_sponsor, 'importoSponsor', mazzobet.fmt(v_contrib),
                             'numeroSquadre', v_n::text, 'importoPerSquadra', v_rain::text),
          'sponsor', 'sponsor:' || v_ev);
end $$;

-- Annulla e rimborsa una scommessa aperta o in attesa di esito (i 100 Carletti di creazione non tornano).
create or replace function mazzobet.void_market(p_market bigint) returns void
language plpgsql set search_path = '' as $$
declare v_m mazzobet.markets; v_bet record;
begin
  select * into v_m from mazzobet.markets where id = p_market for update;
  if v_m.status not in ('open','closed') then return; end if;
  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    perform mazzobet.transfer(v_m.session_id, 'refund', 'refund:' || v_bet.id, p_market, 'bank', null, 'team', v_bet.team_id, v_bet.amount);
    update mazzobet.bets set result = 'void', payout = v_bet.amount where id = v_bet.id;
  end loop;
  update mazzobet.markets set status = 'void', resolved_at = now() where id = p_market;
  for v_bet in select team_id from mazzobet.bets where market_id = p_market order by team_id loop
    perform mazzobet.check_bankruptcy(v_m.session_id, v_bet.team_id);
  end loop;
  if exists (select 1 from mazzobet.bets where market_id = p_market) then
    perform mazzobet.post_news(v_m.session_id, 'radiocorsa', 'mercato_annullato',
            jsonb_build_object('numeroScommessa', v_m.market_no::text), 'bank', 'void:' || p_market);
  end if;
end $$;

-- Compenso di chi esita: pagato dal Banco a fine contestazione, solo se l'esito non è stato ribaltato.
create function mazzobet.pay_fees(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare v_m record;
begin
  for v_m in select id, fee_amount, fee_team_id from mazzobet.markets
              where session_id = p_session and status = 'resolved' and not flipped and fee_amount > 0
                and fee_paid_at is null and appeal_deadline_at < now() order by id loop
    perform mazzobet.transfer(p_session, 'esito_compenso', 'fee:' || v_m.id, v_m.id, 'bank', null, 'team', v_m.fee_team_id, v_m.fee_amount);
    update mazzobet.markets set fee_paid_at = now() where id = v_m.id;
  end loop;
end $$;

create or replace function mazzobet.try_finalize(p_session uuid, p_force boolean default false) returns boolean
language plpgsql set search_path = '' as $$
declare v_status text; v_m record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_session::text, 0));
  select status into v_status from mazzobet.game_sessions where id = p_session;
  if v_status = 'closed' then return true; end if;
  if v_status <> 'closing' then return false; end if;

  if p_force then
    for v_m in select id from mazzobet.markets where session_id = p_session and status in ('open','closed') order by id loop
      perform mazzobet.void_market(v_m.id);
    end loop;
  elsif exists (select 1 from mazzobet.markets where session_id = p_session and status in ('open','closed'))
     or exists (select 1 from mazzobet.markets where session_id = p_session and status = 'resolved'
                  and not flipped and appeal_deadline_at > now()) then
    return false;
  end if;

  perform mazzobet.pay_fees(p_session);
  perform mazzobet.settle(p_session);
  update mazzobet.game_sessions set status = 'closed', closed_at = now(), bank_paused = true where id = p_session;

  insert into mazzobet.final_standings
  select p_session, st.team_id,
         rank() over (order by st.balance desc, st.correct_picks desc),
         st.balance, st.correct_picks,
         rank() over (order by st.correct_picks desc, st.balance desc),
         st.bankruptcies, st.readmissions
    from mazzobet.session_teams st where st.session_id = p_session;
  return true;
end $$;

-- ---------------------------------------------------------------- API pubblica

-- ESITA ORA ora è un solo passo (esito con la scelta SÌ/NO): non serve più la chiusura separata.
drop function public.mb_close_now(uuid, bigint);

create or replace function public.mb_enter_team(p_team smallint, p_token uuid default null, p_user_agent text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_session uuid := mazzobet.active_session();
  v_first boolean;
  v_token uuid;
  v_name text;
begin
  if v_session is null then raise exception 'no_session'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_session::text, 0));
  select name into v_name from mazzobet.teams where id = p_team;
  if v_name is null then raise exception 'unknown_team'; end if;

  with ins as (
    insert into mazzobet.session_teams (session_id, team_id) values (v_session, p_team)
    on conflict do nothing returning 1)
  select exists (select 1 from ins) into v_first;

  if v_first then
    perform mazzobet.transfer(v_session, 'start', 'start:' || p_team, null, 'mint', null, 'team', p_team, mazzobet.cfg('saldo_iniziale')::bigint);
    if (select count(*) from mazzobet.session_teams where session_id = v_session) >= mazzobet.cfg('banco_squadre_per_avvio') then
      update mazzobet.game_sessions
         set bank_next_at    = mazzobet.next_bank_at(v_session),
             sponsor_next_at = mazzobet.next_sponsor_at(v_session)
       where id = v_session and bank_next_at is null;
    end if;
  end if;

  select token into v_token from mazzobet.team_devices
   where token = p_token and session_id = v_session and team_id = p_team;
  if v_token is null then
    insert into mazzobet.team_devices (session_id, team_id, user_agent)
    values (v_session, p_team, left(p_user_agent, 300)) returning token into v_token;
  end if;

  return jsonb_build_object(
    'token', v_token, 'teamId', p_team, 'name', v_name, 'firstEntry', v_first,
    'otherDevices', exists (select 1 from mazzobet.team_devices
                             where session_id = v_session and team_id = p_team and token <> v_token));
end $$;

create or replace function public.mb_create_market(
  p_token uuid, p_question text, p_yes int, p_no int, p_expires_at timestamptz, p_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_end timestamptz; v_status text;
  v_row mazzobet.session_teams; v_q text := btrim(p_question);
  v_id bigint; v_no int; v_fee bigint := mazzobet.cfg('costo_creazione');
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select ends_at, status into v_end, v_status from mazzobet.game_sessions where id = v_s for update;
  if v_status = 'closed' then raise exception 'session_closed'; end if;

  select id, market_no into v_id, v_no from mazzobet.markets where session_id = v_s and idempotency_key = p_key;
  if found then return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', true); end if;

  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'in_game' then raise exception 'bankrupt'; end if;
  if v_row.balance < v_fee then raise exception 'insufficient_funds'; end if;
  if char_length(v_q) not between 8 and 120 then raise exception 'invalid_question'; end if;
  if p_yes not between mazzobet.cfg('quota_min') and mazzobet.cfg('quota_max')
     or p_no not between mazzobet.cfg('quota_min') and mazzobet.cfg('quota_max') then raise exception 'invalid_odds'; end if;
  -- margine: 1/qSÌ + 1/qNO >= 1, in soli interi (blocca le quote «regalo» come 5,00 e 5,00)
  if 100::bigint * (p_yes + p_no) < p_yes::bigint * p_no then raise exception 'odds_margin'; end if;
  if p_expires_at < now() + mazzobet.dur(v_s, mazzobet.cfg('durata_min_mercato_sec')::double precision) then raise exception 'expiry_too_soon'; end if;
  if p_expires_at > v_end then raise exception 'expiry_too_late'; end if;

  update mazzobet.game_sessions set next_market_no = next_market_no + 1 where id = v_s
   returning next_market_no - 1 into v_no;
  insert into mazzobet.markets (session_id, market_no, creator_team_id, question, yes_odds, no_odds,
                                scheduled_close_at, idempotency_key)
  values (v_s, v_no, v_t, v_q, p_yes, p_no, p_expires_at, p_key) returning id into v_id;

  perform mazzobet.transfer(v_s, 'create', 'create:' || v_id, v_id, 'team', v_t, 'bank', null, v_fee);
  perform mazzobet.settle(v_s);
  return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', false);
end $$;

create or replace function public.mb_place_bet(p_token uuid, p_market bigint, p_side text, p_amount bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_m mazzobet.markets; v_bet mazzobet.bets;
  v_row mazzobet.session_teams; v_odds int; v_id bigint;
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
  if v_m.status <> 'open' or v_m.scheduled_close_at <= now() then raise exception 'market_closed'; end if;
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

  -- la puntata è già registrata: con saldo a zero la squadra non fallisce finché la scommessa è in corso
  perform mazzobet.transfer(v_s, 'bet', 'bet:' || v_id, p_market, 'team', v_t, 'bank', null, p_amount);
  perform mazzobet.settle(v_s);
  return jsonb_build_object('betId', v_id, 'replay', false);
end $$;

-- Esito. Prima della scadenza: solo il creatore (ESITA ORA, chiude subito le puntate). Da T a T+2': solo il creatore.
-- Da T+2' a T+17': il creatore e le squadre che non hanno puntato, vale la prima risposta.
create or replace function public.mb_resolve(p_token uuid, p_market bigint, p_outcome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_m mazzobet.markets; v_bet record; v_pay bigint;
  v_total bigint; v_c bigint; v_fee bigint; v_best bigint := 0; v_best_team smallint; v_name text;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if p_outcome not in ('yes','no') then raise exception 'invalid_side'; end if;
  if v_m.status = 'resolved' then raise exception 'already_resolved'; end if;
  if v_m.status in ('void','empty') then raise exception 'not_resolvable'; end if;

  if v_m.status = 'open' then
    if v_m.creator_team_id <> v_t then raise exception 'not_resolvable'; end if;
    update mazzobet.markets set status = 'closed', actual_closed_at = now() where id = p_market;   -- ESITA ORA
  else
    if v_m.resolve_by <= now() then raise exception 'window_expired'; end if;
    if v_m.creator_team_id <> v_t then
      if v_m.creator_only_until > now() then raise exception 'creator_priority'; end if;
      if exists (select 1 from mazzobet.bets where market_id = p_market and team_id = v_t) then
        raise exception 'not_eligible';
      end if;
    end if;
  end if;

  -- compenso, calcolato sul totale puntato (le puntate sono chiuse): il creatore incassa C, un altro esitatore floor(C/2)
  v_total := v_m.yes_pool + v_m.no_pool;
  v_c := least(floor(v_total * mazzobet.cfg('compenso_percentuale') / 100), mazzobet.cfg('compenso_tetto'));
  v_fee := case when v_m.creator_team_id = v_t then v_c
                else floor(v_c * mazzobet.cfg('compenso_altro_percentuale') / 100) end;

  update mazzobet.markets
     set status = 'resolved', outcome = p_outcome, resolved_at = now(), resolved_by_team_id = v_t,
         appeal_deadline_at = now() + mazzobet.dur(v_s, mazzobet.cfg('contestazione_sec')::double precision),
         fee_amount = v_fee, fee_team_id = case when v_fee > 0 then v_t end
   where id = p_market;

  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    if v_bet.side = p_outcome then
      v_pay := floor(v_bet.amount * v_bet.odds_cents / 100.0);
      perform mazzobet.transfer(v_s, 'win', 'win:' || v_bet.id, p_market, 'bank', null, 'team', v_bet.team_id, v_pay);
      update mazzobet.bets set result = 'win', payout = v_pay where id = v_bet.id;
      update mazzobet.session_teams set correct_picks = correct_picks + 1
       where session_id = v_s and team_id = v_bet.team_id;
      if v_pay > v_best then v_best := v_pay; v_best_team := v_bet.team_id; end if;
    else
      update mazzobet.bets set result = 'loss', payout = 0 where id = v_bet.id;
    end if;
  end loop;

  -- chi ha perso l'ultima puntata in corso e resta sotto soglia fallisce adesso
  for v_bet in select team_id from mazzobet.bets where market_id = p_market order by team_id loop
    perform mazzobet.check_bankruptcy(v_s, v_bet.team_id);
  end loop;

  if v_best >= mazzobet.cfg('grande_vincita_soglia') then
    select name into v_name from mazzobet.teams where id = v_best_team;
    perform mazzobet.post_news(v_s, 'radiocorsa', 'grande_vincita',
            jsonb_build_object('nomeSquadra', v_name, 'importo', mazzobet.fmt(v_best)), 'bank', 'bigwin:' || p_market);
  end if;

  perform mazzobet.settle(v_s);
  return jsonb_build_object('marketId', p_market, 'outcome', p_outcome);
end $$;

create or replace function public.mb_appeal(p_token uuid, p_market bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_m mazzobet.markets; v_bettors int; v_appeals int; v_new text;
  v_bet record; v_new_pay bigint; v_delta bigint; v_inserted bigint;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if v_m.status <> 'resolved' then raise exception 'not_appealable'; end if;
  if v_m.flipped then raise exception 'already_flipped'; end if;
  if now() > v_m.appeal_deadline_at then raise exception 'appeal_window_closed'; end if;
  if not exists (select 1 from mazzobet.bets where market_id = p_market and team_id = v_t) then
    raise exception 'not_eligible';
  end if;

  insert into mazzobet.appeals (session_id, market_id, team_id) values (v_s, p_market, v_t)
  on conflict (market_id, team_id) do nothing returning id into v_inserted;
  if v_inserted is null then return jsonb_build_object('flipped', false, 'replay', true); end if;

  select count(*) into v_bettors from mazzobet.bets where market_id = p_market;
  select count(*) into v_appeals from mazzobet.appeals where market_id = p_market;
  if v_appeals < v_bettors / 2 + 1 then
    return jsonb_build_object('flipped', false, 'replay', false);
  end if;

  -- esito ribaltato (una sola volta): nessun compenso a chi aveva esitato
  v_new := case v_m.outcome when 'yes' then 'no' else 'yes' end;
  update mazzobet.markets set outcome = v_new, flipped = true where id = p_market;

  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    v_new_pay := case when v_bet.side = v_new then floor(v_bet.amount * v_bet.odds_cents / 100.0) else 0 end;
    v_delta := v_new_pay - coalesce(v_bet.payout, 0);
    if v_delta > 0 then
      perform mazzobet.transfer(v_s, 'appeal_adjust', 'appeal:' || v_bet.id, p_market, 'bank', null, 'team', v_bet.team_id, v_delta);
    elsif v_delta < 0 then
      perform mazzobet.transfer(v_s, 'appeal_adjust', 'appeal:' || v_bet.id, p_market, 'team', v_bet.team_id, 'bank', null, -v_delta);
    end if;
    update mazzobet.bets set result = case when v_bet.side = v_new then 'win' else 'loss' end, payout = v_new_pay
     where id = v_bet.id;
    if v_bet.side = v_new then
      update mazzobet.session_teams set correct_picks = correct_picks + 1 where session_id = v_s and team_id = v_bet.team_id;
    else
      update mazzobet.session_teams set correct_picks = correct_picks - 1 where session_id = v_s and team_id = v_bet.team_id;
    end if;
  end loop;

  perform mazzobet.post_news(v_s, 'radiocorsa', 'ricorso_accolto',
          jsonb_build_object('numeroScommessa', v_m.market_no::text), 'giuria', 'appeal:' || p_market);
  perform mazzobet.settle(v_s);
  return jsonb_build_object('flipped', true, 'outcome', v_new);
end $$;

create or replace function public.mb_readmit(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_row mazzobet.session_teams; v_name text; v_to bigint := mazzobet.cfg('riammissione_saldo');
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'bankrupt' then raise exception 'not_bankrupt'; end if;
  if v_row.bankrupt_until > now() then raise exception 'lock_active'; end if;
  update mazzobet.session_teams set readmissions = readmissions + 1 where session_id = v_s and team_id = v_t;
  perform mazzobet.transfer(v_s, 'readmit', 'readmit:' || v_t || ':' || (v_row.readmissions + 1), null,
                            'bank', null, 'team', v_t, v_to - v_row.balance);
  select name into v_name from mazzobet.teams where id = v_t;
  perform mazzobet.post_news(v_s, 'radiocorsa', 'riammissione',
          jsonb_build_object('nomeSquadra', v_name, 'importo', v_to::text), 'bank', 'readmit:' || v_t || ':' || (v_row.readmissions + 1));
  perform mazzobet.settle(v_s);
  return jsonb_build_object('balance', v_to);
end $$;

-- Timer persistenti: chiusura alla scadenza (senza puntate → «empty»), annullamento senza esito, compensi,
-- Banco ordinario, sponsor, catene, chiusura serata.
create or replace function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_sess uuid; v_m record; v_gs record;
  v_closed int := 0; v_void int := 0; v_bank int := 0; v_sponsor int := 0; v_final int := 0;
  v_prec double precision := mazzobet.cfg('precedenza_creatore_sec')::double precision;
  v_win double precision := mazzobet.cfg('finestra_esito_sec')::double precision;
begin
  for v_sess in select id from mazzobet.game_sessions where status in ('active','paused','closing') loop
    perform pg_advisory_xact_lock(hashtextextended(v_sess::text, 0));

    for v_m in select m.id, exists (select 1 from mazzobet.bets b where b.market_id = m.id) as has_bets
                 from mazzobet.markets m
                where m.session_id = v_sess and m.status = 'open' and m.scheduled_close_at <= now() order by m.id loop
      if v_m.has_bets then
        update mazzobet.markets
           set status = 'closed', actual_closed_at = scheduled_close_at,
               creator_only_until = scheduled_close_at + mazzobet.dur(v_sess, v_prec),
               resolve_by = scheduled_close_at + mazzobet.dur(v_sess, v_prec + v_win)
         where id = v_m.id;
      else   -- nessuna puntata: si chiude «senza puntate», niente esito, niente annullamento
        update mazzobet.markets set status = 'empty', actual_closed_at = scheduled_close_at, resolved_at = now() where id = v_m.id;
      end if;
      v_closed := v_closed + 1;
    end loop;

    for v_m in select id from mazzobet.markets
                where session_id = v_sess and status = 'closed' and resolve_by <= now() order by id loop
      perform mazzobet.void_market(v_m.id);
      v_void := v_void + 1;
    end loop;

    perform mazzobet.pay_fees(v_sess);

    select status, bank_next_at, sponsor_next_at, bank_paused into v_gs from mazzobet.game_sessions where id = v_sess;
    if v_gs.status <> 'closing' and not v_gs.bank_paused then
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

    perform mazzobet.settle(v_sess);
    if v_gs.status = 'closing' and mazzobet.try_finalize(v_sess) then v_final := v_final + 1; end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void, 'bank', v_bank, 'sponsor', v_sponsor, 'finalized', v_final);
end $$;

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
    'me', (select jsonb_build_object('teamId', st.team_id, 'name', t.name, 'balance', st.balance,
                                     'status', st.status, 'bankruptUntil', st.bankrupt_until,
                                     'readmissions', st.readmissions, 'correct', st.correct_picks)
             from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id
            where st.session_id = v_s and st.team_id = v_t),
    'markets', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'no', m.market_no, 'question', m.question,
          'byTeamId', m.creator_team_id, 'by', t.name,
          'yesOdds', m.yes_odds, 'noOdds', m.no_odds,
          'createdAt', m.created_at, 'expiresAt', m.scheduled_close_at,
          'status', m.status, 'resolveBy', m.resolve_by, 'creatorOnlyUntil', m.creator_only_until,
          'outcome', m.outcome, 'flipped', m.flipped,
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
        join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
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
