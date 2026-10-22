-- Scenari 5-8 del prompt v0.6 (+13 per i timer): tempi di esito con precedenza del creatore, annullamento a T+17',
-- scommessa senza puntate, compenso di chi esita (3450 / 905 / 15), ribaltamento, nessun doppio pagamento.
-- I tempi si simulano spostando le scadenze nel passato. Come si usa: vedi 01_pagamento_quote_puntate.sql.
do $$
declare
  tk uuid[]; i int; s_id uuid := mazzobet.active_session(); r jsonb; err text; n int;
  mA bigint; mB bigint; mC bigint; mD bigint; mE bigint; mF bigint; mG bigint; mH bigint; mI bigint; mJ bigint;
  fut timestamptz := now() + interval '30 minutes';
begin
  assert (select count(*) from mazzobet.session_teams where session_id = s_id) = 0, 'serata non vuota';
  set constraints all immediate;
  update mazzobet.game_sessions set ends_at = now() + interval '12 hours' where id = s_id;
  for i in 1..24 loop tk[i] := (public.mb_enter_team(i::smallint)->>'token')::uuid; end loop;   -- tk[i] = squadra i

  -- ===== Scenario 5: tempi =====  (T = scadenza)
  mA := (public.mb_create_market(tk[24], 'Scommessa live per i tempi di prova', 200, 200, fut, 't1')->>'marketId')::bigint;
  perform public.mb_place_bet(tk[1], mA, 'yes', 50);
  perform public.mb_place_bet(tk[2], mA, 'no', 50);
  update mazzobet.markets set scheduled_close_at = now() - interval '30 seconds' where id = mA;   -- siamo a T + 30 s
  perform public.mb_tick();
  assert (select status from mazzobet.markets where id = mA) = 'closed', 'alla scadenza passa a "da esitare"';
  assert (select extract(epoch from creator_only_until - scheduled_close_at) from mazzobet.markets where id = mA) = 120, 'precedenza del creatore: 2 minuti';
  assert (select extract(epoch from resolve_by - scheduled_close_at) from mazzobet.markets where id = mA) = 1020, 'annullamento a T + 17 minuti';
  begin perform public.mb_resolve(tk[3], mA, 'yes'); exception when others then err := sqlerrm; end;
  assert err = 'creator_priority', 'prima di T+2 un non scommettitore non può esitare: ' || coalesce(err, 'null');
  begin perform public.mb_resolve(tk[1], mA, 'yes'); exception when others then err := sqlerrm; end;
  assert err = 'creator_priority', 'prima di T+2 nemmeno uno scommettitore: ' || coalesce(err, 'null');
  update mazzobet.markets set creator_only_until = now() - interval '1 second' where id = mA;      -- ora siamo oltre T + 2'
  begin perform public.mb_resolve(tk[1], mA, 'yes'); exception when others then err := sqlerrm; end;
  assert err = 'not_eligible', 'dopo T+2 chi ha puntato non può esitare: ' || coalesce(err, 'null');
  perform public.mb_resolve(tk[3], mA, 'yes');   -- un non scommettitore esita al posto del creatore
  assert (select fee_amount from mazzobet.markets where id = mA) = 5, 'altro esitatore: floor(10/2) = 5 (totale 100 → C = 10)';
  assert (select fee_team_id from mazzobet.markets where id = mA) = 3, 'il compenso va a chi ha esitato';

  -- T+17' senza esito: annullamento, rimborsi, nessun compenso
  mB := (public.mb_create_market(tk[24], 'Scommessa che nessuno esita ok', 200, 200, fut, 't2')->>'marketId')::bigint;
  perform public.mb_place_bet(tk[4], mB, 'yes', 40);
  update mazzobet.markets set scheduled_close_at = now() - interval '1030 seconds' where id = mB;  -- T + 17' 10"
  perform public.mb_tick();
  assert (select status from mazzobet.markets where id = mB) = 'void', 'annullata a T + 17 minuti';
  assert (select result from mazzobet.bets where market_id = mB) = 'void', 'puntata rimborsata';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 4) = 1000, 'saldo restituito per intero';
  assert (select fee_amount from mazzobet.markets where id = mB) = 0, 'annullata: nessun compenso';

  -- ===== Scenario 8: scommessa senza puntate =====
  mC := (public.mb_create_market(tk[24], 'Scommessa senza nessuna puntata', 200, 200, fut, 't3')->>'marketId')::bigint;
  update mazzobet.markets set scheduled_close_at = now() - interval '1 second' where id = mC;
  perform public.mb_tick();
  assert (select status from mazzobet.markets where id = mC) = 'empty', 'si chiude «senza puntate»';
  begin perform public.mb_resolve(tk[24], mC, 'yes'); exception when others then err := sqlerrm; end;
  assert err = 'not_resolvable', 'nessun esito da dare: ' || coalesce(err, 'null');
  perform public.mb_tick();
  assert (select status from mazzobet.markets where id = mC) = 'empty', 'e non viene mai annullata';
  assert not exists (select 1 from mazzobet.news where ref = 'void:' || mC), 'nessun comunicato di annullamento';

  -- ===== Scenario 6: compenso =====
  mD := (public.mb_create_market(tk[23], 'Compenso totale 3450 esita il creatore', 200, 200, fut, 'c1')->>'marketId')::bigint;
  mE := (public.mb_create_market(tk[22], 'Compenso totale 3450 esita un altro', 200, 200, fut, 'c2')->>'marketId')::bigint;
  mF := (public.mb_create_market(tk[21], 'Compenso totale 905 esita il creatore', 200, 200, fut, 'c3')->>'marketId')::bigint;
  mG := (public.mb_create_market(tk[20], 'Compenso totale 905 esita un altro', 200, 200, fut, 'c4')->>'marketId')::bigint;
  mH := (public.mb_create_market(tk[19], 'Compenso totale 15 esita il creatore', 200, 200, fut, 'c5')->>'marketId')::bigint;
  mI := (public.mb_create_market(tk[18], 'Compenso totale 15 esita un altro', 200, 200, fut, 'c6')->>'marketId')::bigint;
  mJ := (public.mb_create_market(tk[17], 'Compenso con esito ribaltato dopo', 200, 200, fut, 'c7')->>'marketId')::bigint;
  perform public.mb_place_bet(tk[5], mD, 'yes', 900);  perform public.mb_place_bet(tk[6], mD, 'yes', 900);
  perform public.mb_place_bet(tk[7], mD, 'yes', 900);  perform public.mb_place_bet(tk[8], mD, 'yes', 750);
  perform public.mb_place_bet(tk[9], mE, 'yes', 900);  perform public.mb_place_bet(tk[10], mE, 'yes', 900);
  perform public.mb_place_bet(tk[11], mE, 'yes', 900); perform public.mb_place_bet(tk[12], mE, 'yes', 750);
  perform public.mb_place_bet(tk[13], mF, 'yes', 500); perform public.mb_place_bet(tk[14], mF, 'yes', 405);
  perform public.mb_place_bet(tk[15], mG, 'yes', 500); perform public.mb_place_bet(tk[16], mG, 'yes', 405);
  perform public.mb_place_bet(tk[1], mH, 'yes', 15);
  perform public.mb_place_bet(tk[2], mI, 'yes', 15);
  perform public.mb_place_bet(tk[3], mJ, 'yes', 10);   perform public.mb_place_bet(tk[4], mJ, 'yes', 10);
  perform public.mb_place_bet(tk[5], mJ, 'yes', 10);
  -- il creatore esita con ESITA ORA (mercato ancora aperto)
  perform public.mb_resolve(tk[23], mD, 'yes');
  perform public.mb_resolve(tk[21], mF, 'yes');
  perform public.mb_resolve(tk[19], mH, 'yes');
  perform public.mb_resolve(tk[17], mJ, 'yes');
  -- un altro esita dopo la scadenza e la precedenza del creatore
  update mazzobet.markets set scheduled_close_at = now() - interval '1 second' where id in (mE, mG, mI);
  perform public.mb_tick();
  update mazzobet.markets set creator_only_until = now() - interval '1 second' where id in (mE, mG, mI);
  perform public.mb_resolve(tk[24], mE, 'yes');
  perform public.mb_resolve(tk[23], mG, 'yes');
  perform public.mb_resolve(tk[24], mI, 'yes');
  assert (select fee_amount from mazzobet.markets where id = mD) = 250, '3450 → C = 250 (tetto), esita il creatore';
  assert (select fee_amount from mazzobet.markets where id = mE) = 125, '3450 → altro esitatore 125';
  assert (select fee_amount from mazzobet.markets where id = mF) = 90,  '905 → C = 90';
  assert (select fee_amount from mazzobet.markets where id = mG) = 45,  '905 → altro esitatore 45';
  assert (select fee_amount from mazzobet.markets where id = mH) = 1,   '15 → C = 1';
  assert (select fee_amount from mazzobet.markets where id = mI) = 0 and (select fee_team_id from mazzobet.markets where id = mI) is null,
         '15 → altro esitatore 0 (nessun compenso)';

  -- ===== Scenario 7: ribaltamento =====  (2 ricorsi su 3 scommettitori)
  perform public.mb_appeal(tk[3], mJ);
  r := public.mb_appeal(tk[4], mJ);
  assert (r->>'flipped')::boolean, 'esito ribaltato con la maggioranza';
  assert (select count(*) from mazzobet.ledger_transactions where kind = 'appeal_adjust' and market_id = mJ) = 3, 'un solo movimento per scommettitore';
  begin perform public.mb_appeal(tk[5], mJ); exception when others then err := sqlerrm; end;
  assert err = 'already_flipped', 'niente secondo ribaltamento: ' || coalesce(err, 'null');

  -- ===== il compenso si paga a fine contestazione, solo se non ribaltato =====
  assert not exists (select 1 from mazzobet.ledger_transactions where kind = 'esito_compenso'), 'prima della fine della contestazione nessun pagamento';
  update mazzobet.markets set appeal_deadline_at = now() - interval '1 second' where status = 'resolved';
  perform public.mb_tick();
  perform public.mb_tick();   -- Scenario 13: ripetere il timer non duplica i pagamenti (come dopo un riavvio)
  select count(*) into n from mazzobet.ledger_transactions where kind = 'esito_compenso';
  assert n = 6, 'compensi pagati una volta sola: A, D, E, F, G, H (trovati ' || n || ')';
  assert not exists (select 1 from mazzobet.ledger_transactions where kind = 'esito_compenso' and market_id in (mI, mJ, mB, mC)),
         'nessun compenso per: 15 esitato da altri, ribaltata, annullata, senza puntate';
  assert (select le.amount from mazzobet.ledger_entries le join mazzobet.ledger_transactions lt on lt.id = le.transaction_id
           where lt.kind = 'esito_compenso' and lt.market_id = mD and le.team_id is not null) = 250, 'D: 250 al creatore';
  assert (select le.team_id from mazzobet.ledger_entries le join mazzobet.ledger_transactions lt on lt.id = le.transaction_id
           where lt.kind = 'esito_compenso' and lt.market_id = mE and le.team_id is not null) = 24, 'E: 125 a chi ha esitato (squadra 24)';

  assert (select coalesce(sum(amount), 0) from mazzobet.ledger_entries) = 0, 'ledger a somma zero';
  assert not exists (select 1 from mazzobet.session_teams st where st.balance <>
     (select coalesce(sum(amount), 0) from mazzobet.ledger_entries le where le.session_id = st.session_id and le.team_id = st.team_id)), 'saldi = ledger';
  raise exception 'TEST_OK 02_tempi_compenso_ricorso';
end $$;
