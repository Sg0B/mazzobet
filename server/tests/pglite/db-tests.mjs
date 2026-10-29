// Prova delle migration su un Postgres in memoria (PGlite): non tocca nessun database vero.
// Uso (dalla radice del progetto):  npm i --no-save @electric-sql/pglite  poi  node server/tests/pglite/db-tests.mjs
import { boot } from './load.mjs'
import { readFileSync, readdirSync } from 'node:fs'
const T = new URL('../../db/tests/', import.meta.url)
for (const upTo of [13, 21]) {
  for (const f of readdirSync(T).sort()) {
    const db = await boot(upTo)
    await db.exec(`select mazzobet.admin_new_session('T')`); await db.query('select public.mb_load_catalog($1::jsonb)', [readFileSync(new URL('../../data/catalogo_banco.json', import.meta.url), 'utf8')])
    if (upTo >= 11) await db.exec(`update mazzobet.config set value = 0 where key = 'banco_inizio'`)
    let res
    try { const r = await db.exec(readFileSync(new URL(f, T), 'utf8')); res = JSON.stringify(r.flatMap(x => x.rows)).match(/TEST_OK[^"]*/)?.[0] ?? 'eseguito senza TEST_OK' } catch (e) { res = 'ERRORE: ' + e.message.slice(0, 160) }
    console.log(`schema ${upTo}  ${f}: ${res}`)
  }
}
