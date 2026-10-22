-- Stato della serata: fase, Banco in pausa o no, prossimi timer, mercati aperti/in attesa/in ricorso, cassa del Banco.
select jsonb_pretty(mazzobet.admin_status());
