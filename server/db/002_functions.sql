-- MazzoBet — funzioni transazionali. Ogni azione economica è una funzione atomica e idempotente.
-- Interne: schema mazzobet. Pubbliche (chiamate dal server con service_role): public.mb_*.
-- Ordine dei lock (sempre lo stesso, per evitare deadlock): sessione → mercato → squadre in ordine di id.

create function mazzobet.active_session() returns uuid
language sql stable set search_path = '' as $$
  select id from mazzobet.game_sessions where status in ('active','paused') order by created_at desc limit 1
$$;

-- Risolve il token dispositivo in (sessione, squadra).
create function mazzobet.who(p_token uuid, out o_session uuid, out o_team smallint)
language plpgsql set search_path = '' as $$
begin
  update mazzobet.team_devices set last_seen_at = now()
   where token = p_token returning session_id, team_id into o_session, o_team;
  if o_team is null then raise exception 'unauthorized'; end if;
end $$;

-- Applica una variazione al saldo e gestisce l'ingresso/uscita dalla bancarotta (saldo < ₡10).
create function mazzobet.adjust(p_session uuid, p_team smallint, p_delta bigint) returns void
language plpgsql set search_path = '' as $$
declare v_bal bigint; v_status text;
begin
  update mazzobet.session_teams set balance = balance + p_delta
   where session_id = p_session and team_id = p_team returning balance, status into v_bal, v_status;
  if v_bal < 10 and v_status = 'in_game' then
    update mazzobet.session_teams
       set status = 'bankrupt', bankrupt_until = now() + interval '5 minutes', bankruptcies = bankruptcies + 1
     where session_id = p_session and team_id = p_team;
  elsif v_bal >= 10 and v_status = 'bankrupt' then
    update mazzobet.session_teams set status = 'in_game', bankrupt_until = null
     where session_id = p_session and team_id = p_team;
  end if;
end $$;

-- Sposta Carletti tra due conti con una transazione a partita doppia. Idempotente sulla chiave:
-- ritorna false (senza fare nulla) se la chiave è già stata usata.
create function mazzobet.transfer(
  p_session uuid, p_kind text, p_key text, p_market bigint,
  p_from text, p_from_team smallint, p_to text, p_to_team smallint, p_amount bigint
) returns boolean
language plpgsql set search_path = '' as $$
declare v_tx uuid;
begin
  if p_amount <= 0 then raise exception 'invalid_amount'; end if;
  insert into mazzobet.ledger_transactions (session_id, kind, market_id, idempotency_key)
  values (p_session, p_kind, p_market, p_key)
  on conflict (session_id, idempotency_key) do nothing
  returning id into v_tx;
  if v_tx is null then return false; end if;

  insert into mazzobet.ledger_entries (transaction_id, session_id, account, team_id, amount) values
    (v_tx, p_session, p_from, p_from_team, -p_amount),
    (v_tx, p_session, p_to,   p_to_team,    p_amount);

  if p_from = 'team' then perform mazzobet.adjust(p_session, p_from_team, -p_amount); end if;
  if p_to   = 'team' then perform mazzobet.adjust(p_session, p_to_team,    p_amount); end if;
  return true;
end $$;

-- ---------------------------------------------------------------- API pubblica

create function public.mb_list_teams() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'name', t.name,
           'entered', st.team_id is not null) order by t.id), '[]'::jsonb)
    from mazzobet.teams t
    left join mazzobet.session_teams st
      on st.team_id = t.id and st.session_id = mazzobet.active_session()
$$;

-- Accesso senza PIN: crea (o riusa) il dispositivo; al primo ingresso accredita ₡1.000.
create function public.mb_enter_team(p_team smallint, p_token uuid default null, p_user_agent text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_session uuid := mazzobet.active_session();
  v_first boolean;
  v_token uuid;
  v_name text;
begin
  if v_session is null then raise exception 'no_session'; end if;
  select name into v_name from mazzobet.teams where id = p_team;
  if v_name is null then raise exception 'unknown_team'; end if;

  with ins as (
    insert into mazzobet.session_teams (session_id, team_id) values (v_session, p_team)
    on conflict do nothing returning 1)
  select exists (select 1 from ins) into v_first;

  if v_first then
    perform mazzobet.transfer(v_session, 'start', 'start:' || p_team, null, 'mint', null, 'team', p_team, 1000);
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

create function public.mb_create_market(
  p_token uuid, p_question text, p_yes int, p_no int, p_expires_at timestamptz, p_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_end timestamptz; v_status text;
  v_row mazzobet.session_teams; v_q text := btrim(p_question);
  v_id bigint; v_no int;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  -- il lock sulla sessione serializza numerazione mercati e retry con la stessa chiave
  select ends_at, status into v_end, v_status from mazzobet.game_sessions where id = v_s for update;
  if v_status = 'closed' then raise exception 'session_closed'; end if;

  select id, market_no into v_id, v_no from mazzobet.markets where session_id = v_s and idempotency_key = p_key;
  if found then return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', true); end if;

  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'in_game' then raise exception 'bankrupt'; end if;
  if v_row.balance < 100 then raise exception 'insufficient_funds'; end if;
  if char_length(v_q) not between 8 and 120 then raise exception 'invalid_question'; end if;
  if p_yes not between 110 and 1000 or p_no not between 110 and 1000 then raise exception 'invalid_odds'; end if;
  if p_expires_at < now() + interval '1 minute' then raise exception 'expiry_too_soon'; end if;
  if p_expires_at > v_end then raise exception 'expiry_too_late'; end if;

  update mazzobet.game_sessions set next_market_no = next_market_no + 1 where id = v_s
   returning next_market_no - 1 into v_no;
  insert into mazzobet.markets (session_id, market_no, creator_team_id, question, yes_odds, no_odds,
                                scheduled_close_at, idempotency_key)
  values (v_s, v_no, v_t, v_q, p_yes, p_no, p_expires_at, p_key) returning id into v_id;

  perform mazzobet.transfer(v_s, 'create', 'create:' || v_id, v_id, 'team', v_t, 'bank', null, 100);
  return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', false);
end $$;

create function public.mb_place_bet(p_token uuid, p_market bigint, p_side text, p_amount bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_m mazzobet.markets; v_bet mazzobet.bets;
  v_row mazzobet.session_teams; v_odds int; v_id bigint;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;

  -- doppio tap / retry identico: stesso risultato, nessun secondo addebito
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
  if p_amount is null or p_amount < 10 then raise exception 'invalid_amount'; end if;

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
  return jsonb_build_object('betId', v_id, 'replay', false);
end $$;

-- ESITA ORA: il creatore chiude subito le puntate e apre la finestra di esito.
create function public.mb_close_now(p_token uuid, p_market bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_m mazzobet.markets;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if v_m.creator_team_id <> v_t then raise exception 'not_creator'; end if;
  if v_m.status <> 'open' then raise exception 'market_closed'; end if;
  update mazzobet.markets
     set status = 'closed', actual_closed_at = now(), resolve_by = now() + interval '15 minutes'
   where id = p_market;
  return jsonb_build_object('marketId', p_market);
end $$;

-- Esito: creatore o squadra che non ha puntato; la prima risposta valida vince.
create function public.mb_resolve(p_token uuid, p_market bigint, p_outcome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_m mazzobet.markets; v_bet record; v_pay bigint;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if p_outcome not in ('yes','no') then raise exception 'invalid_side'; end if;
  if v_m.status in ('resolved','void') then raise exception 'already_resolved'; end if;
  if v_m.status <> 'closed' then raise exception 'not_resolvable'; end if;
  if v_m.resolve_by <= now() then raise exception 'window_expired'; end if;
  if v_m.creator_team_id <> v_t
     and exists (select 1 from mazzobet.bets where market_id = p_market and team_id = v_t) then
    raise exception 'not_eligible';
  end if;

  update mazzobet.markets
     set status = 'resolved', outcome = p_outcome, resolved_at = now(),
         appeal_deadline_at = now() + interval '3 minutes', resolved_by_team_id = v_t
   where id = p_market;

  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    if v_bet.side = p_outcome then
      v_pay := floor(v_bet.amount * v_bet.odds_cents / 100.0);
      perform mazzobet.transfer(v_s, 'win', 'win:' || v_bet.id, p_market, 'bank', null, 'team', v_bet.team_id, v_pay);
      update mazzobet.bets set result = 'win', payout = v_pay where id = v_bet.id;
      update mazzobet.session_teams set correct_picks = correct_picks + 1
       where session_id = v_s and team_id = v_bet.team_id;
    else
      update mazzobet.bets set result = 'loss', payout = 0 where id = v_bet.id;
    end if;
  end loop;
  return jsonb_build_object('marketId', p_market, 'outcome', p_outcome);
end $$;

-- Riammissione dopo 5 minuti di bancarotta: saldo impostato a ₡500.
create function public.mb_readmit(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_row mazzobet.session_teams;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'bankrupt' then raise exception 'not_bankrupt'; end if;
  if v_row.bankrupt_until > now() then raise exception 'lock_active'; end if;
  update mazzobet.session_teams set readmissions = readmissions + 1 where session_id = v_s and team_id = v_t;
  perform mazzobet.transfer(v_s, 'readmit', 'readmit:' || v_t || ':' || (v_row.readmissions + 1), null,
                            'bank', null, 'team', v_t, 500 - v_row.balance);
  return jsonb_build_object('balance', 500);
end $$;

-- Timer persistenti: chiude i mercati scaduti e annulla (con rimborso) quelli senza esito dopo 15'.
-- Dipende solo dagli orari nel DB, quindi è sicura dopo un riavvio e con worker concorrenti.
create function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m record; v_bet record; v_closed int := 0; v_void int := 0;
begin
  for v_m in select id from mazzobet.markets
              where status = 'open' and scheduled_close_at <= now() order by id for update skip locked loop
    update mazzobet.markets
       set status = 'closed', actual_closed_at = scheduled_close_at,
           resolve_by = scheduled_close_at + interval '15 minutes'
     where id = v_m.id;
    v_closed := v_closed + 1;
  end loop;

  for v_m in select id, session_id from mazzobet.markets
              where status = 'closed' and resolve_by <= now() order by id for update skip locked loop
    for v_bet in select * from mazzobet.bets where market_id = v_m.id order by team_id loop
      perform mazzobet.transfer(v_m.session_id, 'refund', 'refund:' || v_bet.id, v_m.id,
                                'bank', null, 'team', v_bet.team_id, v_bet.amount);
      update mazzobet.bets set result = 'void', payout = v_bet.amount where id = v_bet.id;
    end loop;
    update mazzobet.markets set status = 'void', resolved_at = now() where id = v_m.id;
    v_void := v_void + 1;
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void);
end $$;

-- Fotografia completa per il client (sola lettura).
create function public.mb_get_state(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_out jsonb;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select jsonb_build_object(
    'now', now(),
    'session', (select jsonb_build_object('id', id, 'status', status, 'endsAt', ends_at)
                  from mazzobet.game_sessions where id = v_s),
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
          'status', m.status, 'resolveBy', m.resolve_by, 'outcome', m.outcome,
          'appealUntil', m.appeal_deadline_at, 'yesPool', m.yes_pool, 'noPool', m.no_pool,
          'my', (select jsonb_build_object('side', b.side, 'amount', b.amount, 'result', b.result, 'payout', b.payout)
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

-- Solo il server (service_role) può chiamare le funzioni pubbliche: mai anon/authenticated.
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
