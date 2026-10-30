// Simulazione completa di una serata con La Teramana: 24 squadre che puntano a caso su tutte le 10 scommesse, 180 minuti di gara
// attraversati a passi di 10 secondi (il tempo si sposta riscrivendo la partenza: nessuna attesa). Poi controlli di coerenza e conto economico del Banco.
// Uso (dalla radice):  node server/tests/pglite/corsa-simulazione.mjs
import { boot } from './load.mjs'
import { buildRace, readRace } from '../../src/race.ts'
import { fileURLToPath } from 'node:url'

let ok = 0, ko = 0
const t = (name, cond, extra = '') => { if (cond) { ok++; console.log('  ok  ', name) } else { ko++; console.log('  FAIL', name, extra) } }
const ACT = `(select id from mazzobet.game_sessions where status='active')`
const { timeline, banco } = readRace(fileURLToPath(new URL('../../data/', import.meta.url)))
const payload = buildRace(timeline, banco).payload
const winning = Object.fromEntries(banco.markets.map((m) => [m.id, m.winning_answer === 'SÌ' ? 'yes' : 'no']))

// generatore casuale con seme fisso: la simulazione è ripetibile
let seed = 20261030
const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296 }

const db = await boot(22)
const q = async (sql, p) => (await db.query(sql, p)).rows
const one = async (sql, p) => (await q(sql, p))[0]
const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await one(`select public.${fn}(${ph}) as r`, args)).r }
await q(`select mazzobet.admin_new_session('Simulazione')`)
await q(`update mazzobet.config set value = extract(epoch from timestamptz '2099-01-01') where key = 'banco_inizio'`)
await q(`update mazzobet.game_sessions set ends_at = now() + interval '12 hours'`)
const N = 24
const tok = {}
for (let i = 1; i <= N; i++) tok[i] = (await rpc('mb_enter_team', [i, null, 'ua'])).token
await rpc('mb_race_load', [JSON.stringify(payload)])
await rpc('mb_admin_race_start')
const jump = async (sec) => {
  await q(`update mazzobet.race_runs set started_at = now() - make_interval(secs => ($1::double precision + paused_secs)) where session_id = ${ACT}`, [sec])
  await rpc('mb_race_tick')
}

console.log('# Una serata intera: 24 squadre, 180 minuti, passi di 10 secondi')
let placed = 0, rejected = 0
const seen = new Set()
for (let sec = 0; sec <= 10800; sec += 10) {
  await jump(sec)
  const st = await rpc('mb_race_state', [tok[1]])
  for (const m of st.markets.filter((x) => x.status === 'open')) {
    // ogni squadra decide una volta sola; la probabilità per passo fa arrivare le puntate sparse nel tempo
    for (let team = 1; team <= N; team++) {
      const key = m.id + ':' + team
      if (seen.has(key) || rnd() > 0.15) continue
      seen.add(key)
      if (rnd() > 0.7) continue
      const bal = Number((await one(`select balance from mazzobet.session_teams where session_id = ${ACT} and team_id = $1`, [team])).balance)
      if (bal < 10) continue
      const amount = Math.max(10, Math.min(bal, Math.floor(10 + rnd() * 190)))
      try { await rpc('mb_place_bet', [tok[team], m.id, rnd() < 0.5 ? 'yes' : 'no', amount]); placed++ } catch { rejected++ }
    }
  }
  if (sec % 300 === 0) await rpc('mb_tick')
}
await rpc('mb_tick')
console.log(`  puntate piazzate: ${placed}, rifiutate: ${rejected}`)

const run = await one(`select status from mazzobet.race_runs where session_id = ${ACT}`)
t('corsa conclusa', run.status === 'finished', run.status)
t('tutte le 73 notizie pubblicate', (await one(`select count(*)::int n from mazzobet.race_feed where session_id = ${ACT}`)).n === 73)
const markets = await q(`select race_market_id id, status, outcome, yes_pool, no_pool from mazzobet.markets where session_id = ${ACT} and race_market_id is not null order by race_market_id`)
t('tutte le 10 scommesse esistono e sono concluse', markets.length === 10 && markets.every((m) => m.status === 'resolved' || m.status === 'empty'), JSON.stringify(markets.map((m) => m.id + m.status)))
t('esiti uguali a quelli del palinsesto', markets.filter((m) => m.status === 'resolved').every((m) => m.outcome === winning[m.id]), JSON.stringify(markets.map((m) => m.id + m.outcome)))

const bets = await q(`select b.*, m.race_market_id rid, m.yes_odds, m.no_odds, m.outcome from mazzobet.bets b join mazzobet.markets m on m.id = b.market_id where m.session_id = ${ACT} and m.race_market_id is not null`)
t('ogni puntata è decisa', bets.length === placed && bets.every((b) => b.result === 'win' || b.result === 'loss'))
t("vincenti e perdenti coerenti con l'esito", bets.every((b) => (b.side === b.outcome) === (b.result === 'win')))
t('vincita = puntata × quota (arrotondata per difetto)', bets.filter((b) => b.result === 'win').every((b) => Number(b.payout) === Math.floor(Number(b.amount) * Number(b.side === 'yes' ? b.yes_odds : b.no_odds) / 100)))
t('puntate perdenti senza vincita', bets.filter((b) => b.result === 'loss').every((b) => !Number(b.payout)))

const sum = Number((await one(`select coalesce(sum(amount),0) s from mazzobet.ledger_entries where session_id = ${ACT}`)).s)
t('contabilità chiusa: la somma di tutti i movimenti è zero', sum === 0, String(sum))
t('nessuna squadra col saldo negativo', (await q(`select 1 from mazzobet.session_teams where session_id = ${ACT} and balance < 0`)).length === 0)

// idempotenza: ripetere i passi non cambia nulla
const snap = async () => JSON.stringify(await q(`select account, team_id, sum(amount) s from mazzobet.ledger_entries where session_id = ${ACT} group by 1,2 order by 1,2`))
const before = await snap()
for (let i = 0; i < 5; i++) { await rpc('mb_race_tick'); await rpc('mb_tick') }
t('ripetere i passi non paga due volte', before === (await snap()))
let late = false
try { await rpc('mb_place_bet', [tok[1], (await one(`select id from mazzobet.markets where race_market_id = 'B01' and session_id = ${ACT}`)).id, 'yes', 10]); late = true } catch { /* atteso */ }
t('a scommessa chiusa non si punta più', !late)

console.log('\n# Conto economico del Banco (solo scommesse della corsa)')
let staked = 0, paid = 0
for (const m of markets) {
  const mb = bets.filter((b) => b.rid === m.id)
  const s = mb.reduce((a, b) => a + Number(b.amount), 0)
  const p = mb.reduce((a, b) => a + Number(b.payout || 0), 0)
  staked += s; paid += p
  console.log(`  ${m.id}  esito ${m.outcome ?? '—'}  puntate ${String(mb.length).padStart(2)}  puntato ${String(s).padStart(5)}  pagato ${String(p).padStart(5)}  Banco ${s - p >= 0 ? '+' : ''}${s - p}`)
}
console.log(`  TOTALE  puntato ${staked}  pagato ${paid}  Banco ${staked - paid >= 0 ? '+' : ''}${staked - paid}  (saldo iniziale totale delle squadre: ${N * 1000})`)
const final = await q(`select balance from mazzobet.session_teams where session_id = ${ACT} order by balance`)
console.log(`  saldo minimo ${final[0].balance}, massimo ${final[final.length - 1].balance}`)
const bankCash = Number((await one(`select coalesce(sum(amount),0) s from mazzobet.ledger_entries where session_id = ${ACT} and account = 'bank'`)).s)
t('il conto del Banco torna con puntate e vincite', bankCash === staked - paid, `${bankCash} vs ${staked - paid}`)

console.log(`\n${ko === 0 ? 'TUTTO OK' : 'CI SONO ERRORI'}: ${ok} controlli passati, ${ko} falliti`)
process.exit(ko === 0 ? 0 : 1)
