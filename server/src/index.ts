import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import rateLimit from '@fastify/rate-limit'
import fastifyStatic from '@fastify/static'
import { createClient } from '@supabase/supabase-js'
import { toApiError } from './errors.js'
import { readCatalog, validateCatalog } from './catalog.js'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!url || !key) {
  console.error('Mancano SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY (vedi server/.env.example).')
  process.exit(1)
}

// Chiave privilegiata solo qui: il browser non vede mai il database.
const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })

const app = Fastify({ logger: true })
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
  const b = (req.body ?? {}) as { teamId?: unknown; token?: unknown }
  const teamId = int(b.teamId)
  if (teamId === null) return reply.code(400).send({ error: 'unknown_team', message: 'Squadra sconosciuta.' })
  const prev = typeof b.token === 'string' && UUID.test(b.token) ? b.token : null
  return rpc(reply, 'mb_enter_team', { p_team: teamId, p_token: prev, p_user_agent: req.headers['user-agent'] ?? null })
})

app.get('/api/state', async (req, reply) => {
  const t = token(req, reply)
  if (t) return rpc(reply, 'mb_get_state', { p_token: t })
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

await app.listen({ port: Number(process.env.PORT ?? 3000), host: '0.0.0.0' })
