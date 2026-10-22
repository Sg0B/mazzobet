-- Controllo di coerenza dei conti sull'ultima serata: tutte le righe devono dire "ok".
with s as (select id from mazzobet.game_sessions order by created_at desc limit 1)
select 'ledger a somma zero' as controllo,
       case when coalesce(sum(le.amount), 0) = 0 then 'ok' else 'ERRORE' end as esito
  from mazzobet.ledger_entries le, s where le.session_id = s.id
union all
select 'saldi squadre = somma del ledger',
       case when not exists (
         select 1 from mazzobet.session_teams st, s
          where st.session_id = s.id and st.balance <> (
            select coalesce(sum(amount), 0) from mazzobet.ledger_entries le
             where le.session_id = st.session_id and le.team_id = st.team_id)
       ) then 'ok' else 'ERRORE' end
union all
select 'nessuna bancarotta non processata',
       case when not exists (select 1 from mazzobet.bankruptcy_events b, s where b.session_id = s.id and b.chain_id is null)
            then 'ok' else 'ERRORE' end;
