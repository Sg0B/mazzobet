-- Corsa simulata: una corsa rimasta «in corso» in una serata già chiusa o resettata non deve più bloccare la ricarica della definizione.
-- Il reset totale chiude la serata senza fermare la corsa: la sua riga restava «running» e, dalla 021 in poi, impediva ogni ricarica
-- (per questo B01 restava al minuto 0 anche dopo la correzione del file). Ora:
--  1) le corse di serate già chiuse vengono segnate come interrotte (le puntate erano già state rimborsate alla chiusura);
--  2) la ricarica è rifiutata solo se la corsa in corso appartiene a una serata ancora aperta.

update mazzobet.race_runs r set status = 'aborted', paused_at = coalesce(r.paused_at, now())
 where r.status in ('running','paused')
   and exists (select 1 from mazzobet.game_sessions s where s.id = r.session_id and s.status = 'closed');

do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.mb_race_load(jsonb)'::regprocedure);
  v_def := replace(v_def,
    $a$if exists (select 1 from mazzobet.race_runs where race_id = v_id and status in ('running','paused')) then$a$,
    $a$if exists (select 1 from mazzobet.race_runs r join mazzobet.game_sessions s on s.id = r.session_id
                 where r.race_id = v_id and r.status in ('running','paused') and s.status <> 'closed') then$a$);
  if position('s.status <> ''closed''' in v_def) = 0 then raise exception 'mb_race_load: modifica non applicata'; end if;
  execute v_def;
end $$;

revoke all on function public.mb_race_load(jsonb) from public, anon, authenticated;
grant execute on function public.mb_race_load(jsonb) to service_role;
