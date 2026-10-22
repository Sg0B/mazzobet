-- Classifica finale congelata dell'ultima serata chiusa.
select f.rank_wealth as pos_patrimonio, t.name as squadra, f.balance as carletti,
       f.correct_picks as pronostici, f.rank_picks as pos_pronostici, f.bankruptcies as bancarotte, f.readmissions as riammissioni
  from mazzobet.final_standings f
  join mazzobet.teams t on t.id = f.team_id
 where f.session_id = (select id from mazzobet.game_sessions where status = 'closed' order by closed_at desc limit 1)
 order by f.rank_wealth, f.rank_picks;
