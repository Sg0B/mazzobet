-- Fattore di velocità GLOBALE dei tempi di gioco (default 1 = tempi del PRD). Serve alle simulazioni:
-- con scale 6, 10 minuti reali ≈ 60 minuti di serata. Scala tutti gli intervalli fissi:
-- finestra di esito (15'), ricorso (3'), blocco bancarotta (5'), durata minima di un mercato (1'),
-- timer del Banco (8–14') e dello sponsor (8–45'). Non tocca la fine serata (ends_at), che è un orario assoluto.
alter table mazzobet.game_sessions add column time_scale numeric not null default 1 check (time_scale > 0);

create function mazzobet.dur(p_session uuid, p_secs double precision) returns interval
language sql set search_path = '' as $$
  select make_interval(secs => (p_secs / coalesce((select time_scale from mazzobet.game_sessions where id = p_session), 1))::double precision)
$$;

create function mazzobet.next_bank_at(p_session uuid) returns timestamptz
language sql set search_path = '' as $$ select now() + mazzobet.dur(p_session, 480 + floor(random() * 361)) $$;

create function mazzobet.next_sponsor_at(p_session uuid) returns timestamptz
language sql set search_path = '' as $$ select now() + mazzobet.dur(p_session, 480 + floor(random() * 2221)) $$;

create or replace function mazzobet.adjust(p_session uuid, p_team smallint, p_delta bigint) returns void
language plpgsql set search_path = '' as $$
declare v_bal bigint; v_status text;
begin
  update mazzobet.session_teams set balance = balance + p_delta
   where session_id = p_session and team_id = p_team returning balance, status into v_bal, v_status;
  if v_bal < 10 and v_status = 'in_game' then
    update mazzobet.session_teams
       set status = 'bankrupt', bankrupt_until = now() + mazzobet.dur(p_session, 300), bankruptcies = bankruptcies + 1
     where session_id = p_session and team_id = p_team;
    insert into mazzobet.bankruptcy_events (session_id, team_id) values (p_session, p_team);
  elsif v_bal >= 10 and v_status = 'bankrupt' then
    update mazzobet.session_teams set status = 'in_game', bankrupt_until = null
     where session_id = p_session and team_id = p_team;
  end if;
end $$;

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
    perform mazzobet.transfer(v_session, 'start', 'start:' || p_team, null, 'mint', null, 'team', p_team, 1000);
    if (select count(*) from mazzobet.session_teams where session_id = v_session) >= 5 then
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
  v_id bigint; v_no int;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select ends_at, status into v_end, v_status from mazzobet.game_sessions where id = v_s for update;
  if v_status = 'closed' then raise exception 'session_closed'; end if;

  select id, market_no into v_id, v_no from mazzobet.markets where session_id = v_s and idempotency_key = p_key;
  if found then return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', true); end if;

  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'in_game' then raise exception 'bankrupt'; end if;
  if v_row.balance < 100 then raise exception 'insufficient_funds'; end if;
  if char_length(v_q) not between 8 and 120 then raise exception 'invalid_question'; end if;
  if p_yes not between 110 and 1000 or p_no not between 110 and 1000 then raise exception 'invalid_odds'; end if;
  if p_expires_at < now() + mazzobet.dur(v_s, 60) then raise exception 'expiry_too_soon'; end if;
  if p_expires_at > v_end then raise exception 'expiry_too_late'; end if;

  update mazzobet.game_sessions set next_market_no = next_market_no + 1 where id = v_s
   returning next_market_no - 1 into v_no;
  insert into mazzobet.markets (session_id, market_no, creator_team_id, question, yes_odds, no_odds,
                                scheduled_close_at, idempotency_key)
  values (v_s, v_no, v_t, v_q, p_yes, p_no, p_expires_at, p_key) returning id into v_id;

  perform mazzobet.transfer(v_s, 'create', 'create:' || v_id, v_id, 'team', v_t, 'bank', null, 100);
  perform mazzobet.process_chains(v_s);
  return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', false);
end $$;

create or replace function public.mb_close_now(p_token uuid, p_market bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_m mazzobet.markets;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if v_m.creator_team_id <> v_t then raise exception 'not_creator'; end if;
  if v_m.status <> 'open' then raise exception 'market_closed'; end if;
  update mazzobet.markets
     set status = 'closed', actual_closed_at = now(), resolve_by = now() + mazzobet.dur(v_s, 900)
   where id = p_market;
  return jsonb_build_object('marketId', p_market);
end $$;

create or replace function public.mb_resolve(p_token uuid, p_market bigint, p_outcome text) returns jsonb
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
         appeal_deadline_at = now() + mazzobet.dur(v_s, 180), resolved_by_team_id = v_t
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

create or replace function mazzobet.admin_resume_bank() returns text
language plpgsql set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  if v is null then return 'nessuna serata attiva'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  update mazzobet.game_sessions
     set bank_paused = false,
         bank_next_at = case when bank_next_at is null then null else mazzobet.next_bank_at(v) end,
         sponsor_next_at = case when sponsor_next_at is null then null else mazzobet.next_sponsor_at(v) end
   where id = v;
  return 'Banco riattivato';
end $$;

create or replace function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_sess uuid; v_m record; v_gs record;
  v_closed int := 0; v_void int := 0; v_bank int := 0; v_sponsor int := 0; v_final int := 0;
begin
  for v_sess in select id from mazzobet.game_sessions where status in ('active','paused','closing') loop
    perform pg_advisory_xact_lock(hashtextextended(v_sess::text, 0));

    for v_m in select id from mazzobet.markets
                where session_id = v_sess and status = 'open' and scheduled_close_at <= now() order by id loop
      update mazzobet.markets
         set status = 'closed', actual_closed_at = scheduled_close_at,
             resolve_by = scheduled_close_at + mazzobet.dur(v_sess, 900)
       where id = v_m.id;
      v_closed := v_closed + 1;
    end loop;

    for v_m in select id from mazzobet.markets
                where session_id = v_sess and status = 'closed' and resolve_by <= now() order by id loop
      perform mazzobet.void_market(v_m.id);
      v_void := v_void + 1;
    end loop;

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

    perform mazzobet.process_chains(v_sess);
    if v_gs.status = 'closing' and mazzobet.try_finalize(v_sess) then v_final := v_final + 1; end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void, 'bank', v_bank, 'sponsor', v_sponsor, 'finalized', v_final);
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
