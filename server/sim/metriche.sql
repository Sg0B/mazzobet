-- Metriche del PRD (§18) estratte dal database dopo una simulazione.
-- Prima di eseguire sostituisci nel CTE "p": l'id serata, il fattore di velocità usato e l'orario di fine simulazione
-- (campo endedAt del JSON in server/sim/out). Esegui da editor SQL come amministratore.
with p as (
  select '00000000-0000-0000-0000-000000000000'::uuid as sid,   -- id serata (select id from mazzobet.game_sessions order by created_at desc)
         6::numeric as scale,                                    -- stesso valore di game_sessions.time_scale
         now() as t_end                                          -- fine simulazione (endedAt)
),
led as (   -- ledger delle squadre con saldo prima/dopo ogni movimento
  select le.id, le.team_id, lt.kind, le.amount, le.created_at,
         coalesce(sum(le.amount) over (partition by le.team_id order by le.id
                  rows between unbounded preceding and 1 preceding), 0) as before
    from mazzobet.ledger_entries le
    join mazzobet.ledger_transactions lt on lt.id = le.transaction_id, p
   where le.session_id = p.sid and le.team_id is not null
),
bank_start as (
  select (select entered_at from mazzobet.session_teams where session_id = p.sid order by entered_at offset 4 limit 1) as t from p
),
hours as (   -- ore di serata con il Banco attivo
  select extract(epoch from (p.t_end - b.t)) * p.scale / 3600 as h from p, bank_start b
),
banco as (
  select jsonb_build_object(
    'ore_serata_con_banco', round((select h from hours)::numeric, 2),
    'interventi_totali', count(*),
    'bonus', count(*) filter (where kind = 'bonus'),
    'malus', count(*) filter (where kind = 'malus'),
    'interventi_per_ora', round((count(*) / nullif((select h from hours), 0))::numeric, 2),
    'destinatari_medi', round(avg(cardinality(teams)), 2),
    'importo_medio', round(avg(amount), 0),
    'squadre_mai_colpite', (select count(*) from mazzobet.session_teams st, p
        where st.session_id = p.sid and not exists (select 1 from led where led.team_id = st.team_id and led.kind in ('bonus','malus'))),
    'colpi_per_squadra_min_max', (select jsonb_build_array(min(n), max(n)) from (
        select st.team_id, count(*) filter (where led.kind in ('bonus','malus')) n
          from mazzobet.session_teams st left join led on led.team_id = st.team_id, p
         where st.session_id = p.sid group by st.team_id) x),
    'bancarotte_per_ultima_causa', (select coalesce(jsonb_object_agg(cause, n), '{}') from (
        select coalesce(cause, '?') cause, count(*) n from (
          select (select l.kind from led l where l.team_id = be.team_id and l.created_at <= be.at order by l.id desc limit 1) as cause
            from mazzobet.bankruptcy_events be, p where be.session_id = p.sid) y group by 1) z)
  ) j
  from mazzobet.bank_events e, p where e.session_id = p.sid and e.kind in ('bonus','malus')
),
colletta as (
  select jsonb_build_object(
    'catene', count(*),
    'giri_medi', round(avg(rounds), 2), 'giri_max', max(rounds),
    'istogramma_giri', (select coalesce(jsonb_object_agg(rounds, n), '{}') from (select rounds, count(*) n from mazzobet.collection_chains c2, p where c2.session_id = p.sid group by rounds) h),
    'caduti_per_catena_medi', round(avg(fallen), 2), 'caduti_per_catena_max', max(fallen),
    'paganti_medi_per_giro', (select round(avg(r.payers), 1) from mazzobet.collection_rounds r join mazzobet.collection_chains c3 on c3.id = r.chain_id, p where c3.session_id = p.sid),
    'carletti_sottratti', (select coalesce(sum(-amount), 0) from led where kind = 'colletta'),
    'bancarotte_totali', (select count(*) from mazzobet.bankruptcy_events b, p where b.session_id = p.sid),
    'riammissioni_totali', (select coalesce(sum(readmissions), 0) from mazzobet.session_teams st, p where st.session_id = p.sid)
  ) j
  from (select c.id, c.rounds, (select count(*) from mazzobet.bankruptcy_events b where b.chain_id = c.id) as fallen
          from mazzobet.collection_chains c, p where c.session_id = p.sid) cc
),
sponsor as (
  select jsonb_build_object(
    'eventi', (select count(*) from mazzobet.bank_events e, p where e.session_id = p.sid and e.kind = 'sponsor'),
    'per_ora_di_serata', (select round((count(*) / nullif((select h from hours), 0))::numeric, 2) from mazzobet.bank_events e, p where e.session_id = p.sid and e.kind = 'sponsor'),
    'formula_corretta_su_tutti', (select coalesce(bool_and(amount = 2000 + 150 * (detail->>'teams')::int + greatest(0, -(detail->>'cashBefore')::bigint)), true)
                                    from mazzobet.bank_events e, p where e.session_id = p.sid and e.kind = 'sponsor'),
    'dettaglio', (select coalesce(jsonb_agg(jsonb_build_object('contributo', amount, 'N', detail->>'teams', 'cassa_prima', detail->>'cashBefore') order by id), '[]')
                    from mazzobet.bank_events e, p where e.session_id = p.sid and e.kind = 'sponsor'),
    'pioggia_accrediti', (select count(*) from led where kind = 'sponsor_rain'),
    'pioggia_a_squadre_in_bancarotta', (select count(*) from led where kind = 'sponsor_rain' and before < 10),
    'uscite_da_bancarotta_grazie_alla_pioggia', (select count(*) from led where kind = 'sponsor_rain' and before < 10 and before + amount >= 10),
    'cassa_banco', (select jsonb_build_object('min', min(c), 'max', max(c), 'finale', (array_agg(c order by id desc))[1])
                      from (select id, sum(amount) over (order by id) c from mazzobet.ledger_entries le, p where le.session_id = p.sid and le.account = 'bank') s)
  ) j
),
esiti as (
  select jsonb_build_object(
    'mercati_creati', count(*),
    'per_stato', (select jsonb_object_agg(status, n) from (select status, count(*) n from mazzobet.markets m2, p where m2.session_id = p.sid group by status) s),
    'esitati_dal_creatore', count(*) filter (where status = 'resolved' and resolved_by_team_id = creator_team_id),
    'esitati_da_terzi', count(*) filter (where status = 'resolved' and resolved_by_team_id <> creator_team_id),
    'annullati_per_mancato_esito', count(*) filter (where status = 'void'),
    'tempo_all_esito_sec_serata', jsonb_build_object(
        'medio', round((avg(extract(epoch from resolved_at - actual_closed_at)) filter (where status = 'resolved') * (select scale from p))::numeric, 0),
        'p50', round((percentile_cont(0.5) within group (order by extract(epoch from resolved_at - actual_closed_at)) filter (where status = 'resolved') * (select scale from p))::numeric, 0),
        'p95', round((percentile_cont(0.95) within group (order by extract(epoch from resolved_at - actual_closed_at)) filter (where status = 'resolved') * (select scale from p))::numeric, 0)),
    'ricorsi_totali', (select count(*) from mazzobet.appeals a, p where a.session_id = p.sid),
    'mercati_con_ricorso', (select count(distinct market_id) from mazzobet.appeals a, p where a.session_id = p.sid),
    'verdetti_ribaltati', count(*) filter (where flipped),
    'senza_puntate', count(*) filter (where status = 'empty'),
    'compensi_pagati', (select count(*) from mazzobet.ledger_transactions lt, p where lt.session_id = p.sid and lt.kind = 'esito_compenso'),
    'totale_compensi_carletti', (select coalesce(sum(le.amount), 0) from mazzobet.ledger_entries le
         join mazzobet.ledger_transactions lt on lt.id = le.transaction_id, p
        where lt.session_id = p.sid and lt.kind = 'esito_compenso' and le.team_id is not null),
    'da_esitare_contemporanei_max', (select coalesce(max(c), 0) from (
        select sum(d) over (order by t, d) c from (
          select actual_closed_at t, 1 d from mazzobet.markets m3, p where m3.session_id = p.sid and actual_closed_at is not null
          union all
          select resolved_at, -1 from mazzobet.markets m4, p where m4.session_id = p.sid and actual_closed_at is not null and resolved_at is not null) ev) s),
    'puntate_totali', (select count(*) from mazzobet.bets b, p where b.session_id = p.sid),
    'puntata_media', (select round(avg(amount), 0) from mazzobet.bets b, p where b.session_id = p.sid),
    'puntate_per_mercato_medie', (select round(count(*)::numeric / nullif(count(distinct market_id), 0), 2) from mazzobet.bets b, p where b.session_id = p.sid)
  ) j
  from mazzobet.markets m, p where m.session_id = p.sid
),
classifica as (
  select jsonb_build_object(
    'squadre_entrate', count(*),
    'saldo_min', min(balance), 'saldo_mediano', percentile_cont(0.5) within group (order by balance), 'saldo_max', max(balance),
    'saldi_negativi', count(*) filter (where balance < 0),
    'in_bancarotta_a_fine_run', count(*) filter (where status = 'bankrupt'),
    'quota_patrimonio_prime_3', round((select sum(b) from (select balance b from mazzobet.session_teams s2, p where s2.session_id = p.sid order by balance desc limit 3) t)::numeric
                                    / nullif(sum(greatest(balance, 0)), 0), 3),
    'pronostici_corretti_min_max', jsonb_build_array(min(correct_picks), max(correct_picks)),
    'top5', (select jsonb_agg(jsonb_build_object('squadra', t.name, 'saldo', s3.balance, 'pronostici', s3.correct_picks) order by s3.balance desc)
               from (select * from mazzobet.session_teams s4, p where s4.session_id = p.sid order by balance desc limit 5) s3 join mazzobet.teams t on t.id = s3.team_id),
    'bottom5', (select jsonb_agg(jsonb_build_object('squadra', t.name, 'saldo', s5.balance, 'stato', s5.status) order by s5.balance)
               from (select * from mazzobet.session_teams s6, p where s6.session_id = p.sid order by balance limit 5) s5 join mazzobet.teams t on t.id = s5.team_id)
  ) j
  from mazzobet.session_teams st, p where st.session_id = p.sid
),
conti as (
  select jsonb_build_object(
    'ledger_somma_zero', (select coalesce(sum(amount), 0) = 0 from mazzobet.ledger_entries le, p where le.session_id = p.sid),
    'saldi_uguali_al_ledger', not exists (select 1 from mazzobet.session_teams st, p where st.session_id = p.sid and st.balance <>
        (select coalesce(sum(amount), 0) from mazzobet.ledger_entries le where le.session_id = st.session_id and le.team_id = st.team_id)),
    'movimenti_per_tipo', (select jsonb_object_agg(kind, n) from (select lt.kind, count(*) n from mazzobet.ledger_transactions lt, p where lt.session_id = p.sid group by lt.kind) s),
    'bancarotte_non_processate', (select count(*) from mazzobet.bankruptcy_events b, p where b.session_id = p.sid and b.chain_id is null)
  ) j
)
select jsonb_pretty(jsonb_build_object(
  'banco_ordinario', (select j from banco),
  'colletta', (select j from colletta),
  'sponsor', (select j from sponsor),
  'esiti', (select j from esiti),
  'classifica', (select j from classifica),
  'conti', (select j from conti)));
