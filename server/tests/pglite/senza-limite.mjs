// Migration 026: nessun tetto alle 03:00 sulle scadenze delle scommesse.
// Uso (dalla radice del progetto):  node server/tests/pglite/senza-limite.mjs
import { boot } from './load.mjs'
const db = await boot(99)
let ok = 0, ko = 0
const t = (name, cond, extra = '') => { if (cond) { ok++; console.log('  ok  ', name) } else { ko++; console.log('  FAIL', name, extra) } }
const q = async (sql, p) => (await db.query(sql, p)).rows
const one = async (sql, p) => (await q(sql, p))[0]
const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await one(`select public.${fn}(${ph}) as r`, args)).r }
const fails = async (fn, args, msg) => { try { await rpc(fn, args); return false } catch (e) { return e.message.includes(msg) } }

await q(`select mazzobet.admin_new_session('Test')`)
// la «fine serata» è già passata (come dopo le 03:00)
await q(`update mazzobet.game_sessions set ends_at = now() - interval '1 hour' where status='active'`)
const tok = (await rpc('mb_enter_team', [1, null, 'ua'])).token
const at = (ms) => new Date(Date.now() + ms).toISOString()

console.log('# dopo la fine serata si crea ancora')
const a = await rpc('mb_create_market', [tok, 'Domanda creata dopo le tre', 200, 200, at(30 * 60_000), 'key-a-abcdef'])
t('scommessa da 30 minuti creata dopo ends_at', a.marketId && !a.replay)

console.log('# scadenza fra qualche giorno')
const b = await rpc('mb_create_market', [tok, 'Venerdì alle 18 piove a Teramo?', 200, 200, at(4 * 86_400_000), 'key-b-abcdef'])
const m = await one(`select scheduled_close_at, status from mazzobet.markets where id=$1`, [b.marketId])
t('scommessa a 4 giorni creata e aperta', m.status === 'open' && Date.parse(m.scheduled_close_at) > Date.now() + 3.9 * 86_400_000)
await rpc('mb_tick')
t('il timer non la chiude prima del tempo', (await one(`select status from mazzobet.markets where id=$1`, [b.marketId])).status === 'open')
const tok2 = (await rpc('mb_enter_team', [2, null, 'ua'])).token
await rpc('mb_place_bet', [tok2, b.marketId, 'yes', 100])
t('si può puntare sulla scommessa lunga', (await one(`select count(*)::int n from mazzobet.bets where market_id=$1`, [b.marketId])).n === 1)

console.log('# i controlli rimasti funzionano')
t('scadenza troppo vicina ancora rifiutata', await fails('mb_create_market', [tok, 'Domanda troppo vicina ok', 200, 200, at(5_000), 'key-c-abcdef'], 'expiry_too_soon'))
await q(`update mazzobet.game_sessions set status='closed' where status='active'`)
t('serata chiusa: niente creazione', await fails('mb_create_market', [tok, 'Domanda a serata chiusa', 200, 200, at(3_600_000), 'key-d-abcdef'], 'session_closed'))

console.log(`\n${ok} ok, ${ko} falliti`)
process.exit(ko ? 1 : 0)
