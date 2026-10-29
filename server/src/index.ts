import { createHash, timingSafeEqual } from 'node:crypto'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import rateLimit from '@fastify/rate-limit'
import fastifyStatic from '@fastify/static'
import { createClient } from '@supabase/supabase-js'
import { toApiError } from './errors.js'
import { readCatalog, validateCatalog } from './catalog.js'
import { PIN_FORMAT, checkPin, hashPin } from './pin.js'
import { configurePush, sendItem, type PushItem } from './push.js'
import { buildRace, readRace } from './race.js'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!url || !key) {
  console.error('Mancano SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY (vedi server/.env.example).')
  process.exit(1)
}

// Chiave privilegiata solo qui: il browser non vede mai il database.
const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })

// Dietro Caddy: l'IP reale arriva da X-Forwarded-For (serve ai limiti per indirizzo).
const app = Fastify({ logger: true, trustProxy: true })
// Limite leggero PER DISPOSITIVO (token), non per IP: a una cena tutti i telefoni sono dietro lo stesso wifi,
// quindi lo stesso IP. Senza token (scelta squadra) vale un limite più largo per IP.
await app.register(rateLimit, {
  timeWindow: '1 minute',
  keyGenerator: (req) => {
    const t = req.headers['x-device-token']
    return typeof t === 'string' && t ? `d:${t}` : `ip:${req.ip}`
  },
  max: (req) => (req.headers['x-device-token'] ? 150 : 400),
})

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Chiama una funzione SQL; gli errori di dominio diventano risposte HTTP leggibili. */
async function rpc(reply: FastifyReply, fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await db.rpc(fn, args)
  if (error) {
    const e = toApiError(error)
    if (e.status === 500) app.log.error({ fn, error }, 'rpc failed')
    return reply.code(e.status).send({ error: e.code, message: e.message })
  }
  return data
}

function token(req: FastifyRequest, reply: FastifyReply): string | null {
  const t = req.headers['x-device-token']
  if (typeof t === 'string' && UUID.test(t)) return t
  reply.code(401).send({ error: 'unauthorized', message: 'Sessione non valida: scegli di nuovo la squadra.' })
  return null
}

const int = (v: unknown) => (typeof v === 'number' && Number.isInteger(v) ? v : null)

// Controllo di salute per Docker e per il monitoraggio: non tocca il database.
app.get('/api/health', async () => ({ ok: true }))

app.get('/api/teams', async (_req, reply) => rpc(reply, 'mb_list_teams'))

app.post('/api/enter', async (req, reply) => {
  const b = (req.body ?? {}) as { teamId?: unknown; token?: unknown; pin?: unknown }
  const teamId = int(b.teamId)
  if (teamId === null) return reply.code(400).send({ error: 'unknown_team', message: 'Squadra sconosciuta.' })
  const prev = typeof b.token === 'string' && UUID.test(b.token) ? b.token : null
  const pin = typeof b.pin === 'string' && PIN_FORMAT.test(b.pin) ? b.pin : null
  const enter = () =>
    rpc(reply, 'mb_enter_team', { p_team: teamId, p_token: prev, p_user_agent: req.headers['user-agent'] ?? null })
  const locked = (secs: number) =>
    reply.code(429).send({ error: 'pin_locked', lockedSecs: secs, message: `Troppi tentativi: riprova tra ${secs} secondi.` })

  const { data: st, error } = await db.rpc('mb_pin_status', { p_team: teamId, p_token: prev })
  if (error) {
    const e = toApiError(error)
    if (e.status === 500) app.log.error({ fn: 'mb_pin_status', error }, 'rpc failed')
    return reply.code(e.status).send({ error: e.code, message: e.message })
  }
  // Dispositivo già riconosciuto per questa squadra: nessun PIN.
  if (st.known) return enter()
  if (st.lockedSecs > 0) return locked(st.lockedSecs)

  if (!pin) {
    return reply.code(400).send({ error: 'pin_required', message: 'Servono 4 cifre per il PIN.' })
  }
  if (!st.hasPin) {
    // Squadra libera (o già in gara ma senza PIN): chi entra imposta il PIN.
    const { hash, salt } = hashPin(pin)
    const { data: set, error: e2 } = await db.rpc('mb_pin_set', { p_team: teamId, p_hash: hash, p_salt: salt })
    if (e2) {
      const e = toApiError(e2)
      return reply.code(e.status).send({ error: e.code, message: e.message })
    }
    if (!set) {
      return reply.code(409).send({ error: 'pin_taken', message: 'Un attimo fa qualcuno ha scelto questa squadra. Se è la tua, inserisci il PIN.' })
    }
    return enter()
  }
  if (checkPin(pin, st.hash, st.salt)) {
    await db.rpc('mb_pin_ok', { p_team: teamId })
    return enter()
  }
  const { data: f, error: e3 } = await db.rpc('mb_pin_fail', { p_team: teamId })
  if (e3) {
    const e = toApiError(e3)
    return reply.code(e.status).send({ error: e.code, message: e.message })
  }
  if (f.lockedSecs > 0) return locked(f.lockedSecs)
  return reply.code(403).send({
    error: 'pin_wrong', left: f.left,
    message: `PIN sbagliato. ${f.left === 1 ? 'Ti resta 1 tentativo' : `Ti restano ${f.left} tentativi`}.`,
  })
})

// Squadre entrate prima dei PIN: il telefono già riconosciuto può impostarlo da qui (GET: serve?, POST: imposta).
// Il token dice di quale squadra è il telefono: il server lo verifica prima di fidarsi di teamId.
async function ownPin(req: FastifyRequest, reply: FastifyReply, teamId: number | null) {
  const t = token(req, reply)
  if (!t) return null
  if (teamId === null) { reply.code(400).send({ error: 'unknown_team', message: 'Squadra sconosciuta.' }); return null }
  const { data, error } = await db.rpc('mb_pin_status', { p_team: teamId, p_token: t })
  if (error) { const e = toApiError(error); reply.code(e.status).send({ error: e.code, message: e.message }); return null }
  if (!data.known) { reply.code(401).send({ error: 'unauthorized', message: 'Sessione non valida: scegli di nuovo la squadra.' }); return null }
  return data as { hasPin: boolean }
}

app.get('/api/pin', async (req, reply) => {
  const st = await ownPin(req, reply, int(Number((req.query as { teamId?: string }).teamId)))
  if (st) return { hasPin: st.hasPin }
})

app.post('/api/pin', async (req, reply) => {
  const b = (req.body ?? {}) as { teamId?: unknown; pin?: unknown }
  const st = await ownPin(req, reply, int(b.teamId))
  if (!st) return
  if (st.hasPin) return reply.code(409).send({ error: 'pin_taken', message: 'Questa squadra ha già un PIN.' })
  if (typeof b.pin !== 'string' || !PIN_FORMAT.test(b.pin)) return reply.code(400).send({ error: 'pin_required', message: 'Servono 4 cifre per il PIN.' })
  const { hash, salt } = hashPin(b.pin)
  const { data: set, error } = await db.rpc('mb_pin_set', { p_team: b.teamId, p_hash: hash, p_salt: salt })
  if (error) { const e = toApiError(error); return reply.code(e.status).send({ error: e.code, message: e.message }) }
  if (!set) return reply.code(409).send({ error: 'pin_taken', message: 'Questa squadra ha già un PIN.' })
  return { ok: true }
})

// ---- Notifiche push (solo due tipi, vedi docs/notifiche.md). Chiavi VAPID solo nel .env del server.
const VAPID_PUBLIC = process.env.VAPID_PUBLIC_KEY ?? ''
const VAPID_PRIVATE = process.env.VAPID_PRIVATE_KEY ?? ''
const VAPID_SUBJECT = process.env.VAPID_SUBJECT ?? ''
const PUSH_ON = process.env.PUSH_ENABLED !== 'false' && !!VAPID_PUBLIC && !!VAPID_PRIVATE && VAPID_SUBJECT.startsWith('mailto:')
const PUSH_COOLDOWN = Number(process.env.PUSH_B_PER_TEAM_COOLDOWN_SEC ?? 120)
if (PUSH_ON) configurePush({ publicKey: VAPID_PUBLIC, privateKey: VAPID_PRIVATE, subject: VAPID_SUBJECT })

app.get('/api/push/key', async () => (PUSH_ON ? { enabled: true, key: VAPID_PUBLIC } : { enabled: false }))

app.post('/api/push/subscribe', async (req, reply) => {
  const t = token(req, reply)
  if (!t) return
  if (!PUSH_ON) return reply.code(503).send({ error: 'push_disabled', message: 'Gli avvisi non sono attivi sul server.' })
  const sub = ((req.body ?? {}) as { subscription?: { endpoint?: unknown; keys?: { p256dh?: unknown; auth?: unknown } } }).subscription
  if (typeof sub?.endpoint !== 'string' || typeof sub.keys?.p256dh !== 'string' || typeof sub.keys.auth !== 'string') {
    return reply.code(400).send({ error: 'bad_param', message: 'Iscrizione non valida.' })
  }
  await rpc(reply, 'mb_push_subscribe', {
    p_token: t, p_endpoint: sub.endpoint, p_p256dh: sub.keys.p256dh, p_auth: sub.keys.auth, p_user_agent: req.headers['user-agent'] ?? null,
  })
  if (!reply.sent) return { ok: true }
})

app.post('/api/push/unsubscribe', async (req, reply) => {
  const t = token(req, reply)
  if (!t) return
  const endpoint = ((req.body ?? {}) as { endpoint?: unknown }).endpoint
  if (typeof endpoint !== 'string') return reply.code(400).send({ error: 'bad_param', message: 'Iscrizione non valida.' })
  await rpc(reply, 'mb_push_unsubscribe', { p_token: t, p_endpoint: endpoint })
  if (!reply.sent) return { ok: true }
})

app.get('/api/state', async (req, reply) => {
  const t = token(req, reply)
  if (t) return rpc(reply, 'mb_get_state', { p_token: t })
})

// Cronaca della corsa: solo le notizie già uscite (la funzione non ha accesso a quelle future né agli esiti).
app.get('/api/race', async (req, reply) => {
  const t = token(req, reply)
  if (t) return rpc(reply, 'mb_race_state', { p_token: t })
})

// Classifiche: identiche per tutte le squadre, quindi una sola lettura dal database ogni pochi secondi.
// Con la cache servita solo a chi ha già mostrato un token valido (un UUID qualunque non basta).
const RANKINGS_TTL_MS = 8_000
const KNOWN_TOKEN_TTL_MS = 60_000
let rankings: { at: number; data: unknown } | null = null
const knownTokens = new Map<string, number>()

app.get('/api/rankings', async (req, reply) => {
  const t = token(req, reply)
  if (!t) return
  const now = Date.now()
  if (rankings && now - rankings.at < RANKINGS_TTL_MS && (knownTokens.get(t) ?? 0) > now) return rankings.data
  const { data, error } = await db.rpc('mb_get_rankings', { p_token: t })
  if (error) {
    const e = toApiError(error)
    if (e.status === 500) app.log.error({ fn: 'mb_get_rankings', error }, 'rpc failed')
    return reply.code(e.status).send({ error: e.code, message: e.message })
  }
  rankings = { at: now, data }
  knownTokens.set(t, now + KNOWN_TOKEN_TTL_MS)
  if (knownTokens.size > 500) for (const [k, exp] of knownTokens) if (exp < now) knownTokens.delete(k)
  return data
})

// Schermo della sala (/tv): sola lettura, senza token, uguale per tutti → una lettura ogni pochi secondi.
const TV_TTL_MS = 3_000
let tv: { at: number; data: unknown } | null = null
let tvLoading: Promise<{ data: unknown; error: unknown }> | null = null

app.get('/api/tv', async (_req, reply) => {
  reply.header('cache-control', 'no-store')
  const now = Date.now()
  if (tv && now - tv.at < TV_TTL_MS) return tv.data
  tvLoading ??= Promise.resolve(db.rpc('mb_get_tv')).finally(() => { tvLoading = null })
  const { data, error } = await tvLoading
  if (error) {
    app.log.error({ fn: 'mb_get_tv', error }, 'rpc failed')
    return reply.code(500).send({ error: 'server_error', message: 'Dati non disponibili.' })
  }
  tv = { at: Date.now(), data }
  return data
})

app.post('/api/markets', async (req, reply) => {
  const t = token(req, reply)
  if (!t) return
  const b = (req.body ?? {}) as Record<string, unknown>
  const yes = int(b.yesOdds)
  const no = int(b.noOdds)
  const expires = typeof b.expiresAt === 'string' ? new Date(b.expiresAt) : null
  if (typeof b.question !== 'string' || typeof b.key !== 'string' || b.key.length < 8 || b.key.length > 64)
    return reply.code(400).send({ error: 'invalid_question', message: 'Dati non validi.' })
  if (yes === null || no === null) return reply.code(400).send({ error: 'invalid_odds', message: 'Quote non valide.' })
  if (!expires || isNaN(expires.getTime())) return reply.code(400).send({ error: 'expiry_too_soon', message: 'Scadenza non valida.' })
  return rpc(reply, 'mb_create_market', {
    p_token: t, p_question: b.question, p_yes: yes, p_no: no, p_expires_at: expires.toISOString(), p_key: b.key,
  })
})

app.post<{ Params: { id: string } }>('/api/markets/:id/bets', async (req, reply) => {
  const t = token(req, reply)
  if (!t) return
  const b = (req.body ?? {}) as { side?: unknown; amount?: unknown }
  const amount = int(b.amount)
  if (b.side !== 'yes' && b.side !== 'no') return reply.code(400).send({ error: 'invalid_side', message: 'Lato non valido.' })
  if (amount === null) return reply.code(400).send({ error: 'invalid_amount', message: 'Puntata minima 10 Carletti.' })
  return rpc(reply, 'mb_place_bet', { p_token: t, p_market: Number(req.params.id), p_side: b.side, p_amount: amount })
})

app.post<{ Params: { id: string } }>('/api/markets/:id/resolve', async (req, reply) => {
  const t = token(req, reply)
  if (!t) return
  const b = (req.body ?? {}) as { outcome?: unknown }
  if (b.outcome !== 'yes' && b.outcome !== 'no') return reply.code(400).send({ error: 'invalid_side', message: 'Lato non valido.' })
  return rpc(reply, 'mb_resolve', { p_token: t, p_market: Number(req.params.id), p_outcome: b.outcome })
})

app.post<{ Params: { id: string } }>('/api/markets/:id/appeal', async (req, reply) => {
  const t = token(req, reply)
  if (t) return rpc(reply, 'mb_appeal', { p_token: t, p_market: Number(req.params.id) })
})

app.post('/api/readmit', async (req, reply) => {
  const t = token(req, reply)
  if (t) return rpc(reply, 'mb_readmit', { p_token: t })
})

/* ---------- Banco di Regia ---------- */
// Codice unico in ADMIN_CODE (variabile d'ambiente del server, mai nel repo né nel frontend). Nessuna sessione:
// il browser lo rimanda a ogni richiesta e il controllo avviene qui, ogni volta. Dopo 10 codici sbagliati in un minuto
// lo stesso indirizzo viene fermato per il resto del minuto.
// Il valore di esempio di .env.example e i codici troppo corti non attivano la Regia.
const rawAdminCode = process.env.ADMIN_CODE ?? ''
const ADMIN_CODE = rawAdminCode.length >= 8 && rawAdminCode !== 'metti-qui-un-codice-tuo' ? rawAdminCode : ''
const digest = (v: string) => createHash('sha256').update(v).digest()
const adminFails = new Map<string, { n: number; until: number }>()

function admin(req: FastifyRequest, reply: FastifyReply): boolean {
  if (!ADMIN_CODE) {
    reply.code(503).send({ error: 'admin_disabled', message: 'La Regia non è configurata sul server (manca ADMIN_CODE).' })
    return false
  }
  const now = Date.now()
  const f = adminFails.get(req.ip)
  if (f && f.until > now && f.n >= 10) {
    reply.code(429).send({ error: 'too_many', message: 'Troppi tentativi: riprova tra un minuto.' })
    return false
  }
  const c = req.headers['x-admin-code']
  if (typeof c === 'string' && timingSafeEqual(digest(c), digest(ADMIN_CODE))) {
    adminFails.delete(req.ip)
    return true
  }
  adminFails.set(req.ip, f && f.until > now ? { n: f.n + 1, until: f.until } : { n: 1, until: now + 60_000 })
  if (adminFails.size > 200) for (const [k, v] of adminFails) if (v.until < now) adminFails.delete(k)
  reply.code(401).send({ error: 'wrong_code', message: 'Codice Regia errato.' })
  return false
}

/** Azione di Regia: controlla il codice, poi chiama la funzione SQL (le modifiche ai giocatori si vedono al prossimo polling). */
const adminAct = (path: string, fn: string, args: (req: FastifyRequest) => Record<string, unknown> | null) =>
  app.post(`/api/regia/${path}`, async (req, reply) => {
    if (!admin(req, reply)) return
    const a = args(req)
    if (a === null) return reply.code(400).send({ error: 'bad_param', message: 'Dati non validi.' })
    rankings = null
    tv = null
    return rpc(reply, fn, a)
  })
const body = (req: FastifyRequest) => (req.body ?? {}) as Record<string, unknown>
const marketId = (req: FastifyRequest) => Number((req.params as { id: string }).id)

app.get('/api/regia/state', async (req, reply) => {
  if (admin(req, reply)) return rpc(reply, 'mb_admin_state')
})
app.get('/api/regia/race', async (req, reply) => {
  if (admin(req, reply)) return rpc(reply, 'mb_admin_race_state')
})
adminAct('reset-team', 'mb_admin_reset_team', (r) => { const t = int(body(r).teamId); return t === null ? null : { p_team: t } })
adminAct('reset-all', 'mb_admin_reset_all', (r) => ({
  p_confirm: typeof body(r).confirm === 'string' ? body(r).confirm : null,
  p_restore_bank_start: body(r).restoreBank !== false,
}))
adminAct('param', 'mb_admin_set_param', (r) => {
  const b = body(r)
  return typeof b.key === 'string' && typeof b.value === 'number' && Number.isFinite(b.value) ? { p_key: b.key, p_value: b.value } : null
})
adminAct('bank-start', 'mb_admin_set_bank_start', (r) => {
  const at = typeof body(r).at === 'string' ? new Date(body(r).at as string) : null
  return at && !isNaN(at.getTime()) ? { p_at: at.toISOString() } : null
})
adminAct('tv-message', 'mb_admin_set_tv', (r) => {
  const b = body(r)
  const m = b.minutes === undefined ? 10 : int(b.minutes)
  return typeof b.text === 'string' && m !== null ? { p_text: b.text, p_minutes: m } : null
})
adminAct('bank-now','mb_admin_bank_now', () => ({}))
adminAct('race-start', 'mb_admin_race_start', () => ({}))
adminAct('race-pause', 'mb_admin_race_pause', (r) => (typeof body(r).paused === 'boolean' ? { p_paused: body(r).paused } : null))
adminAct('bank-pause', 'mb_admin_bank_pause', (r) => (typeof body(r).paused === 'boolean' ? { p_paused: body(r).paused } : null))
adminAct('close-session', 'mb_admin_close_session', () => ({}))
adminAct('force-finalize', 'mb_admin_force_finalize', () => ({}))
adminAct('markets/:id/resolve', 'mb_admin_resolve', (r) => {
  const o = body(r).outcome
  return (o === 'yes' || o === 'no') && Number.isInteger(marketId(r)) ? { p_market: marketId(r), p_outcome: o } : null
})
adminAct('markets/:id/void', 'mb_admin_void', (r) => (Number.isInteger(marketId(r)) ? { p_market: marketId(r) } : null))
adminAct('adjust', 'mb_admin_adjust', (r) => {
  const b = body(r)
  const t = int(b.teamId), d = int(b.delta)
  return t === null || d === null || typeof b.reason !== 'string' ? null : { p_team: t, p_delta: d, p_reason: b.reason }
})

// Catalogo editoriale: validato prima del caricamento. Se non valido si tiene quello già nel DB
// (e i testi di riserva): un errore editoriale non blocca mai il gioco.
try {
  const catalog = readCatalog()
  const problems = validateCatalog(catalog)
  if (problems.length) app.log.error({ problems }, 'catalogo NON valido: non caricato')
  else {
    const { data, error } = await db.rpc('mb_load_catalog', { p: catalog })
    if (error) app.log.error({ error }, 'caricamento catalogo fallito')
    else app.log.info({ entries: data }, 'catalogo caricato')
  }
} catch (e) {
  app.log.error({ e }, 'catalogo non leggibile')
}

// La Teramana: i due file vengono controllati e caricati prima di ogni avvio. Se non sono validi si tiene quanto già
// nel database e la corsa non parte (gli errori e le segnalazioni sono nei log); il resto del gioco non si ferma.
// Dopo il via della corsa il database rifiuta ogni cambio alla definizione.
try {
  const { timeline, banco } = readRace()
  const race = buildRace(timeline, banco)
  for (const w of race.warnings) app.log.warn(`corsa: ${w}`)
  if (!race.payload) app.log.error({ problems: race.problems }, 'corsa NON valida: non caricata')
  else {
    const { data, error } = await db.rpc('mb_race_load', { p: race.payload })
    if (error) app.log.error({ error }, 'caricamento corsa fallito')
    else app.log.info({ load: data }, 'corsa caricata')
  }
} catch (e) {
  app.log.error({ e }, 'file della corsa non leggibili')
}

// Frontend compilato (produzione, un'unica istanza dietro Caddy).
const staticDir = resolve(process.env.STATIC_DIR ?? '../web/dist')
if (existsSync(staticDir)) {
  await app.register(fastifyStatic, { root: staticDir })
  app.setNotFoundHandler((req, reply) =>
    req.url.startsWith('/api/') ? reply.code(404).send({ error: 'not_found' }) : reply.sendFile('index.html'))
}

// Worker timer: chiusura mercati e annullamenti dipendono solo dagli orari nel DB (sicuro dopo un riavvio).
const tick = async () => {
  const { error } = await db.rpc('mb_tick')
  if (error) app.log.error({ error }, 'tick failed')
}
setInterval(tick, 5000)
void tick()

// Corsa: un passo al secondo (notizie, aperture, chiusure, liquidazioni). Gli orari stanno nel database, non qui:
// dopo un riavvio il primo passo recupera tutto, e mb_tick lo fa comunque ogni 5 secondi.
const raceLoop = async () => {
  let running = 0
  try {
    const { data, error } = await db.rpc('mb_race_tick')
    if (error) app.log.error({ error }, 'race tick failed')
    else running = Number(data) || 0
  } catch (e) {
    app.log.error({ e }, 'race tick failed')
  }
  setTimeout(raceLoop, running > 0 ? 1000 : 5000)   // a corsa ferma basta un controllo ogni 5 secondi
}
void raceLoop()

// Worker delle notifiche: chi avvisare lo decide il database (orari e stato letti da lì); un errore qui non tocca mai il gioco.
let pushBusy = false
const pushTick = async () => {
  if (pushBusy) return
  pushBusy = true
  try {
    const { data, error } = await db.rpc('mb_push_due', { p_cooldown_sec: PUSH_COOLDOWN })
    if (error) return app.log.error({ error }, 'push_due failed')
    const ok: number[] = []
    const dead: number[] = []
    for (const it of (data ?? []) as PushItem[]) {
      const r = await sendItem(it, (o, m) => app.log.warn(o, m))
      ok.push(...r.ok)
      dead.push(...r.dead)
    }
    if (ok.length || dead.length) await db.rpc('mb_push_mark', { p_ok: ok, p_dead: dead })
  } catch (e) {
    app.log.error({ e }, 'push tick failed')
  } finally {
    pushBusy = false
  }
}
if (PUSH_ON) setInterval(pushTick, 5000)
else app.log.info('Notifiche push spente (PUSH_ENABLED=false o chiavi VAPID mancanti).')

await app.listen({ port: Number(process.env.PORT ?? 3000), host: '0.0.0.0' })
