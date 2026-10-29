-- Corsa simulata: la definizione (notizie, scommesse, orari) si può ricaricare quando nessuna corsa è in corso.
-- Prima il database rifiutava ogni ricarica dopo che UNA QUALSIASI corsa era partita, anche di una serata già chiusa o resettata:
-- così un orario corretto nel file (es. B01 che si apre al minuto 26) non poteva più entrare. Ora la ricarica è rifiutata
-- solo se una corsa è in corso o in pausa (stato «running» o «paused»); a corsa non partita, finita o interrotta si può ricaricare.

create or replace function public.mb_race_load(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id text := p->'race'->>'race_id'; v_ev int; v_mk int;
begin
  if v_id is null then raise exception 'bad_param'; end if;
  if exists (select 1 from mazzobet.race_runs where race_id = v_id and status in ('running','paused')) then
    return jsonb_build_object('skipped', true, 'reason', 'corsa in corso: la definizione non si cambia');
  end if;
  insert into mazzobet.race_defs (race_id, name, edition, distance_km, duration_seconds)
  values (v_id, p->'race'->>'name', (p->'race'->>'edition')::int, (p->'race'->>'distance_km')::numeric, (p->'race'->>'duration_seconds')::int)
  on conflict (race_id) do update set name = excluded.name, edition = excluded.edition,
    distance_km = excluded.distance_km, duration_seconds = excluded.duration_seconds, loaded_at = now();
  delete from mazzobet.race_events  where race_id = v_id;
  delete from mazzobet.race_markets where race_id = v_id;
  insert into mazzobet.race_events (race_id, id, seq, at_seconds, km, km_is_event_location, km_approximate, block, type, text, is_puncture)
  select v_id, e->>'id', (e->>'seq')::int, (e->>'at_seconds')::int, (e->>'km')::numeric,
         coalesce((e->>'km_is_event_location')::boolean, false), coalesce((e->>'km_approximate')::boolean, false),
         (e->>'block')::int, e->>'type', e->>'text', coalesce((e->>'is_puncture')::boolean, false)
    from jsonb_array_elements(p->'events') e;
  get diagnostics v_ev = row_count;
  insert into mazzobet.race_markets (race_id, id, seq, category, question, opens_at, closes_at, yes_odds, no_odds, winning, settlement)
  select v_id, m->>'id', (m->>'seq')::int, m->>'category', m->>'question', (m->>'opens_at')::int, (m->>'closes_at')::int,
         (m->>'yes_odds')::int, (m->>'no_odds')::int, m->>'winning', m->'settlement'
    from jsonb_array_elements(p->'markets') m;
  get diagnostics v_mk = row_count;
  return jsonb_build_object('skipped', false, 'events', v_ev, 'markets', v_mk);
end $$;

revoke all on function public.mb_race_load(jsonb) from public, anon, authenticated;
grant execute on function public.mb_race_load(jsonb) to service_role;
