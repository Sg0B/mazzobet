-- Fasi del Banco (migration 027): vedere e cambiare ritmo e importi senza deploy.
-- Orari in ora italiana. Valori vuoti (null) = quelli della Regia (8–14', 100–250).

-- 1) Vedere le fasi e quella in corso
select id, name, starts_at at time zone 'Europe/Rome' as dalle,
       interval_min_sec / 60 as ogni_min_da, interval_max_sec / 60 as ogni_min_a,
       amount_min, amount_max, quiet_night as fermo_di_notte,
       id = (mazzobet.bank_phase_now()).id as in_corso
  from mazzobet.bank_phases order by starts_at;

-- 2) Esempi (togli il «--» davanti alla riga che vuoi usare)
-- update mazzobet.bank_phases set starts_at = timestamptz '2026-11-13 14:00:00+01' where name = 'imbizzarrito';
-- update mazzobet.bank_phases set interval_min_sec = 45*60, interval_max_sec = 90*60 where name = 'tranquillo';
-- update mazzobet.bank_phases set amount_min = 60, amount_max = 120 where name = 'tranquillo';
-- update mazzobet.config set value = 8 where key = 'banco_notte_a_h';   -- di notte fermo fino alle 08
-- Il nuovo ritmo vale dal prossimo intervento; per applicarlo subito:
-- update mazzobet.game_sessions set bank_phase = null where status = 'active';
