-- Banco graduale: dal lancio il Banco c'è sempre, ma con un ritmo che cresce verso la serata.
--   «tranquillo»   dal 10/11 09:00  → un intervento ogni 60–120', importi 50–100, fermo di notte (01–09)
--   «imbizzarrito» dal 13/11 15:00  → ogni 20–40', importi 100–250
--   «serata»       dal 13/11 20:00  → valori di config (8–14', 100–250, modificabili dalla Regia)
-- Lo sponsor (pioggia) resta legato a banco_inizio (13/11 20:00), come prima.
-- Senza righe in bank_phases tutto funziona esattamente come prima della 027.
-- Le fasi si cambiano con un UPDATE su mazzobet.bank_phases, senza deploy (vedi ops/08_fasi_banco.sql).

create table mazzobet.bank_phases (
  id               smallint primary key,
  starts_at        timestamptz not null unique,
  name             text not null,
  interval_min_sec int,                 -- null = config banco_intervallo_min_sec
  interval_max_sec int,                 -- null = config banco_intervallo_max_sec
  amount_min       int,                 -- null = config banco_importo_min
  amount_max       int,                 -- null = config banco_importo_max
  quiet_night      boolean not null default false,
  news_title       text,                -- notizia RadioCorsa all'inizio della fase (facoltativa)
  news_body        text,
  check (interval_min_sec is null or interval_min_sec >= 60),
  check (interval_max_sec is null or interval_min_sec is null or interval_max_sec >= interval_min_sec),
  check (amount_min is null or amount_min >= 10),
  check (amount_max is null or amount_min is null or amount_max >= amount_min)
);
alter table mazzobet.bank_phases enable row level security;   -- nessun accesso dall'API: solo le funzioni

insert into mazzobet.bank_phases values
  (1, timestamptz '2026-11-10 09:00:00+01', 'tranquillo', 3600, 7200, 50, 100, true,
   'IL BANCO SI SVEGLIA',
   'Da oggi il Banco è in strada: per ora pedala piano, un colpo ogni tanto e di notte dorme. Ma nessuno ha detto che resterà così.'),
  (2, timestamptz '2026-11-13 15:00:00+01', 'imbizzarrito', 1200, 2400, 100, 250, false,
   'IL BANCO SI È IMBIZZARRITO',
   'Qualcuno ha tolto il freno al Banco: da adesso bonus e malus arrivano molto più spesso, e più pesanti. Tenetevi forte.'),
  (3, timestamptz '2026-11-13 20:00:00+01', 'serata', null, null, null, null, false,
   'BANCO A TUTTA',
   'È la serata: il Banco colpisce a raffica e da ora scendono in strada anche gli sponsor. Carletti in tasca e gambe in sella.');

insert into mazzobet.config (key, value, note) values
  ('banco_notte_da_h', 1, 'Banco fermo di notte (fasi con quiet_night): dalle ore, Europe/Rome'),
  ('banco_notte_a_h', 9, 'Banco fermo di notte: fino alle ore, Europe/Rome')
on conflict (key) do nothing;

alter table mazzobet.game_sessions add column bank_phase smallint;   -- fase con cui è stato armato bank_next_at

-- Fase in corso (null se non ci sono fasi o non è ancora iniziata la prima).
-- Da banco_inizio in poi vale sempre l'ultima fase (la serata): così «Avvia adesso» e l'orario della Regia
-- spostano anche il ritmo del Banco.
create function mazzobet.bank_phase_now() returns mazzobet.bank_phases
language sql stable set search_path = '' as $$
  select * from mazzobet.bank_phases
   where starts_at <= now() or now() >= to_timestamp(mazzobet.cfg('banco_inizio')::double precision)
   order by starts_at desc limit 1
$$;

-- Prossimo intervento: intervallo della fase in corso; nelle fasi «notturne» niente interventi tra le 01 e le 09.
create or replace function mazzobet.next_bank_at(p_session uuid) returns timestamptz
language plpgsql set search_path = '' as $$
declare
  v_p mazzobet.bank_phases := mazzobet.bank_phase_now();
  v_min double precision := coalesce(v_p.interval_min_sec, mazzobet.cfg('banco_intervallo_min_sec'));
  v_max double precision := coalesce(v_p.interval_max_sec, mazzobet.cfg('banco_intervallo_max_sec'));
  v_at timestamptz := now() + mazzobet.dur(p_session, v_min + floor(random() * (v_max - v_min + 1)));
  v_loc timestamp; v_da int := mazzobet.cfg('banco_notte_da_h'); v_a int := mazzobet.cfg('banco_notte_a_h');
begin
  if coalesce(v_p.quiet_night, false) then
    v_loc := v_at at time zone 'Europe/Rome';
    if extract(hour from v_loc) >= v_da and extract(hour from v_loc) < v_a then
      -- spostato alla mattina, entro mezz'ora dalla fine della notte
      v_at := (date_trunc('day', v_loc) + make_interval(hours => v_a)) at time zone 'Europe/Rome'
              + make_interval(secs => floor(random() * 1800));
    end if;
  end if;
  return v_at;
end $$;

-- Intervento del Banco: come nella 013, con gli importi della fase in corso.
create or replace function mazzobet.run_bank_event(p_session uuid) returns void
language plpgsql set search_path = '' as $$
declare
  v_p mazzobet.bank_phases := mazzobet.bank_phase_now();
  v_bonus boolean := random() * 100 < mazzobet.cfg('banco_probabilita_bonus');
  v_thr numeric := mazzobet.cfg('bancarotta_soglia');
  v_eligible smallint[]; v_pick smallint[]; v_n int; v_amount bigint; v_ev bigint; v_t smallint; v_names text[];
  v_dmin int := mazzobet.cfg('banco_destinatari_min'); v_dmax int := mazzobet.cfg('banco_destinatari_max');
  v_imin numeric := coalesce(v_p.amount_min, mazzobet.cfg('banco_importo_min'));
  v_imax numeric := coalesce(v_p.amount_max, mazzobet.cfg('banco_importo_max'));
  v_step numeric := mazzobet.cfg('banco_importo_passo');
begin
  if v_imax < v_imin then v_imax := v_imin; end if;
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
  values (p_session, case when v_bonus then 'bonus' else 'malus' end, v_pick, v_amount,
          jsonb_build_object('innesco', 'timer', 'fase', v_p.name))
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

-- Timer: come nella 018 (corsa compresa); cambia solo la parte Banco/sponsor (segnata «FASI»).
create or replace function public.mb_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_sess uuid; v_m record; v_gs record; v_n int;
  v_closed int := 0; v_void int := 0; v_bank int := 0; v_sponsor int := 0; v_final int := 0;
  v_prec double precision := mazzobet.cfg('precedenza_creatore_sec')::double precision;
  v_win double precision := mazzobet.cfg('finestra_esito_sec')::double precision;
  v_sp_start timestamptz := to_timestamp(mazzobet.cfg('banco_inizio')::double precision);   -- sponsor (e Banco senza fasi)
  v_p mazzobet.bank_phases := mazzobet.bank_phase_now();                                     -- FASI
  v_has_phases boolean := exists (select 1 from mazzobet.bank_phases);                       -- FASI
  v_bank_open boolean; v_sp_open boolean;
begin
  v_sp_open := now() >= v_sp_start;
  v_bank_open := case when v_has_phases then v_p.id is not null or v_sp_open else v_sp_open end;

  for v_sess in select id from mazzobet.game_sessions where status in ('active','paused','closing') loop
    perform pg_advisory_xact_lock(hashtextextended(v_sess::text, 0));

    for v_m in select m.id, exists (select 1 from mazzobet.bets b where b.market_id = m.id) as has_bets
                 from mazzobet.markets m
                where m.session_id = v_sess and m.status = 'open' and m.scheduled_close_at <= now()
                  and m.race_market_id is null                                   -- CORSA
                order by m.id loop
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
                where session_id = v_sess and status = 'closed' and resolve_by <= now()
                  and race_market_id is null                                     -- CORSA
                order by id loop
      perform mazzobet.void_market(v_m.id);
      v_void := v_void + 1;
    end loop;

    perform mazzobet.pay_fees(v_sess);

    select status, bank_next_at, sponsor_next_at, bank_paused, bank_open_announced, created_at, bank_phase into v_gs
      from mazzobet.game_sessions where id = v_sess;

    if v_gs.status = 'closing' then perform mazzobet.race_abort(v_sess);          -- CORSA
    else perform mazzobet.race_tick(v_sess);                                      -- CORSA
    end if;

    if not v_bank_open then
      if v_gs.bank_next_at is not null or v_gs.sponsor_next_at is not null then
        update mazzobet.game_sessions set bank_next_at = null, sponsor_next_at = null, bank_phase = null where id = v_sess;
        v_gs.bank_next_at := null; v_gs.sponsor_next_at := null;
      end if;
    elsif v_gs.status <> 'closing' then
      -- annunci: senza fasi quello di sempre all'apertura; con le fasi uno per fase (una volta per serata)
      if not v_has_phases then
        if not v_gs.bank_open_announced then
          update mazzobet.game_sessions set bank_open_announced = true where id = v_sess;
          if v_gs.created_at < v_sp_start then
            insert into mazzobet.news (session_id, kind, title, body, ref)
            select v_sess, 'bank', t.title, t.body, 'bank_open:' || v_sess
              from (values
                ('SI APRE IL BANCO', 'Il Banco è ufficialmente aperto. D''ora in poi bonus, malus e sponsor possono colpire senza preavviso: Carletti in tasca e gambe in sella.'),
                ('SEGNALE DI PARTENZA', 'La direzione di corsa dà il via al Banco: bonus, malus e sponsor sono in strada. Buona fortuna, gregari.'),
                ('ORA DI CENA, ORA DI BANCO', 'Il Banco prende servizio. Da qui a fine serata qualcuno riceverà, qualcuno pagherà e nessuno potrà dire di non essere stato avvisato.')
              ) as t(title, body) order by random() limit 1;
          end if;
        end if;
      elsif v_p.id is not null and v_p.news_title is not null                                -- FASI
            and not exists (select 1 from mazzobet.news where session_id = v_sess and ref = 'bank_phase:' || v_p.id || ':' || v_sess) then
        update mazzobet.game_sessions set bank_open_announced = true where id = v_sess;
        insert into mazzobet.news (session_id, kind, title, body, ref)
        values (v_sess, 'bank', v_p.news_title, v_p.news_body, 'bank_phase:' || v_p.id || ':' || v_sess);
      end if;

      select count(*) into v_n from mazzobet.session_teams where session_id = v_sess;
      if v_n >= mazzobet.cfg('banco_squadre_per_avvio') then
        -- Banco: armato alla prima occasione e riarmato quando cambia fase (es. alle 15:00 si imbizzarrisce subito)
        if v_gs.bank_next_at is null or v_gs.bank_phase is distinct from v_p.id then                   -- FASI
          update mazzobet.game_sessions set bank_next_at = mazzobet.next_bank_at(v_sess), bank_phase = v_p.id
           where id = v_sess returning bank_next_at into v_gs.bank_next_at;
        end if;
        -- Sponsor: solo da banco_inizio
        if v_sp_open and v_gs.sponsor_next_at is null then
          update mazzobet.game_sessions set sponsor_next_at = mazzobet.next_sponsor_at(v_sess)
           where id = v_sess returning sponsor_next_at into v_gs.sponsor_next_at;
        elsif not v_sp_open and v_gs.sponsor_next_at is not null then
          update mazzobet.game_sessions set sponsor_next_at = null where id = v_sess;
          v_gs.sponsor_next_at := null;
        end if;
      end if;

      if not v_gs.bank_paused then
        if v_gs.bank_next_at is not null and v_gs.bank_next_at <= now() then
          perform mazzobet.run_bank_event(v_sess);
          update mazzobet.game_sessions set bank_next_at = mazzobet.next_bank_at(v_sess), bank_phase = v_p.id where id = v_sess;
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
