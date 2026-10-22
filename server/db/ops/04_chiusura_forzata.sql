-- Emergenza: SOLO dopo 03_chiudi_serata.sql. Annulla e rimborsa subito tutti i mercati aperti o in attesa di esito
-- e congela la classifica senza aspettare le finestre di ricorso (gli esiti già pagati restano come sono).
select jsonb_pretty(mazzobet.admin_force_finalize());
