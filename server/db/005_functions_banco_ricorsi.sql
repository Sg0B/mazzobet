-- Fase 3–4: funzioni. Ogni azione economica prende prima il lock della serata (advisory):
-- le operazioni sono quindi serializzate e le catene che toccano molte squadre non possono andare in deadlock.

-- ---------------------------------------------------------------- helper interni

create or replace function mazzobet.who(p_token uuid, out o_session uuid, out o_team smallint)
language plpgsql set search_path = '' as $$
begin
  select session_id, team_id into o_session, o_team from mazzobet.team_devices where token = p_token;
  if o_team is null then raise exception 'unauthorized'; end if;
  perform pg_advisory_xact_lock(hashtextextended(o_session::text, 0));
  update mazzobet.team_devices set last_seen_at = now() where token = p_token;
end $$;

-- Come who(), ma senza lock: per le sole letture.
create function mazzobet.who_ro(p_token uuid, out o_session uuid, out o_team smallint)
language plpgsql set search_path = '' as $$
begin
  update mazzobet.team_devices set last_seen_at = now()
   where token = p_token returning session_id, team_id into o_session, o_team;
  if o_team is null then raise exception 'unauthorized'; end if;
end $$;

create or replace function mazzobet.adjust(p_session uuid, p_team smallint, p_delta bigint) returns void
language plpgsql set search_path = '' as $$
declare v_bal bigint; v_status text;
begin
  update mazzobet.session_teams set balance = balance + p_delta
   where session_id = p_session and team_id = p_team returning balance, status into v_bal, v_status;
  if v_bal < 10 and v_status = 'in_game' then
    update mazzobet.session_teams
       set status = 'bankrupt', bankrupt_until = now() + interval '5 minutes', bankruptcies = bankruptcies + 1
     where session_id = p_session and team_id = p_team;
    -- la colletta parte da qui, in process_chains(), a fine operazione
    insert into mazzobet.bankruptcy_events (session_id, team_id) values (p_session, p_team);
  elsif v_bal >= 10 and v_status = 'bankrupt' then
    update mazzobet.session_teams set status = 'in_game', bankrupt_until = null
     where session_id = p_session and team_id = p_team;
  end if;
end $$;

create function mazzobet.fmt(n bigint) returns text
language sql immutable set search_path = '' as $$ select replace(to_char(n, 'FM999,999,999,999'), ',', '.') $$;

-- «A», «A e B», «A, B e C»
create function mazzobet.join_names(p text[]) returns text
language sql immutable set search_path = '' as $$
  select case coalesce(cardinality(p), 0)
           when 0 then '' when 1 then p[1]
           else array_to_string(p[1:cardinality(p) - 1], ', ') || ' e ' || p[cardinality(p)] end
$$;

-- Pubblica una notizia: pesca un testo dal catalogo, sostituisce i segnaposto e salva il testo già renderizzato.
-- Se manca un template adatto usa un testo di riserva: un errore editoriale non blocca mai una transazione economica.
create function mazzobet.post_news(p_session uuid, p_cat text, p_event text, p_vars jsonb, p_news_kind text, p_ref text)
returns void
language plpgsql set search_path = '' as $$
declare v_e mazzobet.catalog_entries; v_title text; v_body text; v_k text;
begin
  select * into v_e from mazzobet.catalog_entries
   where kind = p_cat and (p_event is null or event = p_event) order by random() limit 1;
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
  insert into mazzobet.news (session_id, kind, title, body, ref) values (p_session, p_news_kind, v_title, v_body, p_ref);
end $$;

-- Catena di collette (PRD §9.2): ₡25 a ogni squadra in gara, non in bancarotta, con saldo ≥ 10, a giri;
-- chi scende sotto ₡10 innesca il giro successivo; un giro si fa solo con almeno 3 paganti.
-- Un solo prelievo per squadra per giro, anche con più fallimenti simultanei. Una notizia per catena.
create function mazzobet.process_chains(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_chain bigint; v_fallen smallint[]; v_all smallint[]; v_payers smallint[]; v_round int; v_t smallint;
  v_first text; v_rest text[];
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
       where session_id = p_session and status = 'in_game' and balance >= 10;
      exit when coalesce(cardinality(v_payers), 0) < 3;      -- valvola: almeno 3 paganti
      v_round := v_round + 1;
      insert into mazzobet.collection_rounds (chain_id, round_no, payers, fallen)
      values (v_chain, v_round, cardinality(v_payers), v_fallen);
      foreach v_t in array v_payers loop
        perform mazzobet.transfer(p_session, 'colletta', 'colletta:' || v_chain || ':' || v_round || ':' || v_t,
                                  null, 'team', v_t, 'bank', null, 25);
      end loop;
      with u as (update mazzobet.bankruptcy_events set chain_id = v_chain
                  where session_id = p_session and chain_id is null returning team_id, id)
      select array_agg(team_id order by id) into v_fallen from u;
      exit when v_fallen is null;                              -- nessun nuovo caduto: la catena finisce
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
                                 jsonb_build_object('nomeSquadra', v_first, 'importo', '25'), 'bank', 'chain:' || v_chain);
    end if;
  end loop;
end $$;

-- Intervento ordinario del Banco (PRD §9.1): 1–3 squadre, importo unico ₡100–250, 55% bonus / 45% malus.
-- I malus escludono le squadre con saldo < 10; senza eleggibili l'evento diventa un bonus.
create function mazzobet.run_bank_event(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_bonus boolean := random() < 0.55;
  v_eligible smallint[]; v_pick smallint[]; v_n int; v_amount bigint; v_ev bigint; v_t smallint; v_names text[];
begin
  if not v_bonus then
    select array_agg(team_id) into v_eligible from mazzobet.session_teams
     where session_id = p_session and status = 'in_game' and balance >= 10;
    if v_eligible is null then v_bonus := true; end if;
  end if;
  if v_bonus then
    select array_agg(team_id) into v_eligible from mazzobet.session_teams where session_id = p_session;
  end if;
  if v_eligible is null then return; end if;

  v_n := least(1 + floor(random() * 3)::int, cardinality(v_eligible));
  select array_agg(t order by t) into v_pick from (select unnest(v_eligible) as t order by random() limit v_n) s;
  v_amount := 100 + floor(random() * 151)::int;

  insert into mazzobet.bank_events (session_id, kind, teams, amount)
  values (p_session, case when v_bonus then 'bonus' else 'malus' end, v_pick, v_amount) returning id into v_ev;

  foreach v_t in array v_pick loop
    if v_bonus then
      perform mazzobet.transfer(p_session, 'bonus', 'bank_bonus:' || v_ev || ':' || v_t, null, 'bank', null, 'team', v_t, v_amount);
    else
      perform mazzobet.transfer(p_session, 'malus', 'bank_malus:' || v_ev || ':' || v_t, null, 'team', v_t, 'bank', null, v_amount);
    end if;
  end loop;

  select array_agg(name order by name) into v_names from mazzobet.teams where id = any (v_pick);
  perform mazzobet.post_news(p_session, case when v_bonus then 'bonus' else 'malus' end, null,
          jsonb_build_object('nomeSquadre', mazzobet.join_names(v_names), 'importo', mazzobet.fmt(v_amount)),
          case when v_bonus then 'bonus' else 'malus' end, 'bank:' || v_ev);
end $$;

-- Sponsor (PRD §9.3): contributo = 2000 + 150·N + max(0, −C); pioggia di ₡150 a ciascuna delle N squadre
-- entrate, bancarottate incluse; tutto nella stessa transazione. Indipendente dal saldo del Banco.
create function mazzobet.run_sponsor_event(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_c bigint; v_n int; v_contrib bigint; v_ev bigint; v_t smallint; v_sponsor text; v_id text;
begin
  select coalesce(sum(amount), 0) into v_c from mazzobet.ledger_entries where session_id = p_session and account = 'bank';
  select count(*) into v_n from mazzobet.session_teams where session_id = p_session;
  v_contrib := 2000 + 150 * v_n + greatest(0, -v_c);

  select id, event into v_id, v_sponsor from mazzobet.catalog_entries where kind = 'sponsor' order by random() limit 1;
  v_sponsor := coalesce(v_sponsor, 'Lo sponsor');

  insert into mazzobet.bank_events (session_id, kind, amount, detail)
  values (p_session, 'sponsor', v_contrib,
          jsonb_build_object('sponsor', v_sponsor, 'catalogId', v_id, 'teams', v_n, 'cashBefore', v_c))
  returning id into v_ev;

  perform mazzobet.transfer(p_session, 'sponsor_cash', 'sponsor_cash:' || v_ev, null, 'sponsor', null, 'bank', null, v_contrib);
  for v_t in select team_id from mazzobet.session_teams where session_id = p_session order by team_id loop
    perform mazzobet.transfer(p_session, 'sponsor_rain', 'sponsor_rain:' || v_ev || ':' || v_t, null, 'bank', null, 'team', v_t, 150);
  end loop;

  perform mazzobet.post_news(p_session, 'sponsor', v_sponsor,
          jsonb_build_object('nomeSponsor', v_sponsor, 'importoSponsor', mazzobet.fmt(v_contrib),
                             'numeroSquadre', v_n::text, 'importoPerSquadra', '150'),
          'sponsor', 'sponsor:' || v_ev);
end $$;

-- ---------------------------------------------------------------- API pubblica

-- Carica/aggiorna il catalogo editoriale (validato dal server prima della chiamata).
create function public.mb_load_catalog(p jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  delete from mazzobet.catalog_entries;
  insert into mazzobet.catalog_entries (id, kind, event, title, body, body2)
  select e->>'id', 'bonus', e->>'evento', e->>'titolo', e->>'testo', null from jsonb_array_elements(p->'bonus') e
  union all
  select e->>'id', 'malus', e->>'evento', e->>'titolo', e->>'testo', null from jsonb_array_elements(p->'malus') e
  union all
  select e->>'id', 'sponsor', e->>'nome', e->>'titolo', e->>'testoCassa', e->>'testoPioggia' from jsonb_array_elements(p->'sponsor') e
  union all
  select e->>'id', 'radiocorsa', e->>'evento', e->>'titolo', e->>'testo', null from jsonb_array_elements(p->'radiocorsa') e;
  get diagnostics n = row_count;
  return n;
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
    -- all'ingresso della quinta squadra partono, una sola volta, i due timer indipendenti del Banco
    if (select count(*) from mazzobet.session_teams where session_id = v_session) >= 5 then
      update mazzobet.game_sessions
         set bank_next_at    = now() + make_interval(secs => 480 + floor(random() * 361)),
             sponsor_next_at = now() + make_interval(secs => 480 + floor(random() * 2221))
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
  if p_expires_at < now() + interval '1 minute' then raise exception 'expiry_too_soon'; end if;
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
  perform mazzobet.process_chains(v_s);
  return jsonb_build_object('betId', v_id, 'replay', false);
end $$;

-- Ricorso (PRD §7): tutte e sole le squadre che hanno puntato, entro 3' dall'esito. Con la maggioranza assoluta
-- dei distinti scommettitori floor(N/2)+1 l'esito si ribalta una sola volta, con UNA rettifica netta per scommettitore.
create function public.mb_appeal(p_token uuid, p_market bigint) returns jsonb
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
  if v_appeals < v_bettors / 2 + 1 then            -- floor(N/2)+1; contatore e soglia non sono mai mostrati
    return jsonb_build_object('flipped', false, 'replay', false);
  end if;

  v_new := case v_m.outcome when 'yes' then 'no' else 'yes' end;
  update mazzobet.markets set outcome = v_new, flipped = true where id = p_market;

  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    v_new_pay := case when v_bet.side = v_new then floor(v_bet.amount * v_bet.odds_cents / 100.0) else 0 end;
    v_delta := v_new_pay - coalesce(v_bet.payout, 0);   -- rettifica netta: nuovo − vecchio payout
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
  perform mazzobet.process_chains(v_s);
  return jsonb_build_object('flipped', true, 'outcome', v_new);
end $$;

create or replace function public.mb_readmit(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid; v_t smallint; v_row mazzobet.session_teams; v_name text;
begin
  select * into v_s, v_t from mazzobet.who(p_token);
  select * into v_row from mazzobet.session_teams where session_id = v_s and team_id = v_t for update;
  if v_row.status <> 'bankrupt' then raise exception 'not_bankrupt'; end if;
  if v_row.bankrupt_until > now() then raise exception 'lock_active'; end if;
  update mazzobet.session_teams set readmissions = readmissions + 1 where session_id = v_s and team_id = v_t;
  perform mazzobet.transfer(v_s, 'readmit', 'readmit:' || v_t || ':' || (v_row.readmissions + 1), null,
                            'bank', null, 'team', v_t, 500 - v_row.balance);
  select name into v_name from mazzobet.teams where id = v_t;
  perform mazzobet.post_news(v_s, 'radiocorsa', 'riammissione',
          jsonb_build_object('nomeSquadra', v_name, 'importo', '500'), 'bank', 'readmit:' || v_t || ':' || (v_row.readmissions + 1));
  return jsonb_build_object('balance', 500);
end $$;

-- Timer persistenti, tutti derivati dagli orari nel DB (sicuri dopo un riavvio e con worker concorrenti):
-- chiusura mercati, annullamento a 15', Banco ordinario 8–14', sponsor 8–45', catene di colletta.
create or replace function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_sess uuid; v_m record; v_bet record; v_gs record;
  v_closed int := 0; v_void int := 0; v_bank int := 0; v_sponsor int := 0;
begin
  for v_sess in select id from mazzobet.game_sessions where status in ('active','paused') loop
    perform pg_advisory_xact_lock(hashtextextended(v_sess::text, 0));

    for v_m in select id from mazzobet.markets
                where session_id = v_sess and status = 'open' and scheduled_close_at <= now() order by id loop
      update mazzobet.markets
         set status = 'closed', actual_closed_at = scheduled_close_at,
             resolve_by = scheduled_close_at + interval '15 minutes'
       where id = v_m.id;
      v_closed := v_closed + 1;
    end loop;

    for v_m in select id, market_no from mazzobet.markets
                where session_id = v_sess and status = 'closed' and resolve_by <= now() order by id loop
      for v_bet in select * from mazzobet.bets where market_id = v_m.id order by team_id loop
        perform mazzobet.transfer(v_sess, 'refund', 'refund:' || v_bet.id, v_m.id, 'bank', null, 'team', v_bet.team_id, v_bet.amount);
        update mazzobet.bets set result = 'void', payout = v_bet.amount where id = v_bet.id;
      end loop;
      update mazzobet.markets set status = 'void', resolved_at = now() where id = v_m.id;
      perform mazzobet.post_news(v_sess, 'radiocorsa', 'mercato_annullato',
              jsonb_build_object('numeroScommessa', v_m.market_no::text), 'bank', 'void:' || v_m.id);
      v_void := v_void + 1;
    end loop;

    select bank_next_at, sponsor_next_at, bank_paused into v_gs from mazzobet.game_sessions where id = v_sess;
    if not v_gs.bank_paused then
      if v_gs.bank_next_at is not null and v_gs.bank_next_at <= now() then
        perform mazzobet.run_bank_event(v_sess);
        update mazzobet.game_sessions set bank_next_at = now() + make_interval(secs => 480 + floor(random() * 361)) where id = v_sess;
        v_bank := v_bank + 1;
      end if;
      if v_gs.sponsor_next_at is not null and v_gs.sponsor_next_at <= now() then
        perform mazzobet.run_sponsor_event(v_sess);
        update mazzobet.game_sessions set sponsor_next_at = now() + make_interval(secs => 480 + floor(random() * 2221)) where id = v_sess;
        v_sponsor := v_sponsor + 1;
      end if;
    end if;

    perform mazzobet.process_chains(v_sess);
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void, 'bank', v_bank, 'sponsor', v_sponsor);
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
          'status', m.status, 'resolveBy', m.resolve_by, 'outcome', m.outcome, 'flipped', m.flipped,
          'appealUntil', m.appeal_deadline_at, 'yesPool', m.yes_pool, 'noPool', m.no_pool,
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
