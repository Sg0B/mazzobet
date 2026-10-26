-- PIN delle squadre: ogni squadra ha un PIN di 4 cifre scelto da chi entra per primo.
-- Il PIN è salvato solo come hash scrypt con sale (calcolato dal server Node, mai dal database né dal browser).
-- Dopo 5 errori consecutivi la squadra è bloccata per 1 minuto. Il blocco è per squadra (a cena il wifi è uno solo).
-- Il dispositivo già riconosciuto (token) non chiede il PIN; «Resetta squadra» cancella PIN e dispositivi.
-- Applicata a giochi_ufficio il 26/10/2026 (migration mazzobet_015_pin).

create table mazzobet.team_pins (
  session_id    uuid not null,
  team_id       smallint not null,
  pin_hash      text not null,
  pin_salt      text not null,
  fails         int not null default 0,
  blocked_until timestamptz,
  created_at    timestamptz not null default now(),
  primary key (session_id, team_id)
);
alter table mazzobet.team_pins enable row level security;

-- Elenco squadre: aggiunge hasPin (serve a scegliere «imposta PIN» o «inserisci PIN») e lockedSecs (blocco in corso).
create or replace function public.mb_list_teams() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'name', t.name,
           'entered', st.team_id is not null,
           'hasPin', p.team_id is not null,
           'lockedSecs', coalesce(greatest(ceil(extract(epoch from p.blocked_until - now())), 0), 0)::int
         ) order by t.id), '[]'::jsonb)
    from mazzobet.teams t
    left join mazzobet.session_teams st
      on st.team_id = t.id and st.session_id = mazzobet.active_session()
    left join mazzobet.team_pins p
      on p.team_id = t.id and p.session_id = mazzobet.active_session()
$$;

-- Stato di accesso di una squadra, per il server: known = il token è già un dispositivo di questa squadra.
-- Restituisce anche hash e sale perché il confronto avviene nel server (solo service_role può chiamarla).
create function public.mb_pin_status(p_team smallint, p_token uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); p mazzobet.team_pins;
begin
  if v is null then raise exception 'no_session'; end if;
  if not exists (select 1 from mazzobet.teams where id = p_team) then raise exception 'unknown_team'; end if;
  select * into p from mazzobet.team_pins where session_id = v and team_id = p_team;
  return jsonb_build_object(
    'known', p_token is not null and exists (select 1 from mazzobet.team_devices
                                              where token = p_token and session_id = v and team_id = p_team),
    'hasPin', p.team_id is not null,
    'hash', p.pin_hash, 'salt', p.pin_salt,
    'lockedSecs', coalesce(greatest(ceil(extract(epoch from p.blocked_until - now())), 0), 0)::int);
end $$;

-- Imposta il PIN se la squadra non ne ha ancora uno. Ritorna false se qualcuno l'ha impostato un attimo prima.
create function public.mb_pin_set(p_team smallint, p_hash text, p_salt text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_n int;
begin
  if v is null then raise exception 'no_session'; end if;
  if not exists (select 1 from mazzobet.teams where id = p_team) then raise exception 'unknown_team'; end if;
  insert into mazzobet.team_pins (session_id, team_id, pin_hash, pin_salt) values (v, p_team, p_hash, p_salt)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- PIN giusto: azzera gli errori.
create function public.mb_pin_ok(p_team smallint) returns void
language sql security definer set search_path = '' as $$
  update mazzobet.team_pins set fails = 0, blocked_until = null
   where session_id = mazzobet.active_session() and team_id = p_team
$$;

-- PIN sbagliato: conta l'errore; al quinto di fila blocca la squadra per 1 minuto.
create function public.mb_pin_fail(p_team smallint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); p mazzobet.team_pins;
begin
  if v is null then raise exception 'no_session'; end if;
  update mazzobet.team_pins set fails = fails + 1
   where session_id = v and team_id = p_team returning * into p;
  if p.team_id is null then return jsonb_build_object('left', 0, 'lockedSecs', 0); end if;
  if p.fails >= 5 then
    update mazzobet.team_pins set fails = 0, blocked_until = now() + interval '1 minute'
     where session_id = v and team_id = p_team;
    perform mazzobet.alog(v, 'pin_bloccato', '{}'::jsonb, null, p_team);
    return jsonb_build_object('left', 0, 'lockedSecs', 60);
  end if;
  return jsonb_build_object('left', 5 - p.fails, 'lockedSecs', 0);
end $$;

-- «Resetta squadra»: scollega i dispositivi, cancella il PIN e la rende libera. Saldo e storico NON si toccano.
create or replace function public.mb_admin_reset_team(p_team smallint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := mazzobet.active_session(); v_n int; v_pin int;
begin
  if v is null then raise exception 'no_session'; end if;
  if not exists (select 1 from mazzobet.teams where id = p_team) then raise exception 'unknown_team'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v::text, 0));
  delete from mazzobet.team_devices where session_id = v and team_id = p_team;
  get diagnostics v_n = row_count;
  delete from mazzobet.team_pins where session_id = v and team_id = p_team;
  get diagnostics v_pin = row_count;
  perform mazzobet.alog(v, 'reset_squadra', jsonb_build_object('dispositivi', v_n, 'pin', v_pin > 0), null, p_team);
  return jsonb_build_object('devices', v_n);
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
