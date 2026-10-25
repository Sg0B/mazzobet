// Prova della migration 014 (schermo /tv e annuncio della Regia) su Postgres in memoria. Uso: node server/tests/pglite/tv.mjs
import { boot } from './load.mjs'
import { readFileSync } from 'node:fs'
let fails = 0
const ok = (c, m) => { console.log(c ? '  ok  ' : '  KO  ', m); if (!c) fails++ }
const db = await boot(14)
await db.exec(`update mazzobet.config set value = 0 where key = 'banco_inizio'`)
await db.query('select public.mb_load_catalog($1::jsonb)', [readFileSync(new URL('../../data/catalogo_banco.json', import.meta.url), 'utf8')])
const q = async (sql, p = []) => (await db.query(sql, p)).rows[0]
const j = async (sql, p = []) => Object.values(await q(sql, p))[0]

const tk = []
for (let i = 1; i <= 6; i++) tk[i] = (await j(`select public.mb_enter_team(${i}::smallint)->>'token'`))
let tv = await j(`select public.mb_get_tv()`)
ok(tv.session.name === 'Serata 1' && tv.teams.length === 6, 'serata attiva e 6 squadre')
ok(tv.announcement === null && tv.open.length === 0 && Array.isArray(tv.rankings.patrimonio), 'niente annuncio, niente scommesse, classifiche presenti')

const mid = Number(await j(`select public.mb_create_market('${tk[1]}', 'Il cameriere porta prima le pizze o le birre?', 200, 200, now() + interval '30 minutes', 'k1')->>'marketId'`))
await db.exec(`select public.mb_place_bet('${tk[2]}', ${mid}, 'yes', 100); select public.mb_place_bet('${tk[3]}', ${mid}, 'no', 50)`)
tv = await j(`select public.mb_get_tv()`)
ok(tv.open.length === 1 && tv.open[0].bets === 2 && tv.open[0].yesPool === 100, 'scommessa aperta con totali')
await db.exec(`select public.mb_admin_resolve(${mid}, 'yes')`)
tv = await j(`select public.mb_get_tv()`)
ok(tv.open.length === 0 && tv.results.length === 1 && tv.results[0].best.name && tv.results[0].best.payout === 200, 'esito con il miglior vincitore')
await db.exec(`select mazzobet.run_bank_event(mazzobet.active_session())`)
tv = await j(`select public.mb_get_tv()`)
ok(tv.news.length > 0 && tv.bank.events.length === 1, 'RadioCorsa presente')

// classifiche identiche ai telefoni
const a = await j(`select public.mb_get_rankings('${tk[2]}')`)
ok(JSON.stringify(a) === JSON.stringify(tv.rankings), 'classifiche della TV = classifiche dei telefoni')

// annuncio
let st = await j(`select public.mb_admin_set_tv('Si cena alle 21', 10)`)
ok(st.tvMessage?.text === 'Si cena alle 21', 'annuncio impostato (visto dalla Regia)')
tv = await j(`select public.mb_get_tv()`)
ok(tv.announcement?.text === 'Si cena alle 21', 'annuncio visibile sulla TV')
await db.exec(`update mazzobet.game_sessions set tv_message_until = now() - interval '1 second'`)
tv = await j(`select public.mb_get_tv()`)
ok(tv.announcement === null, 'annuncio scaduto sparisce')
await db.exec(`select public.mb_admin_set_tv('Brindisi!', 5)`)
st = await j(`select public.mb_admin_set_tv('', 5)`)
ok(st.tvMessage === null && (await j(`select public.mb_get_tv()`)).announcement === null, "testo vuoto toglie l'annuncio")
let err = ''
try { await db.exec(`select public.mb_admin_set_tv('${'x'.repeat(141)}', 5)`) } catch (e) { err = e.message }
ok(/bad_param/.test(err), 'oltre 140 caratteri rifiutato')
try { err = ''; await db.exec(`select public.mb_admin_set_tv('ciao', 0)`) } catch (e) { err = e.message }
ok(/bad_param/.test(err), 'durata 0 rifiutata')

// permessi
for (const r of ['anon', 'authenticated']) {
  let denied = false
  try { await db.exec(`set role ${r}; select public.mb_get_tv()`) } catch { denied = true }
  await db.exec('reset role')
  ok(denied, `${r} non può leggere la TV`)
}

// serata chiusa: la TV mostra l'ultima
await db.exec(`select public.mb_admin_close_session()`)
tv = await j(`select public.mb_get_tv()`)
ok(tv.session.status === 'closed', 'a serata chiusa mostra la classifica finale')
console.log(fails ? `\n${fails} falliti` : '\ntutto ok')
process.exit(fails ? 1 : 0)
