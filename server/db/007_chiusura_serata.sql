-- Fase finale: pausa del Banco, chiusura serata in due tempi, classifica congelata, snippet operativi.
-- Le funzioni "admin" stanno nello schema mazzobet: non sono raggiungibili dall'API, solo dall'editor SQL.
--
-- Stati serata: active → closing (niente nuove puntate/creazioni; esiti e ricorsi in corso finiscono)
--                     → closed (classifica congelata, sola lettura).

alter table mazzobet.game_sessions drop constraint game_sessions_status_check;
alter table mazzobet.game_sessions add constraint game_sessions_status_check
  check (status in ('active','paused','closing','closed'));
alter table mazzobet.game_sessions add column closing_at timestamptz, add column closed_at timestamptz;

-- Classifica finale immutabile (fotografia al momento della chiusura).
create table mazzobet.final_standings (
  session_id    uuid not null references mazzobet.game_sessions(id),
  team_id       smallint not null,
  rank_wealth   int not null,
  balance       bigint not null,
  correct_picks int not null,
  rank_picks    int not null,
  bankruptcies  int not null,
  readmissions  int not null,
  primary key (session_id, team_id)
);
alter table mazzobet.final_standings enable row level security;
create trigger final_standings_immutable before update or delete on mazzobet.final_standings
  for each row execute function mazzobet.forbid_change();

-- Con la serata in chiusura (o chiusa) nessuna nuova puntata né creazione, anche a livello di database.
create function mazzobet.block_when_closing() returns trigger
language plpgsql set search_path = '' as $$
declare v_status text;
begin
  select status into v_status from mazzobet.game_sessions where id = new.session_id;
  if v_status = 'closing' then raise exception 'session_closing'; end if;
  if v_status = 'closed' then raise exception 'session_closed'; end if;
  return new;
end $$;
create trigger markets_block_closing before insert on mazzobet.markets
  for each row execute function mazzobet.block_when_closing();
create trigger bets_block_closing before insert on mazzobet.bets
  for each row execute function mazzobet.block_when_closing();

-- Serata chiusa = sola lettura: ogni azione che scrive passa da who() e viene respinta.
create or replace function mazzobet.who(p_token uuid, out o_session uuid, out o_team smallint)
language plpgsql set search_path = '' as $$
begin
  select session_id, team_id into o_session, o_team from mazzobet.team_devices where token = p_token;
  if o_team is null then raise exception 'unauthorized'; end if;
  perform pg_advisory_xact_lock(hashtextextended(o_session::text, 0));
  if (select status from mazzobet.game_sessions where id = o_session) = 'closed' then
    raise exception 'session_closed';
  end if;
  update mazzobet.team_devices set last_seen_at = now() where token = p_token;
end $$;

-- Annulla e rimborsa un mercato (puntate rimborsate, ₡100 di creazione NON restituiti).
create function mazzobet.void_market(p_market bigint) returns void
language plpgsql set search_path = '' as $$
declare v_m mazzobet.markets; v_bet record;
begin
  select * into v_m from mazzobet.markets where id = p_market for update;
  if v_m.status not in ('open','closed') then return; end if;
  for v_bet in select * from mazzobet.bets where market_id = p_market order by team_id loop
    perform mazzobet.transfer(v_m.session_id, 'refund', 'refund:' || v_bet.id, p_market, 'bank', null, 'team', v_bet.team_id, v_bet.amount);
    update mazzobet.bets set result = 'void', payout = v_bet.amount where id = v_bet.id;
  end loop;
  update mazzobet.markets set status = 'void', resolved_at = now() where id = p_market;
  perform mazzobet.post_news(v_m.session_id, 'radiocorsa', 'mercato_annullato',
          jsonb_build_object('numeroScommessa', v_m.market_no::text), 'bank', 'void:' || p_market);
end $$;

-- Congela la serata se non resta nulla di pendente (o con p_force, annullando i mercati pendenti).
-- Idempotente. Ritorna true se la serata è (ora) chiusa.
create function mazzobet.try_finalize(p_session uuid, p_force boolean default false) returns boolean
language plpgsql set search_path = '' as $$
declare v_status text; v_m record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_session::text, 0));
  select status into v_status from mazzobet.game_sessions where id = p_session;
  if v_status = 'closed' then return true; end if;
  if v_status <> 'closing' then return false; end if;

  if p_force then
    for v_m in select id from mazzobet.markets where session_id = p_session and status in ('open','closed') order by id loop
      perform mazzobet.void_market(v_m.id);
    end loop;
  elsif exists (select 1 from mazzobet.markets where session_id = p_session and status in ('open','closed'))
     or exists (select 1 from mazzobet.markets where session_id = p_session and status = 'resolved'
                  and not flipped and appeal_deadline_at > now()) then
    return false;                                   -- esiti o ricorsi ancora in corso
  end if;

  perform mazzobet.process_chains(p_session);
  update mazzobet.game_sessions set status = 'closed', closed_at = now(), bank_paused = true where id = p_session;

  insert into mazzobet.final_standings
  select p_session, st.team_id,
         rank() over (order by st.balance desc, st.correct_picks desc),
         st.balance, st.correct_picks,
         rank() over (order by st.correct_picks desc, st.balance desc),
         st.bankruptcies, st.readmissions
    from mazzobet.session_teams st where st.session_id = p_session;
  return true;
end $$;

-- ---------------------------------------------------------------- snippet operativi (editor SQL)

create function mazzobet.admin_status() returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'session', g.name, 'status', g.status, 'bankPaused', g.bank_paused,
    'nextBank', g.bank_next_at, 'nextSponsor', g.sponsor_next_at, 'endsAt', g.ends_at,
    'teams', (select count(*) from mazzobet.session_teams where session_id = g.id),
    'openMarkets', (select count(*) from mazzobet.markets where session_id = g.id and status = 'open'),
    'awaitingResult', (select count(*) from mazzobet.markets where session_id = g.id and status = 'closed'),
    'inAppealWindow', (select count(*) from mazzobet.markets where session_id = g.id and status = 'resolved' and not flipped and appeal_deadline_at > now()),
    'bankCash', (select coalesce(sum(amount), 0) from mazzobet.ledger_entries where session_id = g.id and account = 'bank')
  ) order by g.created_at desc), '[]'::jsonb)
  from (select * from mazzobet.game_sessions order by created_at desc limit 3) g
$$;

-- (a) Pausa del Banco: ferma sia gli interventi ordinari sia gli sponsor.
create function mazzobet.admin_pause_bank() returns text
language plpgsql set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  if v is null then return 'nessuna serata attiva'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  update mazzobet.game_sessions set bank_paused = true where id = v;
  return 'Banco in pausa';
end $$;

-- Ripresa: due nuovi intervalli casuali, senza recuperare gli eventi persi.
create function mazzobet.admin_resume_bank() returns text
language plpgsql set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  if v is null then return 'nessuna serata attiva'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  update mazzobet.game_sessions
     set bank_paused = false,
         bank_next_at = case when bank_next_at is null then null else now() + make_interval(secs => 480 + floor(random() * 361)) end,
         sponsor_next_at = case when sponsor_next_at is null then null else now() + make_interval(secs => 480 + floor(random() * 2221)) end
   where id = v;
  return 'Banco riattivato';
end $$;

-- (b) Chiusura serata, tempo 1: nessuna nuova puntata/creazione, Banco fermo.
-- Esiti e ricorsi in corso finiscono; poi il server congela da solo la classifica (mb_tick).
create function mazzobet.admin_close_session() returns jsonb
language plpgsql set search_path = '' as $$
declare v uuid := mazzobet.active_session();
begin
  if v is null then return mazzobet.admin_status(); end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  update mazzobet.game_sessions set status = 'closing', closing_at = now(), bank_paused = true where id = v;
  perform mazzobet.try_finalize(v);
  return mazzobet.admin_status();
end $$;

-- Chiusura serata, tempo 2 (opzionale, emergenza): annulla e rimborsa subito i mercati pendenti e congela.
create function mazzobet.admin_force_finalize() returns jsonb
language plpgsql set search_path = '' as $$
declare v uuid;
begin
  select id into v from mazzobet.game_sessions where status = 'closing' order by created_at desc limit 1;
  if v is null then return jsonb_build_object('error', 'nessuna serata in chiusura: esegui prima admin_close_session()'); end if;
  perform mazzobet.try_finalize(v, true);
  return mazzobet.admin_status();
end $$;

-- Nuova serata (la precedente deve essere chiusa). Fine serata di default: prossime 03:00 Europe/Rome.
create function mazzobet.admin_new_session(p_name text default 'Serata', p_ends_at timestamptz default null) returns jsonb
language plpgsql set search_path = '' as $$
declare v_end timestamptz := p_ends_at;
begin
  if exists (select 1 from mazzobet.game_sessions where status in ('active','paused','closing')) then
    return jsonb_build_object('error', 'esiste già una serata non chiusa');
  end if;
  if v_end is null then
    select (case when r.n::time < time '03:00' then date_trunc('day', r.n) + interval '3 hours'
                 else date_trunc('day', r.n) + interval '1 day 3 hours' end) at time zone 'Europe/Rome'
      into v_end from (select now() at time zone 'Europe/Rome' as n) r;
  end if;
  insert into mazzobet.game_sessions (name, ends_at) values (p_name, v_end);
  return mazzobet.admin_status();
end $$;

-- ---------------------------------------------------------------- timer

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
             resolve_by = scheduled_close_at + interval '15 minutes'
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
    if v_gs.status = 'closing' and mazzobet.try_finalize(v_sess) then v_final := v_final + 1; end if;
  end loop;
  return jsonb_build_object('closed', v_closed, 'void', v_void, 'bank', v_bank, 'sponsor', v_sponsor, 'finalized', v_final);
end $$;

revoke all on function public.mb_tick() from public, anon, authenticated;
grant execute on function public.mb_tick() to service_role;
