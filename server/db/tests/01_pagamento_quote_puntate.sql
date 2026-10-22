-- Scenari 1-3 del prompt v0.6: pagamento, controllo quote, doppia puntata.
-- Come si usa: incolla TUTTO nell'editor SQL di Supabase ed esegui. Il test gira in una transazione che alla fine
-- viene annullata di proposito: se vedi l'errore «TEST_OK ...» è andato tutto bene e nel database non resta nulla.
-- Se vedi un altro errore, il messaggio dice quale controllo è fallito. Serve una serata attiva e vuota.
do $$
declare
  tk uuid[]; m1 bigint; m2 bigint; m3 bigint; r jsonb; err text; i int;
  s_id uuid := mazzobet.active_session();
begin
  assert (select count(*) from mazzobet.session_teams where session_id = s_id) = 0, 'serata non vuota';
  set constraints all immediate;
  update mazzobet.game_sessions set ends_at = now() + interval '12 hours' where id = s_id;   -- solo dentro il test
  for i in 1..3 loop tk[i] := (public.mb_enter_team((9 + i)::smallint)->>'token')::uuid; end loop;  -- squadre 10, 11, 12
  -- tk[1] = creatore (squadra 10), tk[2] e tk[3] scommettitori

  -- Scenario 2: controllo quote
  m1 := (public.mb_create_market(tk[1], 'Quote 2,00 e 2,00 sono ammesse', 200, 200, now() + interval '30 minutes', 'q1')->>'marketId')::bigint;
  begin perform public.mb_create_market(tk[1], 'Quote 2,50 e 2,50 vanno bloccate', 250, 250, now() + interval '30 minutes', 'q2'); exception when others then err := sqlerrm; end;
  assert err = 'odds_margin', '2,50 e 2,50 devono essere bloccate: ' || coalesce(err, 'null');
  perform public.mb_create_market(tk[1], 'Quote 1,10 e 10,00 sono ammesse', 110, 1000, now() + interval '30 minutes', 'q3');
  begin perform public.mb_create_market(tk[1], 'Quota 1,00 non ammessa ok', 100, 200, now() + interval '30 minutes', 'q4'); exception when others then err := sqlerrm; end;
  assert err = 'invalid_odds', '1,00 rifiutata: ' || coalesce(err, 'null');
  begin perform public.mb_create_market(tk[1], 'Quota 10,01 non ammessa ok', 1001, 200, now() + interval '30 minutes', 'q5'); exception when others then err := sqlerrm; end;
  assert err = 'invalid_odds', '10,01 rifiutata: ' || coalesce(err, 'null');

  -- Scenario 1: pagamento = floor(puntata × quota / 100)
  m2 := (public.mb_create_market(tk[1], 'Pagamento a quota 1,10 di prova', 110, 900, now() + interval '30 minutes', 'p1')->>'marketId')::bigint;
  m3 := (public.mb_create_market(tk[1], 'Pagamento a quota 1,95 di prova', 195, 195, now() + interval '30 minutes', 'p2')->>'marketId')::bigint;
  perform public.mb_place_bet(tk[2], m2, 'yes', 10);
  perform public.mb_place_bet(tk[2], m3, 'yes', 33);
  perform public.mb_resolve(tk[1], m2, 'yes');   -- ESITA ORA del creatore
  perform public.mb_resolve(tk[1], m3, 'yes');
  assert (select payout from mazzobet.bets where market_id = m2) = 11, '10 a 1,10 incassa 11';
  assert (select payout from mazzobet.bets where market_id = m3) = 64, '33 a 1,95 incassa floor(64,35) = 64';

  -- Scenario 3: una sola puntata per squadra e scommessa
  perform public.mb_place_bet(tk[3], m1, 'yes', 50);
  r := public.mb_place_bet(tk[3], m1, 'yes', 50);
  assert (r->>'replay')::boolean, 'stessa richiesta ripetuta = nessun secondo addebito';
  begin perform public.mb_place_bet(tk[3], m1, 'no', 50); exception when others then err := sqlerrm; end;
  assert err = 'already_bet', 'seconda puntata sull''altro lato rifiutata: ' || coalesce(err, 'null');
  begin
    insert into mazzobet.bets (session_id, market_id, team_id, side, amount, odds_cents) values (s_id, m1, 12, 'no', 10, 200);
  exception when unique_violation then err := 'unique'; end;
  assert err = 'unique', 'il database stesso impedisce la doppia puntata';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 12) = 950, 'una sola puntata addebitata';

  assert (select coalesce(sum(amount), 0) from mazzobet.ledger_entries) = 0, 'ledger a somma zero';
  raise exception 'TEST_OK 01_pagamento_quote_puntate';
end $$;
