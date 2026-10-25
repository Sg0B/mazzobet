// Prova delle migration su un Postgres in memoria (PGlite): non tocca nessun database vero.
// Uso (dalla radice del progetto):  npm i --no-save @electric-sql/pglite  poi  node server/tests/pglite/regia.mjs
import { boot } from './load.mjs'
const db = await boot(12)
let ok = 0, ko = 0
const t = (name, cond, extra = '') => { if (cond) { ok++; console.log('  ok  ', name) } else { ko++; console.log('  FAIL', name, extra) } }
const q = async (sql, p) => (await db.query(sql, p)).rows
const one = async (sql, p) => (await q(sql, p))[0]
const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await one(`select public.${fn}(${ph}) as r`, args)).r }
const fails = async (fn, args, msg) => { try { await rpc(fn, args); return false } catch (e) { return e.message.includes(msg) } }
const tick = () => rpc('mb_tick')
const ACT = `(select id from mazzobet.game_sessions where status='active')`
await q(`select mazzobet.admin_new_session('Test')`)
const tok = {}
for (let i = 1; i <= 6; i++) tok[i] = (await rpc('mb_enter_team', [i, null, 'ua'])).token

console.log('# Banco prima di banco_inizio')
await tick()
let s = await one(`select bank_next_at, sponsor_next_at, bank_open_announced from mazzobet.game_sessions where status='active'`)
t('timer non armati con 6 squadre prima di banco_inizio', s.bank_next_at === null && s.sponsor_next_at === null)
t('nessun annuncio prima', (await one(`select count(*)::int n from mazzobet.news where ref like 'bank_open:%'`)).n === 0)

console.log('# Avvia Banco adesso')
let st = await rpc('mb_admin_bank_now')
await tick()
s = await one(`select bank_next_at, sponsor_next_at, bank_open_announced from mazzobet.game_sessions where status='active'`)
t('timer armati dopo Avvia Banco adesso', s.bank_next_at !== null && s.sponsor_next_at !== null)
t('annuncio RadioCorsa una volta', (await one(`select count(*)::int n from mazzobet.news where ref like 'bank_open:%'`)).n === 1)
await tick(); await tick()
t('annuncio non ripetuto', (await one(`select count(*)::int n from mazzobet.news where ref like 'bank_open:%'`)).n === 1)
t('azione nel log', (await one(`select count(*)::int n from mazzobet.admin_log where action='banco_adesso'`)).n === 1)
console.log('# banco_inizio nel futuro ferma il Banco')
await rpc('mb_admin_set_bank_start', ['2099-01-01T00:00:00Z']); await tick()
s = await one(`select bank_next_at from mazzobet.game_sessions where status='active'`)
t('timer disarmati se banco_inizio è futuro', s.bank_next_at === null)
await rpc('mb_admin_bank_now'); await tick()

console.log('# finestra_esito_min calcolata sul valore corrente')
const mk = async (team, key) => rpc('mb_create_market', [tok[team], 'Domanda di prova numero ' + key, 200, 200, new Date(Date.now() + 120000).toISOString(), 'key-' + key + '-abcdef'])
await mk(1, 'a'); await mk(1, 'b')
const ids = (await q(`select id from mazzobet.markets order by id`)).map((r) => r.id)
for (const id of ids) { await rpc('mb_place_bet', [tok[2], id, 'yes', 100]); await rpc('mb_place_bet', [tok[3], id, 'no', 50]) }
const expire = async (id, min) => q(`update mazzobet.markets set scheduled_close_at = now() - ($2 || ' minutes')::interval where id=$1`, [id, String(min)])
await expire(ids[0], 20); await expire(ids[1], 20)
await rpc('mb_admin_set_param', ['finestra_esito_min', 60]); await tick()
let m = await one(`select status from mazzobet.markets where id=$1`, [ids[0]])
t('con finestra 60 la scommessa scaduta da 20 min NON è annullata', m.status === 'closed', m.status)
await rpc('mb_admin_set_param', ['finestra_esito_min', 17]); await tick()
m = await one(`select status from mazzobet.markets where id=$1`, [ids[1]])
t('riportata a 17: scaduta da 20 min viene annullata', m.status === 'void', m.status)
t('parametro non valido rifiutato', await fails('mb_admin_set_param', ['finestra_esito_min', 1], 'bad_param'))
t('chiave sconosciuta rifiutata', await fails('mb_admin_set_param', ['costo_creazione', 5], 'bad_param'))

console.log('# Esito dalla Regia')
await mk(1, 'c'); const m3 = (await one(`select max(id) id from mazzobet.markets`)).id
await rpc('mb_place_bet', [tok[2], m3, 'yes', 100]); await rpc('mb_place_bet', [tok[3], m3, 'no', 50])
const bal = async (i) => Number((await one(`select balance b from mazzobet.session_teams where team_id=$1 and session_id=${ACT}`, [i])).b)
const b1 = await bal(1), b2 = await bal(2), b3 = await bal(3)
await rpc('mb_admin_resolve', [m3, 'yes'])
t('vincitore pagato subito (100 a 2,00 = +200)', (await bal(2)) === b2 + 200)
t('perdente non paga altro', (await bal(3)) === b3)
t('creatore compensato subito: C = 10% di 150 = 15', (await bal(1)) === b1 + 15, `${await bal(1)} vs ${b1}`)
m = await one(`select status, resolved_by_admin, resolved_by_team_id from mazzobet.markets where id=$1`, [m3])
t('segnata come esitata dalla Regia, nessuna squadra esitatrice', m.status === 'resolved' && m.resolved_by_admin === true && m.resolved_by_team_id === null)
t('contestazione impossibile', await fails('mb_appeal', [tok[3], m3], 'appeal_window_closed'))
t('già esitata: secondo esito rifiutato', await fails('mb_admin_resolve', [m3, 'no'], 'already_resolved'))
const stt = await rpc('mb_get_state', [tok[2]])
t('mb_get_state espone byAdmin', stt.markets.find((x) => x.id === m3)?.byAdmin === true)
const sumNoMint = Number((await one(`select coalesce(sum(amount),0) s from mazzobet.ledger_entries where session_id=${ACT} and account<>'mint'`)).s)
const sumMint = Number((await one(`select coalesce(sum(amount),0) s from mazzobet.ledger_entries where session_id=${ACT} and account='mint'`)).s)
t('ledger bilanciato (somma voci = 0)', sumNoMint + sumMint === 0, `${sumNoMint} ${sumMint}`)

console.log('# Esito dalla Regia su scommessa ancora aperta')
await mk(4, 'd'); const m4 = (await one(`select max(id) id from mazzobet.markets`)).id
await rpc('mb_place_bet', [tok[5], m4, 'no', 200])
await rpc('mb_admin_resolve', [m4, 'no'])
t('puntata pagata (200 a 2,00 = 400)', Number((await one(`select payout p from mazzobet.bets where market_id=$1`, [m4])).p) === 400)

console.log('# Annulla con rimborso')
await mk(4, 'e'); const m5 = (await one(`select max(id) id from mazzobet.markets`)).id
await rpc('mb_place_bet', [tok[5], m5, 'yes', 100]); const b5 = await bal(5)
await rpc('mb_admin_void', [m5])
t('rimborso della puntata', (await bal(5)) === b5 + 100)
t('annullare una già esitata rifiutato', await fails('mb_admin_void', [m3], 'not_voidable'))

console.log('# Rettifica saldo')
const b6 = await bal(6)
await rpc('mb_admin_adjust', [6, 250, 'Errore di prova'])
t('+250 accreditati', (await bal(6)) === b6 + 250)
await rpc('mb_admin_adjust', [6, -100, 'Penale'])
t('-100 addebitati', (await bal(6)) === b6 + 150)
t('motivo obbligatorio', await fails('mb_admin_adjust', [6, 10, ' '], 'reason_required'))
t('non porta il saldo sotto zero', await fails('mb_admin_adjust', [6, -999999, 'troppo'], 'insufficient_funds'))
t('rettifica con motivo nel log', (await one(`select detail->>'motivo' m from mazzobet.admin_log where action='rettifica_saldo' order by id limit 1`)).m === 'Errore di prova')

console.log('# Reset squadra')
const dev = await one(`select count(*)::int n from mazzobet.team_devices where team_id=2`)
const before = await bal(2); const betsBefore = (await one(`select count(*)::int n from mazzobet.bets where team_id=2`)).n
await rpc('mb_admin_reset_team', [2])
t('dispositivi cancellati', (await one(`select count(*)::int n from mazzobet.team_devices where team_id=2`)).n === 0 && dev.n >= 1)
t('saldo e storico invariati', (await bal(2)) === before && (await one(`select count(*)::int n from mazzobet.bets where team_id=2`)).n === betsBefore)
t('il vecchio token non vale più', await fails('mb_get_state', [tok[2]], 'unauthorized'))
const re = await rpc('mb_enter_team', [2, null, 'ua'])
t('la squadra può rientrare, stesso saldo', re.firstEntry === false && (await bal(2)) === before)

console.log('# Stato Regia')
st = await rpc('mb_admin_state')
t('stato: 24 squadre, parametri, log', st.teams.length === 24 && Number(st.params.finestra_esito_min) === 17 && st.log.length > 5, JSON.stringify(st.params))

console.log('# Reset totale')
t('senza RESET non fa nulla', await fails('mb_admin_reset_all', ['reset'], 'confirm_required'))
t('serata ancora la stessa', (await one(`select count(*)::int n from mazzobet.game_sessions where status='active'`)).n === 1)
const oldS = (await one(`select id from mazzobet.game_sessions where status='active'`)).id
await mk(4, 'f'); const m6 = (await one(`select max(id) id from mazzobet.markets`)).id
await rpc('mb_place_bet', [tok[5], m6, 'yes', 100])
await rpc('mb_admin_bank_now')
await rpc('mb_admin_reset_all', ['RESET'])
t('reset: apertura del Banco riportata al 13/11 20:00', Number((await one(`select value v from mazzobet.config where key='banco_inzio'`.replace('inzio','inizio'))).v) === 1794596400, '')
const ns = await one(`select id from mazzobet.game_sessions where status='active'`)
t('nuova serata attiva, diversa dalla vecchia', ns && ns.id !== oldS)
t('vecchia serata chiusa', (await one(`select status from mazzobet.game_sessions where id=$1`, [oldS])).status === 'closed')
t('nuova serata senza squadre entrate', (await one(`select count(*)::int n from mazzobet.session_teams where session_id=$1`, [ns.id])).n === 0)
t('scommessa in corso rimborsata alla chiusura', (await one(`select result from mazzobet.bets where market_id=$1`, [m6])).result === 'void')
let oldTokErr = ''
try { await rpc('mb_get_state', [tok[1]]) } catch (e) { oldTokErr = e.message }
t('vecchio token: torna alla scelta squadra (unauthorized)', oldTokErr === 'unauthorized', oldTokErr)
const tn = await rpc('mb_enter_team', [1, null, 'ua'])
t('rientro: saldo iniziale 1000', Number((await one(`select balance b from mazzobet.session_teams where session_id=$1 and team_id=1`, [ns.id])).b) === 1000 && tn.firstEntry === true)
t('reset nel log', (await one(`select count(*)::int n from mazzobet.admin_log where action='reset_totale'`)).n === 1)
await rpc('mb_admin_set_param', ['saldo_iniziale', 1500]); await rpc('mb_enter_team', [3, null, 'ua'])
t('cambio saldo_iniziale: nuovi a 1500, già entrati restano', Number((await one(`select balance b from mazzobet.session_teams where session_id=$1 and team_id=3`, [ns.id])).b) === 1500 && Number((await one(`select balance b from mazzobet.session_teams where session_id=$1 and team_id=1`, [ns.id])).b) === 1000)

console.log('# Permessi')
const priv = await one(`select has_function_privilege('anon','public.mb_admin_reset_all(text,boolean)','execute') a, has_function_privilege('authenticated','public.mb_admin_adjust(smallint,bigint,text)','execute') b, has_function_privilege('service_role','public.mb_admin_state()','execute') c`)
t('anon/authenticated non possono chiamare le funzioni Regia', !priv.a && !priv.b && priv.c)
console.log(`\n${ok} ok, ${ko} falliti`)
