-- (b) Chiusura serata, tempo 1. Idempotente.
--  * Banco e sponsor si fermano; nessuna nuova puntata né creazione di scommesse.
--  * Esiti e ricorsi in corso si concludono normalmente (mercati senza esito: annullati e rimborsati dopo i 15 minuti,
--    i ₡100 di creazione non vengono restituiti).
--  * Quando non resta nulla di pendente il server congela da solo la classifica (entro pochi secondi) e la serata
--    passa a "closed": sola lettura. Controlla con 00_stato.sql.
select jsonb_pretty(mazzobet.admin_close_session());
