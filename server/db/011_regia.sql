-- Banco di Regia: orario di inizio del Banco, scadenze ricalcolate dai parametri, esito dalla Regia,
-- annullamenti e rettifiche, reset squadre e serata, log delle azioni.
-- Tutte le funzioni mb_admin_* sono chiamabili solo dal server (service_role): il controllo del codice
-- della Regia (ADMIN_CODE) sta nel server, mai nel database né nel frontend.
-- Applicata a giochi_ufficio il 25/10/2026 (migration mazzobet_011_regia).

-- ---------------------------------------------------------------- schema

-- Il Banco (bonus, malus, sponsor, piogge) non parte prima di questo istante (secondi Unix UTC).
-- Default: 13/11/2026 ore 20:00 Europe/Rome. Modificabile dalla Regia.
insert into mazzobet.config (key, value, note) values
  ('banco_inizio', extract(epoch from timestamptz '2026-11-13 20:00:00+01'), 'secondi Unix UTC: il Banco non parte prima')
on conflict (key) do nothing;

alter table mazzobet.markets add column resolved_by_admin boolean not null default false;   -- «Esitata dalla Regia»
alter table mazzobet.game_sessions add column bank_open_announced boolean not null default false;

create table mazzobet.admin_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  session_id uuid,
  action     text not null,
  detail     jsonb not null default '{}'::jsonb,
  market_id  bigint,
  team_id    smallint
);
alter table mazzobet.admin_log enable row level security;
create index on mazzobet.admin_log (id desc);

create function mazzobet.alog(p_session uuid, p_action text, p_detail jsonb, p_market bigint default null, p_team smallint default null)
returns void language sql set search_path = '' as $$
  insert into mazzobet.admin_log (session_id, action, detail, market_id, team_id)
  values (p_session, p_action, coalesce(p_detail, '{}'::jsonb), p_market, p_team)
$$;

-- ---------------------------------------------------------------- telefoni di una serata chiusa

-- Lettura con token: se la serata del token è chiusa e ne è iniziata una nuova (reset totale, nuova serata),
-- il token non vale più e il telefono torna alla scelta della squadra. Senza una serata nuova resta la sola lettura
-- (classifica finale congelata).
create or replace function mazzobet.who_ro(p_token uuid, out o_session uuid, out o_team smallint)
language plpgsql set search_path = '' as $$
begin
  update mazzobet.team_devices set last_seen_at = now()
   where token = p_token returning session_id, team_id into o_session, o_team;
  if o_team is null then raise exception 'unauthorized'; end if;
  if (select status from mazzobet.game_sessions where id = o_session) = 'closed'
     and exists (select 1 from mazzobet.game_sessions where status in ('active','paused','closing')) then
    raise exception 'unauthorized';
  end if;
end $$;

-- ---------------------------------------------------------------- scadenze dai parametri correnti

-- Le scommesse scadute e non ancora esitate usano sempre i valori correnti di precedenza e finestra di esito:
-- si ricalcolano ad ogni tick e subito dopo una modifica dei parametri (mai un timestamp "congelato").
create function mazzobet.refresh_deadlines(p_session uuid) returns void
language sql set search_path = '' as $$
  update mazzobet.markets m
     set creator_only_until = m.scheduled_close_at + mazzobet.dur(p_session, mazzobet.cfg('precedenza_creatore_sec')::double precision),
         resolve_by = m.scheduled_close_at + mazzobet.dur(p_session, (mazzobet.cfg('precedenza_creatore_sec') + mazzobet.cfg('finestra_esito_sec'))::double precision)
   where m.session_id = p_session and m.status = 'closed'
$$;

-- ---------------------------------------------------------------- timer: Banco solo dopo banco_inizio

create or replace function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_sess uuid; v_m record; v_gs record; v_open boolean; v_start timestamptz; v_n int;
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
      else
        update mazzobet.markets set status = 'empty', actual_closed_at = scheduled_close_at, resolved_at = now() where id = v_m.id;
      end if;
      v_closed := v_closed + 1;
    end loop;

    perform mazzobet.refresh_deadlines(v_sess);

    for v_m in select id from mazzobet.markets
                where session_id = v_sess and status = 'closed' and resolve_by <= now() order by id loop
      perform mazzobet.void_market(v_m.id);
      v_void := v_void + 1;
    end loop;

    perform mazzobet.pay_fees(v_sess);

    select status, bank_next_at, sponsor_next_at, bank_paused, bank_open_announced, created_at into v_gs
      from mazzobet.game_sessions where id = v_sess;
    v_start := to_timestamp(mazzobet.cfg('banco_inizio')::double precision);
    v_open := now() >= v_start;

    if not v_open then
      -- Banco non ancora aperto: nessun timer armato (anche se le squadre sono già più di 5)
      if v_gs.bank_next_at is not null or v_gs.sponsor_next_at is not null then
        update mazzobet.game_sessions set bank_next_at = null, sponsor_next_at = null where id = v_sess;
        v_gs.bank_next_at := null; v_gs.sponsor_next_at := null;
      end if;
    elsif v_gs.status <> 'closing' then
      if not v_gs.bank_open_announced then
        update mazzobet.game_sessions set bank_open_announced = true where id = v_sess;
        if v_gs.created_at < v_start then   -- annuncio solo se la serata è iniziata prima dell'apertura del Banco
          insert into mazzobet.news (session_id, kind, title, body, ref)
          select v_sess, 'bank', t.title, t.body, 'bank_open:' || v_sess
            from (values
              ('SI APRE IL BANCO', 'Il Banco è ufficialmente aperto. D''ora in poi bonus, malus e sponsor possono colpire senza preavviso: Carletti in tasca e gambe in sella.'),
              ('SEGNALE DI PARTENZA', 'La direzione di corsa dà il via al Banco: bonus, malus e sponsor sono in strada. Buona fortuna, gregari.'),
              ('ORA DI CENA, ORA DI BANCO', 'Il Banco prende servizio. Da qui a fine serata qualcuno riceverà, qualcuno pagherà e nessuno potrà dire di non essere stato avvisato.')
            ) as t(title, body) order by random() limit 1;
        end if;
      end if;
      if v_gs.bank_next_at is null then   -- arma i timer alla quinta squadra (o subito dopo l'apertura del Banco)
        select count(*) into v_n from mazzobet.session_teams where session_id = v_sess;
        if v_n >= mazzobet.cfg('banco_squadre_per_avvio') then
          update mazzobet.game_sessions
             set bank_next_at = mazzobet.next_bank_at(v_sess), sponsor_next_at = mazzobet.next_sponsor_at(v_sess)
           where id = v_sess;
          select bank_next_at, sponsor_next_at into v_gs.bank_next_at, v_gs.sponsor_next_at
            from mazzobet.game_sessions where id = v_sess;
        end if;
      end if;
      if not v_gs.bank_paused then
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
    end if;

    perform mazzobet.settle(v_sess);
    if v_gs.status = 'closing' and mazzobet.try_finalize(v_sess) then v_final := v_final + 1; end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void, 'bank', v_bank, 'sponsor', v_sponsor, 'finalized', v_final);
end $$;

-- ---------------------------------------------------------------- stato per i giocatori: etichetta «Esitata dalla Regia»

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
          'outcome', m.outcome, 'flipped', m.flipped, 'byAdmin', m.resolved_by_admin,
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

-- ---------------------------------------------------------------- funzioni della Regia (solo server)

-- Lettura unica per la pagina Regia.
create function public.mb_admin_state() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  return jsonb_build_object(
    'now', now(),
    'sessions', mazzobet.admin_status(),
    'session', (select jsonb_build_object('id', g.id, 'name', g.name, 'status', g.status, 'endsAt', g.ends_at,
                                          'bankPaused', g.bank_paused, 'bankNextAt', g.bank_next_at, 'sponsorNextAt', g.sponsor_next_at)
                  from mazzobet.game_sessions g where g.id = v),
    'bankStart', to_timestamp(mazzobet.cfg('banco_inizio')::double precision),
    'bankOpen', now() >= to_timestamp(mazzobet.cfg('banco_inizio')::double precision),
    'params', jsonb_build_object(
        'saldo_iniziale', mazzobet.cfg('saldo_iniziale'),
        'riammissione_saldo', mazzobet.cfg('riammissione_saldo'),
        'finestra_esito_min', (mazzobet.cfg('precedenza_creatore_sec') + mazzobet.cfg('finestra_esito_sec')) / 60,
        'precedenza_creatore_min', mazzobet.cfg('precedenza_creatore_sec') / 60,
        'banco_importo_min', mazzobet.cfg('banco_importo_min'),
        'banco_importo_max', mazzobet.cfg('banco_importo_max'),
        'colletta_importo', mazzobet.cfg('colletta_importo')),
    'teams', coalesce((select jsonb_agg(jsonb_build_object(
          'id', t.id, 'name', t.name, 'entered', st.team_id is not null,
          'balance', st.balance, 'status', st.status,
          'devices', (select count(*) from mazzobet.team_devices d where d.session_id = v and d.team_id = t.id)) order by t.id)
        from mazzobet.teams t left join mazzobet.session_teams st on st.team_id = t.id and st.session_id = v), '[]'::jsonb),
    'markets', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'no', m.market_no, 'question', m.question, 'by', t.name, 'byTeamId', m.creator_team_id,
          'status', m.status, 'outcome', m.outcome, 'flipped', m.flipped, 'byAdmin', m.resolved_by_admin,
          'expiresAt', m.scheduled_close_at, 'creatorOnlyUntil', m.creator_only_until, 'resolveBy', m.resolve_by,
          'yesPool', m.yes_pool, 'noPool', m.no_pool) order by m.market_no desc)
        from (select * from mazzobet.markets where session_id = v order by market_no desc limit 40) m
        join mazzobet.teams t on t.id = m.creator_team_id), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object(
          'id', l.id, 'at', l.at, 'action', l.action, 'detail', l.detail, 'marketId', l.market_id, 'teamId', l.team_id,
          'marketNo', (select market_no from mazzobet.markets where id = l.market_id), 'team', (select name from mazzobet.teams where id = l.team_id))
        order by l.id desc)
        from (select * from mazzobet.admin_log order by id desc limit 60) l), '[]'::jsonb)
  );
end $$;

-- Reset di una squadra: scollega tutti i suoi dispositivi e la rende di nuovo libera. Saldo e storico NON si toccano.
create function public.mb_admin_reset_team(p_team smallint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_n int;
begin
  if v is null then raise exception 'no_session'; end if;
  if not exists (select 1 from mazzobet.teams where id = p_team) then raise exception 'unknown_team'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  delete from mazzobet.team_devices where session_id = v and team_id = p_team;
  get diagnostics v_n = row_count;
  perform mazzobet.alog(v, 'reset_squadra', jsonb_build_object('dispositivi', v_n), null, p_team);
  return jsonb_build_object('devices', v_n);
end $$;

-- Reset totale = nuova serata pulita: chiude (rimborsando ciò che è in corso) e ne apre una nuova.
-- Tutti ripartono dal saldo iniziale e le squadre rientrano da capo. Richiede la parola RESET.
-- Con p_restore_bank_start (default) l'apertura del Banco torna al 13/11/2026 ore 20:00: nelle serate di prova il Banco
-- non gonfia i saldi tra un reset e l'altro; la sera del 13/11 il valore è comunque già passato.
create function public.mb_admin_reset_all(p_confirm text, p_restore_bank_start boolean default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old uuid; v_new uuid; v_name text;
begin
  if p_confirm is distinct from 'RESET' then raise exception 'confirm_required'; end if;
  if p_restore_bank_start then
    update mazzobet.config set value = extract(epoch from timestamptz '2026-11-13 20:00:00+01') where key = 'banco_inizio';
  end if;
  select id into v_old from mazzobet.game_sessions where status in ('active','paused','closing') order by created_at desc limit 1;
  if v_old is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_old::text, 0));
    if (select status from mazzobet.game_sessions where id = v_old) <> 'closing' then
      perform mazzobet.admin_close_session();
    end if;
    if exists (select 1 from mazzobet.game_sessions where id = v_old and status = 'closing') then
      perform mazzobet.admin_force_finalize();
    end if;
  end if;
  if exists (select 1 from mazzobet.game_sessions where status in ('active','paused','closing')) then raise exception 'reset_failed'; end if;
  v_name := 'Serata ' || to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI');
  perform mazzobet.admin_new_session(v_name);
  select id into v_new from mazzobet.game_sessions where status = 'active' order by created_at desc limit 1;
  perform mazzobet.alog(v_new, 'reset_totale', jsonb_build_object('serataPrecedente', v_old, 'nome', v_name, 'bancoRipristinato', p_restore_bank_start));
  return public.mb_admin_state();
end $$;

-- Parametri modificabili senza deploy, con limiti di validità. La finestra di esito è il tempo TOTALE dalla scadenza
-- (precedenza del creatore inclusa): internamente resta precedenza + finestra aperta a tutti.
create function public.mb_admin_set_param(p_key text, p_value numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v uuid := mazzobet.active_session();
  v_prec numeric := mazzobet.cfg('precedenza_creatore_sec');
  v_total numeric := mazzobet.cfg('precedenza_creatore_sec') + mazzobet.cfg('finestra_esito_sec');
  v_old numeric;
begin
  if p_value is null or p_value <> floor(p_value) then raise exception 'bad_param'; end if;
  if v is not null then perform pg_advisory_xact_lock(hashtextextended(v::text, 0)); end if;
  case p_key
    when 'saldo_iniziale' then
      if p_value < 0 or p_value > 1000000 then raise exception 'bad_param'; end if;
      v_old := mazzobet.cfg('saldo_iniziale'); update mazzobet.config set value = p_value where key = 'saldo_iniziale';
    when 'riammissione_saldo' then
      if p_value < 10 or p_value > 1000000 then raise exception 'bad_param'; end if;
      v_old := mazzobet.cfg('riammissione_saldo'); update mazzobet.config set value = p_value where key = 'riammissione_saldo';
    when 'finestra_esito_min' then
      if p_value * 60 <= v_prec or p_value > 1440 then raise exception 'bad_param'; end if;
      v_old := v_total / 60; update mazzobet.config set value = p_value * 60 - v_prec where key = 'finestra_esito_sec';
    when 'precedenza_creatore_min' then
      if p_value < 0 or p_value * 60 >= v_total then raise exception 'bad_param'; end if;
      v_old := v_prec / 60;
      update mazzobet.config set value = p_value * 60 where key = 'precedenza_creatore_sec';
      update mazzobet.config set value = v_total - p_value * 60 where key = 'finestra_esito_sec';
    when 'banco_importo_min' then
      if p_value < 10 or p_value > mazzobet.cfg('banco_importo_max') then raise exception 'bad_param'; end if;
      v_old := mazzobet.cfg('banco_importo_min'); update mazzobet.config set value = p_value where key = 'banco_importo_min';
    when 'banco_importo_max' then
      if p_value < mazzobet.cfg('banco_importo_min') or p_value > 5000 then raise exception 'bad_param'; end if;
      v_old := mazzobet.cfg('banco_importo_max'); update mazzobet.config set value = p_value where key = 'banco_importo_max';
    when 'colletta_importo' then
      if p_value < 1 or p_value > 1000 then raise exception 'bad_param'; end if;
      v_old := mazzobet.cfg('colletta_importo'); update mazzobet.config set value = p_value where key = 'colletta_importo';
    else raise exception 'bad_param';
  end case;
  if v is not null then perform mazzobet.refresh_deadlines(v); end if;
  perform mazzobet.alog(v, 'parametro', jsonb_build_object('chiave', p_key, 'prima', v_old, 'dopo', p_value));
  return public.mb_admin_state();
end $$;

-- Orario di apertura del Banco. Se è nel futuro il Banco si ferma e riparte da lì; nel passato vale "subito".
create function public.mb_admin_set_bank_start(p_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_old timestamptz := to_timestamp(mazzobet.cfg('banco_inizio')::double precision);
begin
  if p_at is null then raise exception 'bad_param'; end if;
  update mazzobet.config set value = extract(epoch from p_at) where key = 'banco_inizio';
  perform mazzobet.alog(v, 'banco_inizio', jsonb_build_object('prima', v_old, 'dopo', p_at));
  return public.mb_admin_state();
end $$;

-- «Avvia Banco adesso»: apre il Banco e lo toglie dalla pausa; i timer partono entro pochi secondi.
create function public.mb_admin_bank_now() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  update mazzobet.config set value = extract(epoch from now()) where key = 'banco_inizio';
  if v is not null then
    perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
    update mazzobet.game_sessions set bank_paused = false where id = v;
  end if;
  perform mazzobet.alog(v, 'banco_adesso', '{}'::jsonb);
  return public.mb_admin_state();
end $$;

create function public.mb_admin_bank_pause(p_paused boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  if p_paused then perform mazzobet.admin_pause_bank(); else perform mazzobet.admin_resume_bank(); end if;
  perform mazzobet.alog(v, case when p_paused then 'banco_pausa' else 'banco_ripresa' end, '{}'::jsonb);
  return public.mb_admin_state();
end $$;

create function public.mb_admin_close_session() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  if v is null then raise exception 'no_session'; end if;
  perform mazzobet.admin_close_session();
  perform mazzobet.alog(v, 'chiusura_serata', '{}'::jsonb);
  return public.mb_admin_state();
end $$;

create function public.mb_admin_force_finalize() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  select id into v from mazzobet.game_sessions where status = 'closing' order by created_at desc limit 1;
  if v is null then raise exception 'no_session'; end if;
  perform mazzobet.admin_force_finalize();
  perform mazzobet.alog(v, 'chiusura_forzata', '{}'::jsonb);
  return public.mb_admin_state();
end $$;

-- Esito dalla Regia: definitivo, puntate pagate subito, nessuna contestazione. Il creatore riceve il compenso C come se
-- avesse esitato lui; la Regia non incassa nulla e non muove Carletti a proprio favore.
create function public.mb_admin_resolve(p_market bigint, p_outcome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid := mazzobet.active_session(); v_m mazzobet.markets; v_bet record; v_pay bigint;
  v_total bigint; v_c bigint; v_best bigint := 0; v_best_team smallint; v_name text;
begin
  if v_s is null then raise exception 'no_session'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_s::text, 0));
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if p_outcome not in ('yes','no') then raise exception 'invalid_side'; end if;
  if v_m.status = 'resolved' then raise exception 'already_resolved'; end if;
  if v_m.status in ('void','empty') then raise exception 'not_resolvable'; end if;
  if v_m.status = 'open' then
    update mazzobet.markets set status = 'closed', actual_closed_at = now() where id = p_market;
  end if;

  v_total := v_m.yes_pool + v_m.no_pool;
  v_c := least(floor(v_total * mazzobet.cfg('compenso_percentuale') / 100), mazzobet.cfg('compenso_tetto'));

  update mazzobet.markets
     set status = 'resolved', outcome = p_outcome, resolved_at = now(), resolved_by_team_id = null, resolved_by_admin = true,
         appeal_deadline_at = now() - interval '1 second',   -- nessuna finestra di contestazione
         fee_amount = v_c, fee_team_id = case when v_c > 0 then v_m.creator_team_id end
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

  for v_bet in select team_id from mazzobet.bets where market_id = p_market order by team_id loop
    perform mazzobet.check_bankruptcy(v_s, v_bet.team_id);
  end loop;

  if v_best >= mazzobet.cfg('grande_vincita_soglia') then
    select name into v_name from mazzobet.teams where id = v_best_team;
    perform mazzobet.post_news(v_s, 'radiocorsa', 'grande_vincita',
            jsonb_build_object('nomeSquadra', v_name, 'importo', mazzobet.fmt(v_best)), 'bank', 'bigwin:' || p_market);
  end if;

  perform mazzobet.pay_fees(v_s);   -- compenso al creatore subito (finestra di contestazione già chiusa)
  perform mazzobet.settle(v_s);
  perform mazzobet.alog(v_s, 'esito_regia', jsonb_build_object('esito', p_outcome, 'compensoCreatore', v_c), p_market, v_m.creator_team_id);
  return jsonb_build_object('marketId', p_market, 'outcome', p_outcome);
end $$;

-- Annulla con rimborso delle puntate (il costo di creazione non si restituisce, come per gli annullamenti automatici).
create function public.mb_admin_void(p_market bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid := mazzobet.active_session(); v_m mazzobet.markets;
begin
  if v_s is null then raise exception 'no_session'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_s::text, 0));
  select * into v_m from mazzobet.markets where id = p_market and session_id = v_s for update;
  if not found then raise exception 'market_not_found'; end if;
  if v_m.status not in ('open','closed') then raise exception 'not_voidable'; end if;
  perform mazzobet.void_market(p_market);
  perform mazzobet.settle(v_s);
  perform mazzobet.alog(v_s, 'annulla_rimborso', '{}'::jsonb, p_market, v_m.creator_team_id);
  return jsonb_build_object('marketId', p_market);
end $$;

-- Rettifica del saldo con motivo obbligatorio. Passa dal registro dei movimenti (contro la cassa del Banco).
create function public.mb_admin_adjust(p_team smallint, p_delta bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s uuid := mazzobet.active_session(); v_bal bigint;
begin
  if v_s is null then raise exception 'no_session'; end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000 then raise exception 'bad_param'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 then raise exception 'reason_required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_s::text, 0));
  select balance into v_bal from mazzobet.session_teams where session_id = v_s and team_id = p_team for update;
  if not found then raise exception 'unknown_team'; end if;
  if v_bal + p_delta < 0 then raise exception 'insufficient_funds'; end if;
  if p_delta > 0 then
    perform mazzobet.transfer(v_s, 'rettifica', 'rettifica:' || gen_random_uuid(), null, 'bank', null, 'team', p_team, p_delta);
  else
    perform mazzobet.transfer(v_s, 'rettifica', 'rettifica:' || gen_random_uuid(), null, 'team', p_team, 'bank', null, -p_delta);
  end if;
  perform mazzobet.settle(v_s);
  perform mazzobet.alog(v_s, 'rettifica_saldo', jsonb_build_object('importo', p_delta, 'motivo', btrim(p_reason), 'saldoPrima', v_bal), null, p_team);
  return jsonb_build_object('teamId', p_team, 'balance', v_bal + p_delta);
end $$;

-- Permessi: solo il server (service_role) può chiamare le funzioni mb_*.
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
