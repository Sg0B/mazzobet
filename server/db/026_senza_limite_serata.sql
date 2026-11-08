-- Niente più tetto alle 03:00: una scommessa può scadere quando vuole il creatore (anche fra qualche giorno).
-- La fine serata (game_sessions.ends_at) resta solo come dato informativo: la serata si chiude dalla Regia.
-- Stessa funzione della 010, senza il controllo «expiry_too_late».
create or replace function public.mb_create_market(
  p_token uuid, p_question text, p_yes int, p_no int, p_expires_at timestamptz, p_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_status text;
  v_row mazzobet.session_teams; v_q text := btrim(p_question);
  v_id bigint; v_no int; v_fee bigint := mazzobet.cfg('costo_creazione');
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select status into v_status from mazzobet.game_sessions where id = v_s for update;
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

  update mazzobet.game_sessions set next_market_no = next_market_no + 1 where id = v_s
   returning next_market_no - 1 into v_no;
  insert into mazzobet.markets (session_id, market_no, creator_team_id, question, yes_odds, no_odds,
                                scheduled_close_at, idempotency_key)
  values (v_s, v_no, v_t, v_q, p_yes, p_no, p_expires_at, p_key) returning id into v_id;

  perform mazzobet.transfer(v_s, 'create', 'create:' || v_id, v_id, 'team', v_t, 'bank', null, v_fee);
  perform mazzobet.settle(v_s);
  return jsonb_build_object('marketId', v_id, 'marketNo', v_no, 'replay', false);
end $$;
