// Prova della migration 015 (PIN squadre) con il server vero davanti a un finto Supabase che inoltra le rpc a un Postgres in memoria.
// Uso (dalla radice): npm i --no-save @electric-sql/pglite  poi  node server/tests/pglite/pin.mjs   (usa tsx per importare pin.ts)
import http from 'node:http'
import { spawn } from 'node:child_process'
import { boot } from './load.mjs'

let fails = 0
const ok = (c, m) => { console.log(c ? '  ok  ' : '  KO  ', m); if (!c) fails++ }
const db = await boot(15)
await db.exec(`select mazzobet.admin_new_session('Test')`)
const q = async (sql, p = []) => (await db.query(sql, p)).rows

// Finto PostgREST: POST /rest/v1/rpc/<fn> con argomenti con nome.
const shim = http.createServer(async (req, res) => {
  const fn = req.url.split('/rpc/')[1]
  let body = ''
  for await (const c of req) body += c
  const args = JSON.parse(body || '{}')
  const keys = Object.keys(args)
  const call = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`
  try {
    const r = (await db.query(call, keys.map((k) => args[k]))).rows[0].r
    res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(r))
  } catch (e) {
    res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ message: e.message }))
  }
})
await new Promise((r) => shim.listen(54399, r))
const srv = spawn('npx', ['tsx', 'server/src/index.ts'], {
  shell: true, stdio: 'ignore',
  env: { ...process.env, SUPABASE_URL: 'http://127.0.0.1:54399', SUPABASE_SERVICE_ROLE_KEY: 'finta', PORT: '3399' },
})
const B = 'http://127.0.0.1:3399/api'
for (let i = 0; i < 60; i++) { try { if ((await fetch(B + '/health')).ok) break } catch { /* attende */ } await new Promise((r) => setTimeout(r, 500)) }
const enter = async (teamId, pin, token) => {
  const r = await fetch(B + '/enter', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ teamId, pin, token }) })
  return { s: r.status, b: await r.json() }
}
const list = async () => (await (await fetch(B + '/teams')).json())
const unblock = () => db.exec(`update mazzobet.team_pins set blocked_until = now() - interval '1 second'`)

try {
  console.log('# 1 primo accesso')
  let r = await enter(3, undefined)
  ok(r.s === 400 && r.b.error === 'pin_required', 'senza PIN non entra')
  r = await enter(3, '12a4')
  ok(r.s === 400, 'PIN non numerico rifiutato')
  r = await enter(3, '4821')
  ok(r.s === 200 && r.b.token && r.b.firstEntry === true, 'squadra libera: imposta il PIN ed entra')
  const tokA = r.b.token
  const row = (await q(`select pin_hash, pin_salt from mazzobet.team_pins where team_id = 3`))[0]
  ok(row && row.pin_hash.length === 64 && row.pin_salt.length === 32 && !row.pin_hash.includes('4821'), 'salvati solo hash scrypt e sale')
  ok(JSON.stringify(await q(`select * from mazzobet.team_pins`)).indexOf('4821') === -1, 'PIN mai in chiaro nel database')
  let t3 = (await list()).find((t) => t.id === 3)
  ok(t3.entered && t3.hasPin && t3.lockedSecs === 0, 'per gli altri la squadra è «già in gioco» con PIN')
  r = await enter(3, '4821', 'non-un-uuid')
  ok(r.s === 200 && r.b.token !== tokA && r.b.firstEntry === false && r.b.otherDevices === true, 'secondo dispositivo con lo stesso PIN: entra, stesso saldo')

  console.log('# 2 PIN sbagliato 5 volte')
  r = await enter(3, '0000')
  ok(r.s === 403 && r.b.error === 'pin_wrong' && r.b.left === 4, 'primo errore: restano 4 tentativi')
  for (let i = 0; i < 3; i++) r = await enter(3, '0000')
  ok(r.s === 403 && r.b.left === 1, 'quarto errore: resta 1 tentativo')
  r = await enter(3, '0000')
  ok(r.s === 429 && r.b.error === 'pin_locked' && r.b.lockedSecs > 0 && r.b.lockedSecs <= 60, 'quinto errore: blocco di 1 minuto')
  r = await enter(3, '4821')
  ok(r.s === 429, 'durante il blocco anche il PIN giusto è rifiutato')
  t3 = (await list()).find((t) => t.id === 3)
  ok(t3.lockedSecs > 0, 'l\'elenco squadre mostra il blocco')
  r = await enter(4, '1111')
  ok(r.s === 200, 'il blocco è per squadra: un\'altra squadra entra')
  r = await enter(3, '0000', tokA)
  ok(r.s === 200, 'dispositivo già riconosciuto entra anche durante il blocco')
  await unblock()
  r = await enter(3, '4821')
  ok(r.s === 200, 'finito il blocco il PIN giusto funziona')
  r = await enter(3, '0000'); const a = r.b.left
  r = await enter(3, '4821'); r = await enter(3, '0000')
  ok(a === 4 && r.b.left === 4, 'il PIN giusto azzera il conteggio degli errori')

  console.log('# 3 dispositivo noto / nuovo')
  r = await enter(3, undefined, tokA)
  ok(r.s === 200 && r.b.token === tokA, 'dispositivo riconosciuto: nessun PIN e stesso token')
  r = await enter(3, undefined, tokA.replace(/^./, tokA[0] === 'a' ? 'b' : 'a'))
  ok(r.s === 400 && r.b.error === 'pin_required', 'token sconosciuto = nuovo dispositivo: serve il PIN')
  r = await enter(5, undefined, tokA)
  ok(r.s === 400, 'il token di una squadra non apre un\'altra squadra')

  console.log('# 4 reset squadra')
  const bal = (await q(`select balance from mazzobet.session_teams where team_id = 3`))[0].balance
  const led = (await q(`select count(*)::int n from mazzobet.ledger_entries where team_id = 3`))[0].n
  await q(`select public.mb_admin_reset_team(3::smallint)`)
  ok((await q(`select count(*)::int n from mazzobet.team_pins where team_id = 3`))[0].n === 0, 'PIN cancellato')
  ok((await q(`select count(*)::int n from mazzobet.team_devices where team_id = 3`))[0].n === 0, 'dispositivi cancellati')
  ok((await q(`select balance from mazzobet.session_teams where team_id = 3`))[0].balance === bal
    && (await q(`select count(*)::int n from mazzobet.ledger_entries where team_id = 3`))[0].n === led, 'saldo e storico invariati')
  r = await enter(3, undefined, tokA)
  ok(r.s === 400, 'il vecchio token non entra più')
  r = await enter(3, '9999')
  ok(r.s === 200 && r.b.firstEntry === false, 'la squadra è di nuovo libera: nuovo PIN, stesso saldo')
  ok((await q(`select count(*)::int n from mazzobet.admin_log where action = 'reset_squadra'`))[0].n === 1, 'reset nel log della Regia')

  console.log('# squadra già in gara senza PIN (prima della 015)')
  await q(`select public.mb_enter_team(7::smallint)`)
  ok((await list()).find((t) => t.id === 7).entered && !(await list()).find((t) => t.id === 7).hasPin, 'elenco: in gioco ma senza PIN')
  r = await enter(7, '2468')
  ok(r.s === 200 && (await q(`select count(*)::int n from mazzobet.team_pins where team_id = 7`))[0].n === 1, 'chi entra imposta il PIN')

  console.log('# telefono già riconosciuto su squadra senza PIN')
  const legacy = (await q(`select public.mb_enter_team(8::smallint) as r`))[0].r
  const api = (path, token, body) => fetch(B + path, { method: body ? 'POST' : 'GET', headers: { 'content-type': 'application/json', 'x-device-token': token }, body: body ? JSON.stringify(body) : undefined }).then(async (x) => ({ s: x.status, b: await x.json() }))
  r = await api('/pin?teamId=8', legacy.token)
  ok(r.s === 200 && r.b.hasPin === false, 'il telefono riconosciuto scopre che manca il PIN')
  r = await api('/pin?teamId=9', legacy.token)
  ok(r.s === 401, "il token di una squadra non parla per un'altra squadra")
  r = await api('/pin', legacy.token, { teamId: 8, pin: '12' })
  ok(r.s === 400, 'PIN malformato rifiutato')
  r = await api('/pin', legacy.token, { teamId: 8, pin: '1357' })
  ok(r.s === 200, 'imposta il PIN dal telefono già dentro')
  r = await api('/pin', legacy.token, { teamId: 8, pin: '2222' })
  ok(r.s === 409, 'non si può sovrascrivere un PIN esistente')
  r = await api('/pin?teamId=8', legacy.token)
  ok(r.b.hasPin === true, 'ora la squadra ha il PIN')
  r = await enter(8, '2222')
  ok(r.s === 403 && r.b.error === 'pin_wrong', 'un altro telefono ora deve conoscere il PIN')
  r = await enter(8, '1357')
  ok(r.s === 200, 'e con il PIN giusto entra')

  console.log('# permessi')
  const g = await q(`select has_function_privilege('anon', 'public.mb_pin_status(smallint, uuid)', 'execute') a, has_function_privilege('service_role', 'public.mb_pin_status(smallint, uuid)', 'execute') s`)
  ok(!g[0].a && g[0].s, 'le funzioni PIN sono chiamabili solo dal server')
} finally {
  spawn('taskkill', ['/pid', String(srv.pid), '/T', '/F'], { stdio: 'ignore' })
  // il server figlio può restare in ascolto: lo fermo anche per porta (Windows)
  spawn('powershell', ['-NoProfile', '-Command', "Get-NetTCPConnection -LocalPort 3399 -State Listen -ErrorAction SilentlyContinue | % { Stop-Process -Id $_.OwningProcess -Force }"], { stdio: 'ignore' })
  shim.close()
}
console.log(fails ? `\n${fails} FALLITI` : '\ntutto ok')
process.exit(fails ? 1 : 0)
