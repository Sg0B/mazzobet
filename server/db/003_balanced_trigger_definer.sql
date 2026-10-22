-- Il trigger di bilanciamento è deferred: scatta al commit con il ruolo della connessione
-- (service_role), che non ha accesso allo schema mazzobet. Va eseguito con i diritti del proprietario.
create or replace function mazzobet.check_tx_balanced() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select coalesce(sum(amount), 0) from mazzobet.ledger_entries where transaction_id = new.transaction_id) <> 0 then
    raise exception 'ledger_unbalanced';
  end if;
  return null;
end $$;
