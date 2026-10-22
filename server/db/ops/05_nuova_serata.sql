-- Apre una nuova serata (la precedente deve essere chiusa). Le squadre rientrano con ₡1.000 e i timer del Banco
-- ripartono alla quinta squadra. Fine serata di default: prossime 03:00 Europe/Rome.
-- Per un orario diverso: select mazzobet.admin_new_session('Serata 2', '2026-11-05 02:30:00+01');
select jsonb_pretty(mazzobet.admin_new_session('Serata'));
