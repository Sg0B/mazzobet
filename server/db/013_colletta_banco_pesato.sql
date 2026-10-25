-- Colletta limitata al saldo e Banco ordinario con estrazione pesata (decisioni 1.2 e 1.3 del 25/10/2026).
-- Applicata a giochi_ufficio il 26/10/2026 (migration mazzobet_013_colletta_banco_pesato).
--
-- 1.2  Chi paga la colletta versa al massimo il proprio saldo: mai più saldi negativi per la colletta.
--      (Chi ha 10–24 Carletti paga tutto quello che ha e, scendendo sotto soglia, cade a sua volta nella catena.)
-- Correzione di un difetto: nel Banco ordinario `select unnest(...) order by random()` ordinava una volta sola per tutto
--      l'array, quindi pescava sempre le squadre con l'id più basso. L'estrazione ora usa unnest nel FROM.
-- 1.3  Il Banco ordinario sceglie i destinatari con peso 1/(1 + interventi già ricevuti nella serata):
--      chi non è mai stato colpito ha peso pieno, chi lo è stato spesso ne ha meno. Bonus e malus contano allo stesso modo.

create or replace function mazzobet.process_chains(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_chain bigint; v_fallen smallint[]; v_all smallint[]; v_payers smallint[]; v_round int; v_t smallint;
  v_first text; v_rest text[];
  v_amount bigint := mazzobet.cfg('colletta_importo');
  v_min_payers int := mazzobet.cfg('colletta_min_paganti');
  v_thr numeric := mazzobet.cfg('bancarotta_soglia');
  v_pay bigint;
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
        select least(v_amount, balance) into v_pay from mazzobet.session_teams where session_id = p_session and team_id = v_t;
        continue when v_pay <= 0;
        perform mazzobet.transfer(p_session, 'colletta', 'colletta:' || v_chain || ':' || v_round || ':' || v_t,
                                  null, 'team', v_t, 'bank', null, v_pay);
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
  -- Estrazione pesata senza reinserimento: tempo d'attesa esponenziale con media (1 + interventi ricevuti),
  -- vince chi ha il valore più basso → probabilità proporzionale a 1/(1 + interventi).
  select array_agg(team_id order by team_id) into v_pick from (
    select e.team_id
      from unnest(v_eligible) as e(team_id)
     order by -ln(1 - random()) * (1 + (select count(*) from mazzobet.bank_events b
                                          where b.session_id = p_session and b.kind in ('bonus','malus') and e.team_id = any (b.teams)))
     limit v_n) s;
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
