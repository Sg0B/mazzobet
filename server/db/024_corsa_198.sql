-- Corsa simulata, edizione a 198 minuti (03:18:00): la durata normale non è più 180 ma 198.
-- «corsa_durata_min» è il tempo reale scelto dalla Regia prima del via (da 5 a 198; 198 = tempo normale, velocità ×1).
-- Il valore 180 (vecchio «tempo normale», rimasto salvato) diventa 198; ogni altro valore scelto (es. 30 per le prove) resta com'è.

update mazzobet.config set value = 198, note = 'minuti: durata reale della corsa, 198 = tempo normale' where key = 'corsa_durata_min' and value = 180;
update mazzobet.config set note = 'minuti: durata reale della corsa, 198 = tempo normale' where key = 'corsa_durata_min';
insert into mazzobet.config (key, value, note) values ('corsa_durata_min', 198, 'minuti: durata reale della corsa, 198 = tempo normale')
on conflict (key) do nothing;

create or replace function public.mb_admin_race_set_duration(p_minutes int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_old numeric := mazzobet.cfg('corsa_durata_min');
begin
  if v is null then raise exception 'no_session'; end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 198 then raise exception 'bad_param'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  if exists (select 1 from mazzobet.race_runs where session_id = v and status <> 'not_started') then raise exception 'race_already_started'; end if;
  update mazzobet.config set value = p_minutes where key = 'corsa_durata_min';
  perform mazzobet.alog(v, 'corsa_durata', jsonb_build_object('prima', v_old, 'dopo', p_minutes));
  return public.mb_admin_state();
end $$;

revoke all on function public.mb_admin_race_set_duration(int) from public, anon, authenticated;
grant execute on function public.mb_admin_race_set_duration(int) to service_role;

-- Il carosello della Corsa mostra la categoria della scommessa (es. «GPM San Giacomo, km 22»): la aggiungo allo stato per i telefoni.
-- Solo il testo della categoria, che è già pubblico nella domanda; nessun esito.
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.mb_get_state(uuid)'::regprocedure);
  v_def := replace(v_def, $a$'raceId', m.race_market_id, 'awaiting', m.race_awaiting,$a$,
    $a$'raceId', m.race_market_id, 'awaiting', m.race_awaiting,
          'category', (select rm.category from mazzobet.race_markets rm join mazzobet.race_runs rr on rr.race_id = rm.race_id and rr.session_id = m.session_id where rm.id = m.race_market_id),$a$);
  if position('''category''' in v_def) = 0 then raise exception 'mb_get_state: modifica non applicata'; end if;
  execute v_def;
end $$;

revoke all on function public.mb_get_state(uuid) from public, anon, authenticated;
grant execute on function public.mb_get_state(uuid) to service_role;
