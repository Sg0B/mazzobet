-- Comunicati «grande vincita» (soglia 500), «cassa in rosso» / «cassa in attivo», riammissione dopo il blocco.
-- Come si usa: vedi 01_pagamento_quote_puntate.sql. Serve il catalogo caricato.
do $$
declare
  tk uuid[]; i int; s_id uuid := mazzobet.active_session(); err text; m1 bigint; m2 bigint; r jsonb; txt text; chains0 int;
  fut timestamptz := now() + interval '30 minutes';
begin
  assert (select count(*) from mazzobet.session_teams where session_id = s_id) = 0, 'serata non vuota';
  assert (select count(*) from mazzobet.catalog_entries) >= 60, 'catalogo non caricato (avvia il server una volta)';
  set constraints all immediate;
  update mazzobet.game_sessions set ends_at = now() + interval '12 hours' where id = s_id;
  for i in 1..3 loop tk[i] := (public.mb_enter_team((9 + i)::smallint)->>'token')::uuid; end loop;   -- squadre 10, 11, 12

  -- grande vincita: 400 a quota 2,00 → 800 (≥ 500); 20 → 40 (sotto soglia, nessun comunicato)
  m1 := (public.mb_create_market(tk[1], 'Una scommessa con una grande vincita', 200, 200, fut, 'g1')->>'marketId')::bigint;
  perform public.mb_place_bet(tk[2], m1, 'yes', 400);
  perform public.mb_place_bet(tk[3], m1, 'yes', 20);
  assert not exists (select 1 from mazzobet.news where session_id = s_id and kind = 'bank'), 'nessuna notizia prima dell''esito';
  perform public.mb_resolve(tk[1], m1, 'yes');
  assert (select count(*) from mazzobet.news where session_id = s_id and ref = 'bigwin:' || m1) = 1, 'un comunicato di grande vincita';
  select body into txt from mazzobet.news where session_id = s_id and ref = 'bigwin:' || m1;
  assert txt like '%Us Postal Service%' and txt like '%800%', 'nomina la squadra e l''importo (800): ' || txt;

  -- cassa: +100 (creazione) +420 (puntate) −840 (vincite) = −320 → «in rosso»
  assert (select cash_negative from mazzobet.game_sessions where id = s_id), 'cassa sotto zero';
  assert (select count(*) from mazzobet.news where session_id = s_id and ref = 'cash:red') = 1, 'comunicato «cassa in rosso» (una volta sola)';
  -- poi torna sopra zero con puntate perse: «in attivo»
  m2 := (public.mb_create_market(tk[3], 'Una scommessa persa che riempie la cassa', 200, 200, fut, 'g2')->>'marketId')::bigint;
  perform public.mb_place_bet(tk[2], m2, 'no', 500);
  perform public.mb_resolve(tk[3], m2, 'yes');
  assert not (select cash_negative from mazzobet.game_sessions where id = s_id), 'cassa di nuovo positiva';
  assert (select count(*) from mazzobet.news where session_id = s_id and ref = 'cash:green') = 1, 'comunicato «cassa in attivo»';

  -- riammissione: blocco di 5 minuti, poi 500 Carletti, contatore +1, nessuna colletta
  perform mazzobet.transfer(s_id, 'test', 'low12', null, 'team', 12::smallint, 'bank', null,
          (select balance - 5 from mazzobet.session_teams where session_id = s_id and team_id = 12));
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 12) = 'bankrupt', 'squadra 12 in bancarotta';
  perform mazzobet.settle(s_id);
  select count(*) into chains0 from mazzobet.collection_chains where session_id = s_id;
  begin perform public.mb_readmit(tk[3]); exception when others then err := sqlerrm; end;
  assert err = 'lock_active', 'prima dei 5 minuti non si può: ' || coalesce(err, 'null');
  update mazzobet.session_teams set bankrupt_until = now() - interval '1 second' where session_id = s_id and team_id = 12;
  perform public.mb_readmit(tk[3]);
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 12) = 500, 'saldo impostato a 500';
  assert (select readmissions from mazzobet.session_teams where session_id = s_id and team_id = 12) = 1, 'contatore riammissioni +1';
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 12) = 'in_game', 'di nuovo in gara';
  assert (select count(*) from mazzobet.collection_chains where session_id = s_id) = chains0, 'la riammissione non innesca nessuna colletta';

  assert (select coalesce(sum(amount), 0) from mazzobet.ledger_entries) = 0, 'ledger a somma zero';
  raise exception 'TEST_OK 04_grande_vincita_cassa_riammissione';
end $$;
