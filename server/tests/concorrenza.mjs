#!/usr/bin/env node
// Prova di concorrenza sull'API vera (scenari 3 e 4 del prompt v0.6 + creazione duplicata ed esito simultaneo).
// Spara molte richieste insieme e controlla che il risultato sia sempre uno solo.
//
//   node tests/concorrenza.mjs            (server acceso su http://localhost:3000 e serata attiva)
//
// Usa le squadre 20-24, che devono essere ancora fuori dalla serata. Lascia dati di prova nella serata:
// usalo su una serata di prova e poi chiudila.
const BASE = process.argv[2] ?? 'http://localhost:3000'
const results = []
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'OK    ' : 'ERRORE'} ${name}${detail ? ' — ' + detail : ''}`) }

async function call(path, { body, token } = {}) {
  const r = await fetch(BASE + '/api' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...(token ? { 'x-device-token': token } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  return { status: r.status, data: await r.json().catch(() => ({})) }
}
const enter = async (teamId) => {
  const r = await call('/enter', { body: { teamId } })
  if (r.status !== 200) throw new Error(`squadra ${teamId} non entrata (${r.data.error}): serve una serata attiva con la squadra libera`)
  return r.data.token
}
const state = async (t) => (await call('/state', { token: t })).data
const balance = async (t) => Number((await state(t)).me.balance)
const future = (min) => new Date(Date.now() + min * 60_000).toISOString()
const create = (t, q, key) => call('/markets', { token: t, body: { question: q, yesOdds: 200, noOdds: 200, expiresAt: future(25), key } })
const count = (rs, f) => rs.filter(f).length

const run = Date.now().toString(36)
const [t20, t21, t22, t23, t24] = await Promise.all([20, 21, 22, 23, 24].map(enter))

// A. Doppio tap: 20 richieste identiche insieme → una sola puntata addebitata
{
  const m = (await create(t20, 'Prova doppio tap sulla puntata', `A-${run}`)).data.marketId
  const before = await balance(t21)
  const rs = await Promise.all(Array.from({ length: 20 }, () => call(`/markets/${m}/bets`, { token: t21, body: { side: 'yes', amount: 50 } })))
  const after = await balance(t21)
  check('A. doppio tap: tutte le risposte positive', count(rs, (r) => r.status === 200) === 20, `${count(rs, (r) => r.status === 200)}/20`)
  check('A. doppio tap: addebitata una sola volta', before - after === 50, `saldo ${before} → ${after}`)
  check('A. doppio tap: una sola puntata vera', count(rs, (r) => r.data.replay === false) === 1, `${count(rs, (r) => r.data.replay === false)} nuove`)
}

// B. Stessa squadra, stessa scommessa, lati opposti insieme → una sola passa
{
  const m = (await create(t20, 'Prova lati opposti in simultanea', `B-${run}`)).data.marketId
  const before = await balance(t22)
  const rs = await Promise.all(Array.from({ length: 10 }, (_, i) => call(`/markets/${m}/bets`, { token: t22, body: { side: i % 2 ? 'yes' : 'no', amount: 50 } })))
  const after = await balance(t22)
  check('B. lati opposti: addebito unico', before - after === 50, `saldo ${before} → ${after}`)
  check('B. lati opposti: i perdenti vengono rifiutati', count(rs, (r) => r.data.error === 'already_bet') === 5, `${count(rs, (r) => r.data.error === 'already_bet')} rifiutate`)
}

// C. Tre puntate da 700 su tre scommesse diverse insieme (saldo 1000) → ne passa una sola
{
  const ms = []
  for (let i = 0; i < 3; i++) ms.push((await create(t20, `Prova saldo insufficiente numero ${i + 1}`, `C${i}-${run}`)).data.marketId)
  const before = await balance(t23)
  const rs = await Promise.all(ms.map((m) => call(`/markets/${m}/bets`, { token: t23, body: { side: 'yes', amount: 700 } })))
  const after = await balance(t23)
  check('C. saldo insufficiente: passa una sola puntata', count(rs, (r) => r.status === 200) === 1, `${count(rs, (r) => r.status === 200)} accettate`)
  check('C. saldo insufficiente: le altre rifiutate per saldo', count(rs, (r) => r.data.error === 'insufficient_funds') === 2)
  check('C. saldo insufficiente: nessun saldo negativo', after >= 0 && before - after === 700, `saldo ${before} → ${after}`)
}

// D. Creazione duplicata: 10 richieste con la stessa chiave → una scommessa, 100 Carletti una volta sola
{
  const before = await balance(t24)
  const rs = await Promise.all(Array.from({ length: 10 }, () => create(t24, 'Prova creazione duplicata insieme', `D-${run}`)))
  const after = await balance(t24)
  const ids = new Set(rs.map((r) => r.data.marketId))
  check('D. creazione duplicata: una sola scommessa', ids.size === 1, `${ids.size} scommesse`)
  check('D. creazione duplicata: 100 Carletti addebitati una volta', before - after === 100, `saldo ${before} → ${after}`)
}

// E. Esito simultaneo: il creatore prova SÌ e NO insieme → ne vale uno solo
{
  const m = (await create(t20, 'Prova esito in simultanea ok', `E-${run}`)).data.marketId
  await call(`/markets/${m}/bets`, { token: t21, body: { side: 'yes', amount: 10 } })
  const rs = await Promise.all(Array.from({ length: 6 }, (_, i) => call(`/markets/${m}/resolve`, { token: t20, body: { outcome: i % 2 ? 'yes' : 'no' } })))
  check('E. esito simultaneo: ne passa uno solo', count(rs, (r) => r.status === 200) === 1, `${count(rs, (r) => r.status === 200)} accettati`)
  check('E. esito simultaneo: gli altri vedono «già esitata»', count(rs, (r) => r.data.error === 'already_resolved') === 5)
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `\n${failed} controlli falliti su ${results.length}.` : `\nTutti i ${results.length} controlli superati.`)
process.exit(failed ? 1 : 0)
