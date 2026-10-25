// Prova delle migration su un Postgres in memoria (PGlite): non tocca nessun database vero.
// Uso (dalla radice del progetto):  npm i --no-save @electric-sql/pglite  poi  node server/tests/pglite/load.mjs
import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
const D = new URL('../../db/', import.meta.url)
export async function boot(upTo = 13){
  const db=new PGlite()
  await db.exec(`create role service_role; create role anon; create role authenticated;`)
  const files=readdirSync(D).filter(f=>/^0\d\d_.*\.sql$/.test(f)).sort()
  for(const f of files){
    const n=parseInt(f.slice(0,3)); if(n>upTo) break
    try{ await db.exec(readFileSync(new URL(f, D), 'utf8')) }catch(e){ console.log('ERRORE in',f,':',e.message); throw e }
  }
  return db
}
if (process.argv[1].endsWith('load.mjs')){ const db=await boot(); console.log('schema+011 caricati'); console.log((await db.query("select count(*) from mazzobet.config")).rows[0]) }
