-- Classifiche: patrimonio, pronostici corretti, striscia vincente, somma puntate, bancarotte.
-- Applicata a giochi_ufficio il 25/10/2026 (migration mazzobet_012_classifiche).
-- Nessuna tabella nuova: tutto è calcolato da bets, markets, session_teams, bankruptcy_events.

insert into mazzobet.config (key, value, note) values
  ('min_esitate', 3, 'pronostici corretti: scommesse esitate minime per entrare in classifica'),
  ('striscia_quota_min', 130, 'centesimi (1,30): una vincita conta per la striscia solo da questa quota; 0 = nessun filtro'),
  ('striscia_puntata_min', 50, 'Carletti: una vincita conta per la striscia solo da questa puntata; 0 = nessun filtro')
on conflict (key) do nothing;

-- Tutte le classifiche insieme, per la serata attiva. I dati non dipendono dalla squadra che chiede:
-- il server può tenere la risposta in cache per qualche secondo e servirla a tutti.
create or replace function public.mb_get_rankings(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s uuid; v_t smallint; v_out jsonb;
  v_min   int := mazzobet.cfg('min_esitate')::int;
  v_qmin  int := mazzobet.cfg('striscia_quota_min')::int;
  v_pmin  bigint := mazzobet.cfg('striscia_puntata_min')::bigint;
begin
  select * into v_s, v_t from mazzobet.who_ro(p_token);

  with
  base as (
    select st.team_id, t.name, st.balance, st.bankruptcies
      from mazzobet.session_teams st join mazzobet.teams t on t.id = st.team_id
     where st.session_id = v_s),
  picks as (   -- annullate/rimborsate (result = 'void') e puntate ancora senza esito non contano come esitate
    select team_id,
           count(*) filter (where result = 'win') as won,
           count(*) filter (where result in ('win','loss')) as done,
           coalesce(sum(amount) filter (where result is distinct from 'void'), 0) as staked,
           coalesce(sum(amount) filter (where result is null), 0) as in_play
      from mazzobet.bets where session_id = v_s group by team_id),
  ev as (      -- esiti validi per la striscia, nell'ordine di esito; vale l'esito finale dopo un ricorso
    select b.team_id, (b.result = 'loss') as is_loss, m.resolved_at, m.id as mid
      from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id
     where b.session_id = v_s and b.result in ('win','loss')
       and (b.result = 'loss'
            or ((v_qmin = 0 or b.odds_cents >= v_qmin) and (v_pmin = 0 or b.amount >= v_pmin)))),
  seq as (
    select team_id, is_loss,
           sum(is_loss::int) over (partition by team_id order by resolved_at, mid rows unbounded preceding) as grp
      from ev),
  losses as (select team_id, count(*) filter (where is_loss) as l from seq group by team_id),
  runs as (select team_id, grp, count(*) as n from seq where not is_loss group by team_id, grp),
  streak as (
    select l.team_id,
           coalesce((select max(r.n) from runs r where r.team_id = l.team_id), 0) as best,
           coalesce((select r.n from runs r where r.team_id = l.team_id and r.grp = l.l), 0) as cur
      from losses l),   -- la serie in corso è l'ultima: quella dopo l'ultima sconfitta (grp = sconfitte totali)
  lastbk as (select team_id, max(at) as last_at from mazzobet.bankruptcy_events where session_id = v_s group by team_id),
  m as (
    select b.team_id, b.name, b.balance, b.bankruptcies, lb.last_at,
           coalesce(p.won, 0) as won, coalesce(p.done, 0) as done, coalesce(p.staked, 0) as staked,
           b.balance + coalesce(p.in_play, 0) as wealth,
           coalesce(s.best, 0) as best, coalesce(s.cur, 0) as cur
      from base b
      left join picks p using (team_id) left join streak s using (team_id) left join lastbk lb using (team_id))
  select jsonb_build_object(
    'minEsitate', v_min, 'stricciaQuotaMin', v_qmin, 'stricciaPuntataMin', v_pmin,
    'patrimonio', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'value', wealth, 'balance', balance) order by pos, name)
        from (select *, rank() over (order by wealth desc) as pos from m) x), '[]'::jsonb),
    'pronostici', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'won', won, 'done', done,
          'pct', case when done > 0 then round(100.0 * won / done) end) order by pos nulls last, name)
        from (select *, case when done >= v_min then rank() over (order by (done >= v_min) desc,
                                                              won::numeric / nullif(done, 0) desc nulls last, won desc) end as pos
                from m) x), '[]'::jsonb),
    'striscia', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'best', best, 'cur', cur) order by pos, name)
        from (select *, rank() over (order by best desc, cur desc) as pos from m) x), '[]'::jsonb),
    'puntate', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'value', staked) order by pos, name)
        from (select *, rank() over (order by staked desc) as pos from m) x), '[]'::jsonb),
    'bancarotte', coalesce((select jsonb_agg(jsonb_build_object(
          'teamId', team_id, 'name', name, 'pos', pos, 'value', bankruptcies) order by pos, name)
        from (select *, rank() over (order by bankruptcies desc, last_at desc nulls last) as pos
                from m where bankruptcies > 0) x), '[]'::jsonb)
  ) into v_out from (select 1) one;
  return v_out;
end $$;

revoke all on function public.mb_get_rankings(uuid) from public, anon, authenticated;
grant execute on function public.mb_get_rankings(uuid) to service_role;
