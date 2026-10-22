-- L'API Supabase (pg_safeupdate) rifiuta DELETE senza WHERE, anche dentro una funzione.
create or replace function public.mb_load_catalog(p jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  delete from mazzobet.catalog_entries where true;
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
revoke all on function public.mb_load_catalog(jsonb) from public, anon, authenticated;
grant execute on function public.mb_load_catalog(jsonb) to service_role;
