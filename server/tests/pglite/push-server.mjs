// Prova del worker delle notifiche con il server vero: finto Supabase (inoltra le rpc a Postgres in memoria)
// e finto servizio push HTTPS (certificato temporaneo). Uso (dalla radice):  node server/tests/pglite/push-server.mjs
import http from 'node:http'
import https from 'node:https'
import { spawn, execFileSync } from 'node:child_process'
import { createECDH, randomBytes } from 'node:crypto'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { boot } from './load.mjs'

const webpush = createRequire(new URL('../../package.json', import.meta.url))('web-push')
let fails = 0
const ok = (c, m) => { console.log(c ? '  ok  ' : '  KO  ', m); if (!c) fails++ }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const db = await boot(16)
const q = async (sql, p = []) => (await db.query(sql, p)).rows
const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await q(`select public.${fn}(${ph}) as r`, args))[0].r }
await q(`select mazzobet.admin_new_session('Test')`)

// finto Supabase
const shim = http.createServer(async (req, res) => {
  const fn = req.url.split('/rpc/')[1]
  let body = ''
  for await (const c of req) body += c
  const args = JSON.parse(body || '{}')
  const keys = Object.keys(args)
  try {
    const r = (await db.query(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`, keys.map((k) => args[k]))).rows[0].r
    res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(r))
  } catch (e) {
    res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ message: e.message }))
  }
})
await new Promise((r) => shim.listen(54398, r))

// finto servizio push (https, certificato temporaneo)
const dir = mkdtempSync(join(tmpdir(), 'mbpush-'))
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'k.pem'), '-out', join(dir, 'c.pem'), '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' })
const hits = []
const pushSvc = https.createServer({ key: readFileSync(join(dir, 'k.pem')), cert: readFileSync(join(dir, 'c.pem')) }, (req, res) => {
  hits.push({ url: req.url, ttl: req.headers.ttl, urgency: req.headers.urgency, auth: String(req.headers.authorization ?? '') })
  req.resume()
  res.writeHead(req.url.startsWith('/gone') ? 410 : 201); res.end()
})
await new Promise((r) => pushSvc.listen(54397, r))
const sub = (path) => {
  const e = createECDH('prime256v1'); e.generateKeys()
  return { endpoint: `https://localhost:54397${path}`, keys: { p256dh: e.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') } }
}

const vapid = webpush.generateVAPIDKeys()
const start = (port, extra = {}) => spawn('npx', ['tsx', 'server/src/index.ts'], {
  shell: true, stdio: 'ignore',
  env: { ...process.env, SUPABASE_URL: 'http://127.0.0.1:54398', SUPABASE_SERVICE_ROLE_KEY: 'finta', PORT: String(port),
         NODE_TLS_REJECT_UNAUTHORIZED: '0', VAPID_PUBLIC_KEY: vapid.publicKey, VAPID_PRIVATE_KEY: vapid.privateKey,
         VAPID_SUBJECT: 'mailto:prova@esempio.it', PUSH_B_PER_TEAM_COOLDOWN_SEC: '120', ...extra },
})
const waitUp = async (port) => { for (let i = 0; i < 60; i++) { try { if ((await fetch(`http://127.0.0.1:${port}/api/health`)).ok) return } catch { /* attende */ } await sleep(500) } }
const killPort = (port) => spawn('powershell', ['-NoProfile', '-Command', `Get-NetTCPConnection -LocalPort ${port} -State Listen -ErrorAction SilentlyContinue | % { Stop-Process -Id $_.OwningProcess -Force }`], { stdio: 'ignore' })
const post = (base, path, token, body) => fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { 'x-device-token': token } : {}) }, body: JSON.stringify(body) }).then(async (r) => ({ s: r.status, b: await r.json() }))
const tok = {}
for (let i = 1; i <= 3; i++) tok[i] = (await rpc('mb_enter_team', [i, null, 'ua'])).token
const mk = async (team, key) => Number((await rpc('mb_create_market', [tok[team], 'Domanda di prova numero ' + key, 200, 200, new Date(Date.now() + 120000).toISOString(), 'key-' + key + '-abcdef'])).marketId)
const expire = (m, secs) => q(`update mazzobet.markets set scheduled_close_at = now() - make_interval(secs => $2) where id = $1`, [m, secs])

killPort(3398); killPort(3397)
let srv, srv2
try {
  srv = start(3398)
  await waitUp(3398)
  const A = 'http://127.0.0.1:3398/api'

  console.log('# rotte')
  const k = await (await fetch(A + '/push/key')).json()
  ok(k.enabled === true && k.key === vapid.publicKey && !JSON.stringify(k).includes(vapid.privateKey), 'chiave pubblica sì, privata mai')
  ok((await post(A, '/push/subscribe', null, { subscription: sub('/ok/1') })).s === 401, 'iscriversi senza sessione: 401')
  ok((await post(A, '/push/subscribe', tok[1], { subscription: { endpoint: 'x' } })).s === 400, 'iscrizione malformata: 400')
  ok((await post(A, '/push/subscribe', tok[1], { subscription: sub('/ok/1') })).s === 200, 'squadra 1 si iscrive')
  ok((await post(A, '/push/subscribe', tok[2], { subscription: sub('/ok/2') })).s === 200, 'squadra 2 si iscrive')
  ok((await post(A, '/push/subscribe', tok[3], { subscription: sub('/gone/3') })).s === 200, 'squadra 3 si iscrive (il suo servizio risponderà 410)')

  console.log('# A al creatore (squadra 1 crea, la 2 punta)')
  const m1 = await mk(1, 'a')
  await rpc('mb_place_bet', [tok[2], m1, 'yes', 100])
  await expire(m1, 5)
  await sleep(7000)
  const h1 = hits.filter((h) => h.url.startsWith('/ok/1'))
  ok(h1.length === 1 && !hits.some((h) => h.url.startsWith('/ok/2')), 'una notifica alla 1, nessuna alla 2 che ha puntato')
  ok(h1[0]?.ttl === '900' && h1[0]?.urgency === 'high' && h1[0]?.auth.toLowerCase().startsWith('vapid'), 'TTL 15 minuti, urgenza alta, firma VAPID')
  await sleep(6000)
  ok(hits.filter((h) => h.url.startsWith('/ok/1')).length === 1, 'nessun doppione dopo altri giri del worker')

  console.log('# B (squadra 3, il suo servizio risponde 410)')
  await expire(m1, 130)
  await sleep(7000)
  ok(hits.some((h) => h.url.startsWith('/gone/3')), 'la B parte verso la 3')
  ok((await q(`select disabled_at from mazzobet.push_subscriptions where team_id = 3`))[0].disabled_at !== null, '410: iscrizione disattivata, nessun errore visibile')
  ok(!hits.some((h) => h.url.startsWith('/ok/2')), 'chi ha puntato non riceve mai la B')

  console.log('# riavvio a metà finestra: nessun duplicato')
  const before = hits.length
  killPort(3398); await sleep(1500)
  srv = start(3398); await waitUp(3398)
  await sleep(8000)
  ok(hits.length === before, 'dopo il riavvio del server nessuna notifica ripetuta')
  killPort(3398)

  console.log('# PUSH_ENABLED=false')
  srv2 = start(3397, { PUSH_ENABLED: 'false' }); await waitUp(3397)
  const B = 'http://127.0.0.1:3397/api'
  ok((await (await fetch(B + '/push/key')).json()).enabled === false, 'la chiave non viene offerta')
  ok((await post(B, '/push/subscribe', tok[1], { subscription: sub('/ok/1') })).s === 503, 'iscriversi: 503 chiaro')
  const m2 = await mk(1, 'z'); await rpc('mb_place_bet', [tok[2], m2, 'yes', 100]); await expire(m2, 5)
  const n = hits.length
  await sleep(8000)
  ok(hits.length === n, 'nessun invio con le notifiche spente')
  const open = await (await fetch(B + '/state', { headers: { 'x-device-token': tok[1] } })).json()
  ok(Array.isArray(open.markets), 'il gioco funziona normalmente')
} finally {
  killPort(3398); killPort(3397)
  shim.close(); pushSvc.close()
}
console.log(fails ? `\n${fails} FALLITI` : '\ntutto ok')
process.exit(fails ? 1 : 0)
