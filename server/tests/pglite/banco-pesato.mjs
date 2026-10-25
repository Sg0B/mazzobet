// Confronto tra estrazione uniforme (schema fino alla 012) e pesata (013): quante squadre su 24 non vengono mai colpite in
// un'ora di Banco (~6 interventi). Uso: node server/tests/pglite/banco-pesato.mjs
import { boot } from './load.mjs'
import { readFileSync } from 'node:fs'
const RUNS = 40, EVENTS = 6, TEAMS = 24
async function run(upTo) {
  let never = 0, maxHits = 0
  for (let r = 0; r < RUNS; r++) {
    const db = await boot(upTo)
    await db.exec(`update mazzobet.config set value = 0 where key = 'banco_inizio'; select mazzobet.admin_new_session('T')`)
    await db.query('select public.mb_load_catalog($1::jsonb)', [readFileSync(new URL('../../data/catalogo_banco.json', import.meta.url), 'utf8')])
    for (let i = 1; i <= TEAMS; i++) await db.exec(`select public.mb_enter_team(${i}::smallint)`)
    for (let e = 0; e < EVENTS; e++) await db.exec(`select mazzobet.run_bank_event(mazzobet.active_session())`)
    const hits = (await db.query(`select t, count(*)::int c from mazzobet.bank_events, unnest(teams) t where kind in ('bonus','malus') group by t`)).rows
    never += TEAMS - hits.length
    maxHits = Math.max(maxHits, ...hits.map(h => h.c))
    await db.close()
  }
  return { mediaMaiColpite: (never / RUNS).toFixed(1), maxColpiPerSquadra: maxHits }
}
console.log('uniforme (012):', await run(12))
console.log('pesata   (013):', await run(13))
