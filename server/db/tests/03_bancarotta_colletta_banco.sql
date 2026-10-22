-- Scenari 9-12 del prompt v0.6: bancarotta (con puntate in corso), colletta con cascata (numeri del prompt),
-- Banco ordinario, sponsor con cassa negativa, pausa e timer ripetuti. Come si usa: vedi 01_pagamento_quote_puntate.sql.
-- Squadre usate: X = 1, A = 2, B = 3, C = 4, D = 5, E = 6. Serve il catalogo caricato (il server lo carica all'avvio).
do $$
declare
  tk uuid[]; i int; k int; s_id uuid := mazzobet.active_session(); r jsonb; n int; txt text; bal bigint; cash bigint;
  mE bigint; ev0 bigint; fut timestamptz := now() + interval '30 minutes';
begin
  assert (select count(*) from mazzobet.session_teams where session_id = s_id) = 0, 'serata non vuota';
  assert (select count(*) from mazzobet.catalog_entries) >= 60, 'catalogo non caricato (avvia il server una volta)';
  set constraints all immediate;
  update mazzobet.game_sessions set ends_at = now() + interval '12 hours' where id = s_id;
  for i in 1..6 loop tk[i] := (public.mb_enter_team(i::smallint)->>'token')::uuid; end loop;
  assert (select bank_next_at is not null and sponsor_next_at is not null from mazzobet.game_sessions where id = s_id), 'il Banco parte alla 5ª squadra';

  -- ===== Scenario 10: colletta con cascata =====  X saldo 3; A 20, B 30, C 40, D 200, E 300
  perform mazzobet.transfer(s_id, 'test', 'set:2', null, 'team', 2::smallint, 'bank', null, 980::bigint);
  perform mazzobet.transfer(s_id, 'test', 'set:3', null, 'team', 3::smallint, 'bank', null, 970::bigint);
  perform mazzobet.transfer(s_id, 'test', 'set:4', null, 'team', 4::smallint, 'bank', null, 960::bigint);
  perform mazzobet.transfer(s_id, 'test', 'set:5', null, 'team', 5::smallint, 'bank', null, 800::bigint);
  perform mazzobet.transfer(s_id, 'test', 'set:6', null, 'team', 6::smallint, 'bank', null, 700::bigint);
  perform mazzobet.transfer(s_id, 'test', 'set:1', null, 'team', 1::smallint, 'bank', null, 997::bigint);   -- X scende a 3: bancarotta
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 1) = 'bankrupt', 'X in bancarotta (nessuna puntata in corso)';
  perform mazzobet.settle(s_id);
  assert (select rounds from mazzobet.collection_chains where session_id = s_id) = 2, 'due giri; al terzo restano 2 paganti e la catena si ferma';
  assert (select r.payers from mazzobet.collection_rounds r join mazzobet.collection_chains c on c.id = r.chain_id where c.session_id = s_id and r.round_no = 1) = 5, 'giro 1: A, B, C, D, E';
  assert (select r.payers from mazzobet.collection_rounds r join mazzobet.collection_chains c on c.id = r.chain_id where c.session_id = s_id and r.round_no = 2) = 3, 'giro 2: C, D, E (valvola rispettata)';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 2) = -5,  'A: 20 − 25 = −5';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 3) = 5,   'B: 30 − 25 = 5';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 4) = -10, 'C: 40 − 25 − 25 = −10';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 5) = 150, 'D: 200 − 25 − 25';
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 6) = 250, 'E: 300 − 25 − 25';
  assert (select count(*) from mazzobet.bankruptcy_events where session_id = s_id and chain_id is not null) = 4, 'fallite: X, A, B, C';
  assert (select count(*) from mazzobet.ledger_transactions where session_id = s_id and kind = 'colletta') = 8, 'un prelievo per pagante e giro (5 + 3)';
  select count(*) into n from mazzobet.news where session_id = s_id and ref like 'chain:%';
  assert n = 1, 'un solo comunicato per tutta la catena';
  select body into txt from mazzobet.news where session_id = s_id and ref like 'chain:%';
  assert txt like '%Parallelo24%' and txt like '%VeloClub Mosciano%' and txt not like '%{%', 'comunicato con primo caduto e successivi: ' || txt;

  -- ===== Scenario 9: bancarotta e puntate in corso =====
  mE := (public.mb_create_market(tk[6], 'Mercato per la prova della bancarotta', 200, 200, fut, 'b1')->>'marketId')::bigint;   -- E: 250 → 150
  perform public.mb_place_bet(tk[5], mE, 'yes', 150);      -- D punta TUTTO: saldo 0 con puntata in corso
  assert (select balance from mazzobet.session_teams where session_id = s_id and team_id = 5) = 0, 'D ha puntato tutti i Carletti';
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 5) = 'in_game', 'saldo 0 con puntata in corso: NON in bancarotta';
  assert (select count(*) from mazzobet.collection_chains where session_id = s_id) = 1, 'e nessuna colletta è partita';
  perform public.mb_resolve(tk[6], mE, 'no');             -- D perde: l'ultima puntata si risolve con saldo 0
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 5) = 'bankrupt', 'D fallisce quando perde l''ultima puntata';
  assert (select count(*) from mazzobet.collection_chains where session_id = s_id) = 2, 'ora parte la colletta (con meno di 3 paganti: nessun prelievo)';
  assert (select rounds from mazzobet.collection_chains where session_id = s_id order by id desc limit 1) = 0, 'catena senza giri';
  -- saldo 9 senza puntate pendenti → bancarotta; poi un bonus a 10 o più → torna attiva senza riammissione
  select balance into bal from mazzobet.session_teams where session_id = s_id and team_id = 6;
  perform mazzobet.transfer(s_id, 'test', 'set:6b', null, 'team', 6::smallint, 'bank', null, bal - 9);
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 6) = 'bankrupt', 'saldo 9 senza puntate: bancarotta';
  perform mazzobet.transfer(s_id, 'test', 'bonus:6', null, 'bank', null, 'team', 6::smallint, 200::bigint);
  assert (select status from mazzobet.session_teams where session_id = s_id and team_id = 6) = 'in_game', 'un bonus a 10 o più la riporta in gara';
  assert (select readmissions from mazzobet.session_teams where session_id = s_id and team_id = 6) = 0, 'senza riammissione e senza contatore';
  perform mazzobet.settle(s_id);

  -- ===== Scenario 11: Banco ordinario =====
  select coalesce(max(id), 0) into ev0 from mazzobet.bank_events;
  for k in 1..10 loop perform mazzobet.run_bank_event(s_id); end loop;
  select count(*) into n from mazzobet.news where session_id = s_id and kind in ('bonus','malus');
  assert n = (select count(distinct catalog_id) from mazzobet.news where session_id = s_id and kind in ('bonus','malus')), 'nessun testo ripetuto nella serata';
  for k in 1..20 loop perform mazzobet.run_bank_event(s_id); end loop;
  assert not exists (select 1 from mazzobet.bank_events where id > ev0 and (amount % 10 <> 0 or amount not between 100 and 250)), 'importi multipli di 10 tra 100 e 250';
  assert not exists (select 1 from mazzobet.bank_events where id > ev0 and cardinality(teams) not between 1 and 3), 'da 1 a 3 destinatari';
  assert not exists (select 1 from mazzobet.bank_events e
                      join mazzobet.ledger_transactions lt on lt.idempotency_key like 'bank\_%:' || e.id || ':%'
                      join mazzobet.ledger_entries le on le.transaction_id = lt.id and le.team_id is not null
                     where e.id > ev0 and abs(le.amount) <> e.amount), 'un unico importo per tutti i destinatari';
  -- il malus non colpisce mai chi ha saldo sotto 10: con tutte le squadre sotto 10 ogni evento diventa un bonus
  for k in 1..10 loop
    for i in 1..6 loop
      select balance into bal from mazzobet.session_teams where session_id = s_id and team_id = i;
      if bal > 5 then perform mazzobet.transfer(s_id, 'test', 'low:' || k || ':' || i, null, 'team', i::smallint, 'bank', null, bal - 5);
      elsif bal < 5 then perform mazzobet.transfer(s_id, 'test', 'low:' || k || ':' || i, null, 'bank', null, 'team', i::smallint, 5 - bal); end if;
    end loop;
    select coalesce(max(id), 0) into ev0 from mazzobet.bank_events;
    perform mazzobet.run_bank_event(s_id);
    assert (select kind from mazzobet.bank_events where id = (select max(id) from mazzobet.bank_events)) = 'bonus',
           'nessuna squadra eleggibile al malus: l''evento diventa un bonus (giro ' || k || ')';
  end loop;
  perform mazzobet.settle(s_id);

  -- ===== Scenario 12: sponsor con cassa negativa =====
  select coalesce(sum(amount), 0) into cash from mazzobet.ledger_entries where session_id = s_id and account = 'bank';
  perform mazzobet.transfer(s_id, 'test', 'neg', null, 'bank', null, 'team', 6::smallint, cash + 5000);   -- cassa = −5000
  perform mazzobet.settle(s_id);
  assert (select cash_negative from mazzobet.game_sessions where id = s_id), 'cassa sotto zero registrata';
  assert (select count(*) from mazzobet.news where session_id = s_id and ref = 'cash:red') = 1, 'comunicato «cassa in rosso»';
  perform mazzobet.run_sponsor_event(s_id);
  assert (select amount from mazzobet.bank_events where session_id = s_id and kind = 'sponsor' order by id desc limit 1) = 2000 + 150 * 6 + 5000, 'contributo = 2000 + 150·N + max(0, −C)';
  select coalesce(sum(amount), 0) into cash from mazzobet.ledger_entries where session_id = s_id and account = 'bank';
  assert cash = 2000, 'con cassa negativa la cassa finale vale esattamente 2000 (trovata ' || cash || ')';
  perform mazzobet.settle(s_id);
  assert (select count(*) from mazzobet.news where session_id = s_id and ref = 'cash:green') = 1, 'comunicato «cassa in attivo»';
  assert (select count(*) from mazzobet.ledger_transactions where session_id = s_id and kind = 'sponsor_rain') = 6, 'pioggia a tutte le 6 squadre entrate, anche le fallite';

  -- ===== pausa e timer ripetuti (Scenario 13, lato database) =====
  update mazzobet.game_sessions set bank_paused = true, bank_next_at = now() - interval '1 second', sponsor_next_at = now() - interval '1 second' where id = s_id;
  r := public.mb_tick();
  assert (r->>'bank')::int = 0 and (r->>'sponsor')::int = 0, 'in pausa non parte nulla';
  perform mazzobet.admin_resume_bank();
  update mazzobet.game_sessions set bank_next_at = now() - interval '1 second' where id = s_id;
  select count(*) into n from mazzobet.bank_events where session_id = s_id and kind in ('bonus','malus');
  perform public.mb_tick();
  perform public.mb_tick();
  assert (select count(*) from mazzobet.bank_events where session_id = s_id and kind in ('bonus','malus')) = n + 1, 'un solo intervento anche ripetendo il timer';

  assert (select coalesce(sum(amount), 0) from mazzobet.ledger_entries) = 0, 'ledger a somma zero';
  assert not exists (select 1 from mazzobet.session_teams st where st.balance <>
     (select coalesce(sum(amount), 0) from mazzobet.ledger_entries le where le.session_id = st.session_id and le.team_id = st.team_id)), 'saldi = ledger';
  raise exception 'TEST_OK 03_bancarotta_colletta_banco';
end $$;
