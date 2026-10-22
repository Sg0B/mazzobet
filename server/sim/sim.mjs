#!/usr/bin/env node
// Simulazione di carico/serata di MazzoBet: N squadre simulate che usano l'API vera come farebbero i telefoni.
//
//   node sim/sim.mjs --teams 24 --sim-minutes 60 --scale 6
//
// Il database deve avere lo stesso fattore di velocità (game_sessions.time_scale = --scale) sulla serata attiva
// e nessuna squadra già entrata. Con scale 6, 60 minuti di serata durano 10 minuti reali.
// Gli agenti decidono in "tempo di serata" (secondi simulati / scale = secondi reali); il polling di /api/state
// resta ogni ~3 secondi reali come nell'app, quindi il carico sul server è prudente (più alto di quello reale).
import { mkdirSync, writeFileSync } from 'node:fs'

const argv = process.argv.slice(2)
const arg = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d }
const BASE = arg('base', 'http://localhost:3000')
const TEAMS = Number(arg('teams', 24))
const SIM_MIN = Number(arg('sim-minutes', 60))
const SCALE = Number(arg('scale', 6))
const SEED = Number(arg('seed', 1))
const REAL_MS = (SIM_MIN * 60_000) / SCALE
const POLL_MS = 3000

// PRNG deterministico: stessa seed → stesse scelte (la concorrenza resta comunque non deterministica).
function mulberry32(a) { return () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296 } }
const rnd = mulberry32(SEED)
const pick = (a) => a[Math.floor(rnd() * a.length)]
const between = (lo, hi) => lo + rnd() * (hi - lo)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
/** Secondi di serata → millisecondi reali. */
const simSec = (s) => (s * 1000) / SCALE

/* ---------- metriche client ---------- */
const lat = {}        // endpoint → [ms]
const codes = {}      // endpoint → { esito → n }
const perSecond = {}  // secondo → n richieste
let stateBytes = []
const bump = (o, k, n = 1) => { o[k] = (o[k] ?? 0) + n }

async function call(name, path, { method, body, token } = {}) {
  const t = performance.now()
  let status = 0, data = null, bytes = 0
  try {
    const r = await fetch(BASE + '/api' + path, {
      method: method ?? (body === undefined ? 'GET' : 'POST'),
      headers: { ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...(token ? { 'x-device-token': token } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    status = r.status
    const text = await r.text()
    bytes = text.length
    try { data = JSON.parse(text) } catch { data = null }
  } catch { status = 0; data = { error: 'network' } }
  const ms = performance.now() - t
  ;(lat[name] ??= []).push(ms)
  codes[name] ??= {}
  bump(codes[name], status >= 200 && status < 300 ? 'ok' : data?.error ?? `http_${status}`)
  bump(perSecond, Math.floor((Date.now() - T0) / 1000))
  if (name === 'state' && status === 200) stateBytes.push(bytes)
  return { status, data, ms }
}

/* ---------- agenti ---------- */
const truths = new Map()   // marketId → 'yes' | 'no' (verità decisa dal simulatore, nota agli agenti)
const stats = { bets: 0, creates: 0, resolves: 0, resolvesWrong: 0, appeals: 0, flips: 0, readmits: 0, allIn: 0 }
const resolveDelays = []   // ms reali tra chiusura mercato e primo esito inviato (visto dall'agente)
let running = true
let T0 = Date.now()

const QUESTIONS = [
  'Qualcuno brinda in piedi entro la prossima ora?', 'Il dolce arriva prima delle 23?', 'Bila fa un discorso entro 20 minuti?',
  'Qualcuno ordina un altro giro di vino?', 'Il primo piatto arriva freddo al tavolo?', 'Si canta una canzone prima del caffè?',
  'Qualcuno si alza per un selfie di gruppo?', 'Il cameriere sbaglia un ordine stasera?', 'Parte un applauso per il cuoco?',
  'Qualcuno chiede il bis di tiramisù?',
]
const PROFILES = ['cauto', 'cauto', 'cauto', 'cauto', 'normale', 'normale', 'normale', 'normale', 'azzardo', 'azzardo']

class Agent {
  constructor(i) {
    this.teamId = i + 1
    this.profile = PROFILES[i % PROFILES.length]
    this.token = null
    this.st = null
    this.stAt = 0
    this.respondedAt = new Map()
  }
  /** Chiamata autenticata col token del dispositivo di questa squadra. */
  call(name, path, opts = {}) { return call(name, path, { ...opts, token: this.token }) }
  /** "Adesso" secondo il server, stimato dall'ultimo stato. */
  now() { return this.st ? Date.parse(this.st.now) + (Date.now() - this.stAt) : Date.now() }
  async enter() {
    const r = await call('enter', '/enter', { body: { teamId: this.teamId } })
    if (r.status === 200) this.token = r.data.token
  }
  async poll() {
    while (running) {
      if (this.token) {
        const r = await this.call('state', '/state')
        if (r.status === 200) { this.st = r.data; this.stAt = Date.now() }
      }
      await sleep(POLL_MS * (0.8 + rnd() * 0.4))
    }
  }
  async act() {
    while (running) {
      await sleep(simSec(between(30, 90)))
      if (!this.st || !running) continue
      try { await this.decide() } catch { /* un errore di rete non ferma l'agente */ }
    }
  }
  async decide() {
    const st = this.st, me = st.me, now = this.now()
    const myId = me.teamId

    // 1. esiti: il creatore risponde quasi sempre; gli altri non scommettitori ogni tanto («la prima risposta vale»)
    for (const m of st.markets.filter((x) => x.status === 'closed' && !x.outcome)) {
      const mine = m.byTeamId === myId
      if (!mine && m.my) continue
      if (!mine && m.creatorOnlyUntil && Date.parse(m.creatorOnlyUntil) > now) continue   // precedenza del creatore
      if (!this.respondedAt.has(m.id)) this.respondedAt.set(m.id, Date.now())
      if (rnd() < (mine ? 0.9 : 0.12)) {
        const truth = truths.get(m.id) ?? pick(['yes', 'no'])
        const wrong = rnd() < 0.05
        const outcome = wrong ? (truth === 'yes' ? 'no' : 'yes') : truth
        const r = await this.call('resolve', `/markets/${m.id}/resolve`, { body: { outcome } })
        if (r.status === 200) {
          stats.resolves++
          if (wrong) stats.resolvesWrong++
          resolveDelays.push(Math.max(0, now - Date.parse(m.expiresAt)) / SCALE)  // secondi di serata dopo la scadenza, in ms «reali»
        }
      }
    }

    // 2. ricorsi: chi ha puntato contesta un esito sbagliato; qualcuno anche se ha solo perso
    for (const m of st.markets.filter((x) => x.status === 'resolved' && x.my && !x.my.appealed && !x.flipped && Date.parse(x.appealUntil) > now)) {
      const truth = truths.get(m.id)
      const wrong = truth && m.outcome !== truth
      const p = wrong ? 0.7 : m.my.result === 'loss' ? 0.04 : 0
      if (rnd() < p) {
        const r = await this.call('appeal', `/markets/${m.id}/appeal`, { body: {} })
        if (r.status === 200) { stats.appeals++; if (r.data.flipped) stats.flips++ }
      }
    }

    // 3. riammissione appena finito il blocco
    if (me.status === 'bankrupt' && me.bankruptUntil && Date.parse(me.bankruptUntil) <= now) {
      const r = await this.call('readmit', '/readmit', { body: {} })
      if (r.status === 200) stats.readmits++
    }
    if (me.status !== 'in_game' || st.session.status !== 'active') return

    // 4. creazione mercato
    if (me.balance >= 100 && rnd() < 0.05) {
      const dur = pick([20, 20, 20, 30, 30, 60]) // minuti di serata («live 20», +30, +1h)
      const expiresAt = now + (dur * 60_000) / SCALE
      if (expiresAt < Date.parse(st.session.endsAt)) {
        const yes = Math.round((1.15 + rnd() * 3.5) * 100), no = Math.round((1.15 + rnd() * 3.0) * 100)
        const r = await this.call('create', '/markets', { body: { question: pick(QUESTIONS), yesOdds: yes, noOdds: no, expiresAt: new Date(expiresAt).toISOString(), key: crypto.randomUUID() } })
        if (r.status === 200) {
          stats.creates++
          const pYes = 1 / yes / (1 / yes + 1 / no)
          truths.set(r.data.marketId, rnd() < pYes ? 'yes' : 'no')
        }
      }
    }

    // 5. puntata
    if (me.balance >= 10 && rnd() < 0.35) {
      const open = st.markets.filter((x) => x.status === 'open' && x.byTeamId !== myId && !x.my && Date.parse(x.expiresAt) > now + 3000)
      if (open.length) {
        const m = pick(open)
        const side = rnd() < 0.5 + (m.yesOdds < m.noOdds ? 0.1 : -0.1) ? 'yes' : 'no'
        let amount
        if (this.profile === 'cauto') amount = pick([10, 20, 25, 50])
        else if (this.profile === 'normale') amount = pick([25, 50, 100, 150, 250])
        else amount = rnd() < 0.5 ? me.balance : pick([100, 250, 500])
        amount = Math.max(10, Math.min(amount, me.balance))
        if (amount === me.balance) stats.allIn++
        const r = await this.call('bet', `/markets/${m.id}/bets`, { body: { side, amount } })
        if (r.status === 200) stats.bets++
      }
    }
  }
}

/* ---------- esecuzione ---------- */
const pct = (a, p) => { if (!a?.length) return null; const s = [...a].sort((x, y) => x - y); return Math.round(s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] * 10) / 10 }

async function main() {
  const teams = await call('teams', '/teams')
  if (teams.status !== 200) throw new Error('server non raggiungibile su ' + BASE)
  if (teams.data.some((t) => t.entered)) throw new Error('la serata attiva ha già squadre entrate: apri una serata pulita')
  console.log(`Simulazione: ${TEAMS} squadre, ${SIM_MIN} min di serata a scala ${SCALE} → ${(REAL_MS / 60000).toFixed(1)} min reali. Seed ${SEED}.`)

  T0 = Date.now()
  const startedAt = new Date().toISOString()
  const agents = Array.from({ length: TEAMS }, (_, i) => new Agent(i))
  const loops = []
  // ingressi scaglionati nei primi 3 minuti di serata (il Banco parte alla quinta squadra)
  for (const [i, a] of agents.entries()) {
    loops.push((async () => {
      await sleep(simSec((i / TEAMS) * 180))
      await a.enter()
      if (!a.token) return
      a.poll()
      await a.act()
    })())
  }

  const timer = setInterval(() => {
    const el = (Date.now() - T0) / 1000
    process.stdout.write(`\r  ${Math.floor(el / 60)}:${String(Math.floor(el % 60)).padStart(2, '0')} reali · serata ${Math.round(el * SCALE / 60)} min · puntate ${stats.bets} · mercati ${stats.creates} · esiti ${stats.resolves} · ricorsi ${stats.appeals}   `)
  }, 2000)

  await sleep(REAL_MS)
  running = false
  clearInterval(timer)
  await sleep(1500)
  const endedAt = new Date().toISOString()
  console.log('\nFine simulazione.')

  const summary = {
    config: { base: BASE, teams: TEAMS, simMinutes: SIM_MIN, scale: SCALE, realMinutes: REAL_MS / 60000, seed: SEED, pollMs: POLL_MS },
    startedAt, endedAt,
    actions: stats,
    profiles: Object.fromEntries(['cauto', 'normale', 'azzardo'].map((p) => [p, agents.filter((a) => a.profile === p).length])),
    agentsEntered: agents.filter((a) => a.token).length,
    latencyMs: Object.fromEntries(Object.entries(lat).map(([k, v]) => [k, { n: v.length, p50: pct(v, 50), p95: pct(v, 95), p99: pct(v, 99), max: pct(v, 100) }])),
    outcomes: codes,
    requests: { total: Object.values(lat).reduce((a, v) => a + v.length, 0), peakPerSecond: Math.max(...Object.values(perSecond)), avgPerSecond: Math.round((Object.values(lat).reduce((a, v) => a + v.length, 0) / (REAL_MS / 1000)) * 10) / 10 },
    stateBytes: { n: stateBytes.length, p50: pct(stateBytes, 50), max: pct(stateBytes, 100) },
    resolveDelaySimSeconds: { n: resolveDelays.length, p50: Math.round(((pct(resolveDelays, 50) ?? 0) / 1000) * SCALE), p95: Math.round(((pct(resolveDelays, 95) ?? 0) / 1000) * SCALE) },
    finalBalances: agents.filter((a) => a.st).map((a) => ({ team: a.st.me.name, profile: a.profile, balance: a.st.me.balance, status: a.st.me.status })),
  }
  mkdirSync(new URL('./out/', import.meta.url), { recursive: true })
  const file = new URL(`./out/sim-${startedAt.replace(/[:.]/g, '-')}.json`, import.meta.url)
  writeFileSync(file, JSON.stringify(summary, null, 2))
  console.log('Risultati client salvati in', file.pathname.replace(/^\//, ''))
  console.log(JSON.stringify({ actions: summary.actions, requests: summary.requests, latencyMs: summary.latencyMs, outcomes: summary.outcomes }, null, 2))
}

main().catch((e) => { console.error('\nERRORE:', e.message); process.exit(1) })
