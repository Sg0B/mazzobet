/**
 * Store collegato al server. Il server è autoritativo (saldo, quote, puntate, esiti, orari):
 * qui si tiene solo una copia dello stato, aggiornata a polling e dopo ogni azione.
 * Notizie RadioCorsa e Banco sono ancora di esempio (fase successiva).
 */
import { useSyncExternalStore } from 'react'
import { ApiError, api, getToken, setToken } from '../lib/api'
import { cur } from '../lib/format'

export type Side = 'yes' | 'no'
/** open = puntate aperte · closed = da esitare · done = esitata · void = annullata · empty = chiusa senza puntate */
export type MarketStatus = 'open' | 'closed' | 'done' | 'void' | 'empty'

/** Parametri di gioco: arrivano dal server (tabella di configurazione); questi sono solo valori di partenza. */
export interface Config {
  betMin: number
  createFee: number
  oddsMin: number
  oddsMax: number
  feePct: number
  feeCap: number
  feeOtherPct: number
  creatorPriorityMin: number
  resolveWindowMin: number
  appealMin: number
  bankruptThreshold: number
  readmitBalance: number
}
const DEFAULT_CONFIG: Config = {
  betMin: 10, createFee: 100, oddsMin: 110, oddsMax: 1000, feePct: 10, feeCap: 250, feeOtherPct: 50,
  creatorPriorityMin: 2, resolveWindowMin: 15, appealMin: 3, bankruptThreshold: 10, readmitBalance: 500,
}

export interface Bet {
  side: Side
  amount: number
  result?: 'win' | 'loss' | 'void'
  payout?: number
  appealed?: boolean
}

export interface Market {
  id: number // id interno, usato dall'API
  num: number // numero mostrato («Scommessa n. 44»)
  text: string
  by: string
  yes: number // quota SÌ in centesimi
  no: number // quota NO in centesimi
  createdAt: number
  expiresAt: number
  yesPool: number
  noPool: number
  status: MarketStatus
  resolveBy?: number
  /** Fino a qui può esitare solo il creatore. */
  creatorOnlyUntil?: number
  outcome?: Side
  flipped: boolean
  appealUntil?: number
  /** Compenso se esita il creatore / se esita un altro (calcolato sul totale puntato). */
  feeCreator: number
  feeOther: number
  /** Compenso fissato all'esito, chi lo incassa e se è già stato pagato. */
  feeAmount: number
  feeTeamId?: number
  feePaid: boolean
  /** Esitata dalla Regia: definitiva, senza contestazione. */
  byAdmin: boolean
  my: Bet | null
  /** Scommessa della corsa simulata (nessun creatore): orari in secondi di gara. */
  race?: { id: string; opensAt: number; closesAt: number; awaiting: boolean }
}

/** Orologio di gara ricevuto dal server; il tempo corrente si ricalcola con raceElapsed(). */
export interface RaceClock {
  loaded: boolean
  name: string
  edition: number
  distanceKm: number
  durationSeconds: number
  status: 'not_started' | 'running' | 'paused' | 'finished' | 'aborted'
  elapsed: number
  /** 1 = tempo reale; più di 1 = prova accelerata (la Regia ha scelto una durata più breve di 180 minuti). */
  speed: number
  /** Ora del server (ms) a cui si riferisce elapsed. */
  at: number
}
export interface RaceEvent {
  id: string
  at: number
  km: number
  kmEvent: boolean
  kmApprox: boolean
  type: string
  text: string
}

/** Secondi di gara adesso (si ferma in pausa, a fine corsa e se interrotta). */
export const raceElapsed = (c: RaceClock | null, now = serverNow()) =>
  !c || !c.loaded ? 0 : c.status === 'running' ? Math.min(c.durationSeconds, c.elapsed + (Math.max(0, now - c.at) / 1000) * (c.speed || 1)) : c.elapsed

export type NewsKind = 'bonus' | 'malus' | 'giuria' | 'bank' | 'sponsor'
export interface News {
  id: number
  at: number
  kind: NewsKind
  title: string
  text: string
}

export type LedgerKind = 'start' | 'create' | 'bet' | 'win' | 'refund' | 'bonus' | 'malus' | 'colletta' | 'sponsor' | 'adjust' | 'fee' | 'reamm' | 'other'
export interface LedgerEntry {
  id: number
  at: number
  kind: LedgerKind
  label: string
  amount: number
}

export interface LeaderRow {
  teamId: number
  name: string
  balance: number
  correct: number
  bankruptcies: number
  readmissions: number
}

/** Righe delle classifiche calcolate dal server (posizioni già assegnate, parità comprese). */
export interface RankRow { teamId: number; name: string; pos: number | null }
export interface Rankings {
  minEsitate: number
  patrimonio: (RankRow & { value: number; balance: number })[]
  pronostici: (RankRow & { won: number; done: number; pct: number | null })[]
  striscia: (RankRow & { best: number; cur: number })[]
  puntate: (RankRow & { value: number })[]
  bancarotte: (RankRow & { value: number })[]
}

export interface TeamInfo {
  id: number
  name: string
  entered: boolean
  hasPin: boolean
  /** Secondi di blocco rimasti (5 PIN sbagliati di fila), 0 se libera. */
  lockedSecs: number
}

export interface GameState {
  /** Orologio allineato al server (countdown corretti anche con l'ora del telefono sbagliata). */
  now: number
  ready: boolean
  team: string | null
  teamId: number | null
  config: Config
  tab: 'home' | 'rank' | 'bets' | 'radio' | 'race'
  balance: number
  bankruptUntil: number | null
  readmissions: number
  correct: number
  endsAt: number | null
  /** 'closing' = niente nuove puntate/creazioni; 'closed' = sola lettura, classifica congelata. */
  sessionStatus: 'active' | 'paused' | 'closing' | 'closed'
  markets: Market[]
  news: News[]
  ledger: LedgerEntry[]
  leaderboard: LeaderRow[]
  rankings: Rankings | null
  /** Orologio della corsa simulata (arriva con lo stato) e cronaca (si chiede solo nella pagina Corsa). */
  race: RaceClock | null
  raceFeed: RaceEvent[]
  bankCash: number
  bankInPlay: number
  toast: string | null
}

export type Result = { ok: true } | { ok: false; error: string; lockedSecs?: number }
const ok: Result = { ok: true }
const fail = (e: unknown): Result => ({
  ok: false,
  error: e instanceof ApiError ? e.message : 'Errore. Riprova.',
})

let state: GameState = {
  now: Date.now(),
  ready: false,
  team: null,
  teamId: null,
  config: DEFAULT_CONFIG,
  tab: 'home',
  balance: 0,
  bankruptUntil: null,
  readmissions: 0,
  correct: 0,
  endsAt: null,
  sessionStatus: 'active',
  markets: [],
  news: [],
  ledger: [],
  leaderboard: [],
  rankings: null,
  race: null,
  raceFeed: [],
  bankCash: 0,
  bankInPlay: 0,
  toast: null,
}

const listeners = new Set<() => void>()
function set(patch: Partial<GameState>) {
  state = { ...state, ...patch }
  listeners.forEach((l) => l())
}

export const useGame = () =>
  useSyncExternalStore(
    (cb) => {
      listeners.add(cb)
      return () => listeners.delete(cb)
    },
    () => state,
  )

/* ---------- derivati ---------- */

export const isMine = (m: Market) => m.by === state.team
export const committed = (s: GameState) =>
  s.markets.filter((m) => m.my && (m.status === 'open' || m.status === 'closed')).reduce((a, m) => a + m.my!.amount, 0)
/** Scommesse da esitare in cui posso rispondere: non ho puntato, e la precedenza del creatore è finita. */
export const toResolve = (s: GameState) =>
  s.markets.filter((m) => !m.race && m.status === 'closed' && !m.outcome && !m.my && m.by !== s.team && (m.creatorOnlyUntil ?? 0) <= s.now)
/** Obbligo bloccante: mie scommesse (con puntate) scadute e non ancora esitate. */
export const mustResolve = (s: GameState) => s.markets.filter((m) => m.by === s.team && m.status === 'closed' && !m.outcome)

/* ---------- server clock ---------- */

let clockOffset = 0
/** Ora del server (ms). */
export const serverNow = () => Date.now() + clockOffset

let toastTimer: ReturnType<typeof setTimeout> | undefined
export function toast(text: string) {
  set({ toast: text })
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => set({ toast: null }), 2600)
}

/* ---------- mapping dal server ---------- */

interface ServerMarket {
  id: number
  no: number
  question: string
  by: string | null
  raceId: string | null
  awaiting: boolean
  opensAt: number | null
  closesAt: number | null
  yesOdds: number
  noOdds: number
  createdAt: string
  expiresAt: string
  status: 'open' | 'closed' | 'resolved' | 'void' | 'empty'
  resolveBy: string | null
  creatorOnlyUntil: string | null
  outcome: Side | null
  flipped: boolean
  appealUntil: string | null
  yesPool: number
  noPool: number
  feeCreator: number
  feeOther: number
  feeAmount: number
  feeTeamId: number | null
  feePaid: boolean
  byAdmin: boolean
  my: { side: Side; amount: number; result: Bet['result'] | null; payout: number | null; appealed: boolean } | null
}
interface ServerState {
  now: string
  session: { endsAt: string; status: GameState['sessionStatus'] }
  config: Config
  me: { teamId: number; name: string; balance: number; status: string; bankruptUntil: string | null; readmissions: number; correct: number }
  markets: ServerMarket[]
  race: Omit<RaceClock, 'at'>
  ledger: { id: number; at: string; kind: string; marketNo: number | null; amount: number }[]
  news: { id: number; at: string; kind: NewsKind; title: string; text: string }[]
  leaderboard: LeaderRow[]
  bank: { cash: number; inPlay: number }
}

const ts = (v: string | null) => (v ? new Date(v).getTime() : undefined)

const LEDGER_KIND: Record<string, LedgerKind> = {
  start: 'start', create: 'create', bet: 'bet', win: 'win', refund: 'refund', readmit: 'reamm',
  bonus: 'bonus', malus: 'malus', colletta: 'colletta', sponsor_rain: 'sponsor', appeal_adjust: 'adjust', rettifica: 'adjust', esito_compenso: 'fee',
}
function ledgerLabel(kind: string, no: number | null) {
  const n = no !== null ? ` n. ${no}` : ''
  switch (kind) {
    case 'start': return 'Ingresso in gara'
    case 'create': return `Pubblicazione scommessa${n}`
    case 'bet': return `Puntata su${n}`
    case 'win': return `Vincita scommessa${n}`
    case 'refund': return `Rimborso scommessa${n}`
    case 'readmit': return 'Riammissione, debito azzerato'
    case 'bonus': return 'Bonus del Banco'
    case 'malus': return 'Malus del Banco'
    case 'colletta': return 'Colletta per il gregario caduto'
    case 'sponsor_rain': return 'Pioggia di Carletti dello sponsor'
    case 'appeal_adjust': return `Rettifica per ricorso, scommessa${n}`
    case 'rettifica': return `Rettifica della Regia`
    case 'esito_compenso': return `Compenso per l'esito, scommessa${n}`
    default: return kind
  }
}

function mapMarket(m: ServerMarket): Market {
  return {
    id: m.id,
    num: m.no,
    text: m.question,
    by: m.by ?? 'La Teramana',
    race: m.raceId ? { id: m.raceId, opensAt: Number(m.opensAt), closesAt: Number(m.closesAt), awaiting: !!m.awaiting } : undefined,
    yes: m.yesOdds,
    no: m.noOdds,
    createdAt: new Date(m.createdAt).getTime(),
    expiresAt: new Date(m.expiresAt).getTime(),
    yesPool: Number(m.yesPool),
    noPool: Number(m.noPool),
    status: m.status === 'resolved' ? 'done' : m.status,
    resolveBy: ts(m.resolveBy),
    creatorOnlyUntil: ts(m.creatorOnlyUntil),
    outcome: m.outcome ?? undefined,
    flipped: m.flipped,
    appealUntil: ts(m.appealUntil),
    feeCreator: Number(m.feeCreator),
    feeOther: Number(m.feeOther),
    feeAmount: Number(m.feeAmount),
    feeTeamId: m.feeTeamId ?? undefined,
    feePaid: m.feePaid,
    byAdmin: !!m.byAdmin,
    my: m.my ? { side: m.my.side, amount: Number(m.my.amount), result: m.my.result ?? undefined, payout: m.my.payout === null ? undefined : Number(m.my.payout), appealed: m.my.appealed } : null,
  }
}

/** Toast per ciò che cambia senza un'azione mia (rimborsi, esiti di altri). */
function announceChanges(prev: Market[], next: Market[]) {
  for (const m of next) {
    const before = prev.find((p) => p.id === m.id)
    if (!before || !m.my || before.status === m.status) continue
    const label = m.race ? `Corsa, scommessa ${m.race.id}` : `Scommessa n. ${m.num}`
    if (m.status === 'void') toast(`${label} annullata: puntata rimborsata`)
    else if (m.status === 'done' && before.status !== 'done') toast(m.my.result === 'win' ? `${label} vinta: +${cur(m.my.payout ?? 0)}` : `${label} persa`)
  }
}

/** Notifica live non bloccante per le nuove notizie RadioCorsa (resta comunque nel feed). */
function announceNews(prev: News[], next: News[]) {
  const seen = new Set(prev.map((n) => n.id))
  const fresh = next.filter((n) => !seen.has(n.id))
  if (fresh.length) toast(fresh[0].title)
}

let refreshing = false
export async function refresh() {
  if (refreshing || !getToken()) return
  refreshing = true
  try {
    const s = await api<ServerState>('/state')
    clockOffset = new Date(s.now).getTime() - Date.now()
    const markets = s.markets.map(mapMarket)
    const news = s.news.map((n) => ({ id: n.id, at: new Date(n.at).getTime(), kind: n.kind, title: n.title, text: n.text }))
    if (state.ready && state.team) {
      announceChanges(state.markets, markets)
      announceNews(state.news, news)
    }
    set({
      news,
      ready: true,
      now: serverNow(),
      team: s.me.name,
      teamId: s.me.teamId,
      config: { ...DEFAULT_CONFIG, ...s.config },
      balance: Number(s.me.balance),
      bankruptUntil: s.me.status === 'bankrupt' && s.me.bankruptUntil ? new Date(s.me.bankruptUntil).getTime() : null,
      readmissions: s.me.readmissions,
      correct: s.me.correct,
      endsAt: new Date(s.session.endsAt).getTime(),
      sessionStatus: s.session.status,
      markets,
      race: s.race.loaded ? { ...s.race, at: serverNow() } : null,
      ledger: s.ledger.map((l) => ({ id: l.id, at: new Date(l.at).getTime(), kind: LEDGER_KIND[l.kind] ?? 'banco', label: ledgerLabel(l.kind, l.marketNo), amount: Number(l.amount) })),
      leaderboard: s.leaderboard.map((r) => ({ ...r, balance: Number(r.balance) })),
      bankCash: Number(s.bank.cash),
      bankInPlay: Number(s.bank.inPlay),
    })
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) {
      setToken(null)
      set({ ready: true, team: null })
    } else if (!state.ready) set({ ready: true })
  } finally {
    refreshing = false
  }
}

/** Classifiche complete: si chiedono solo mentre il tab è aperto (il server le tiene in cache pochi secondi). */
let loadingRankings = false
export async function loadRankings() {
  if (loadingRankings || !getToken()) return
  loadingRankings = true
  try {
    set({ rankings: await api<Rankings>('/rankings') })
  } catch {
    /* resta l'ultima versione ricevuta */
  } finally {
    loadingRankings = false
  }
}

/** Cronaca della corsa: si chiede solo mentre la pagina Corsa è aperta. */
let loadingRace = false
export async function loadRace() {
  if (loadingRace || !getToken()) return
  loadingRace = true
  try {
    const r = await api<{ loaded: boolean; now: string; feed?: RaceEvent[] } & Omit<RaceClock, 'at' | 'loaded'>>('/race')
    set({
      raceFeed: r.feed ?? [],
      race: r.loaded ? { loaded: true, name: r.name, edition: r.edition, distanceKm: Number(r.distanceKm), durationSeconds: r.durationSeconds, status: r.status, elapsed: r.elapsed, speed: Number(r.speed) || 1, at: new Date(r.now).getTime() } : null,
    })
  } catch {
    /* resta l'ultima versione ricevuta */
  } finally {
    loadingRace = false
  }
}

/** Esegue un'azione sul server e aggiorna lo stato; ritorna l'esito per la UI. */
async function run(fn: () => Promise<unknown>, success?: string): Promise<Result> {
  try {
    await fn()
    await refresh()
    if (success) toast(success)
    return ok
  } catch (e) {
    await refresh()
    return fail(e)
  }
}

/* ---------- azioni ---------- */

export const actions = {
  async listTeams() {
    return api<TeamInfo[]>('/teams')
  },

  async enterTeam(teamId: number, pin?: string): Promise<Result> {
    try {
      const r = await api<{ token: string }>('/enter', { body: { teamId, token: getToken(), pin } })
      setToken(r.token)
      set({ tab: 'home' })
      await refresh()
      return ok
    } catch (e) {
      const r = fail(e)
      if (e instanceof ApiError && e.code === 'pin_locked' && !r.ok) r.lockedSecs = Number(e.lockedSecs) || 60
      return r
    }
  },

  /** Una squadra entrata prima dei PIN non ne ha uno: il telefono riconosciuto può impostarlo. */
  async needsPin(teamId: number): Promise<boolean> {
    try {
      return !(await api<{ hasPin: boolean }>(`/pin?teamId=${teamId}`)).hasPin
    } catch {
      return false
    }
  },

  async setOwnPin(teamId: number, pin: string): Promise<Result> {
    try {
      await api('/pin', { body: { teamId, pin } })
      return ok
    } catch (e) {
      return fail(e)
    }
  },

  leaveTeam() {
    setToken(null)
    set({ team: null, teamId: null, markets: [], ledger: [], leaderboard: [], rankings: null, race: null, raceFeed: [], balance: 0, bankruptUntil: null })
  },

  setTab(tab: GameState['tab']) {
    set({ tab })
    window.scrollTo(0, 0)
  },

  placeBet(marketId: number, side: Side, amount: number): Promise<Result> {
    return run(() => api(`/markets/${marketId}/bets`, { body: { side, amount } }), `Puntata confermata: ${cur(amount)} su ${side === 'yes' ? 'SÌ' : 'NO'}`)
  },

  /** `key` identifica il tentativo: un retry con la stessa chiave non crea due mercati né due addebiti. */
  createMarket(input: { text: string; yes: number; no: number; expiresAt: number; key: string }): Promise<Result> {
    return run(
      async () => {
        await api('/markets', { body: { question: input.text, yesOdds: input.yes, noOdds: input.no, expiresAt: new Date(input.expiresAt).toISOString(), key: input.key } })
        set({ tab: 'home' })
        window.scrollTo(0, 0)
      },
      'Scommessa pubblicata',
    )
  },

  /**
   * Esito da creatore o da squadra che non ha puntato. Se la scommessa è ancora aperta (solo il creatore)
   * è «ESITA ORA»: chiude subito le puntate, registra l'esito e apre la contestazione.
   */
  async resolve(marketId: number, outcome: Side) {
    const r = await run(() => api(`/markets/${marketId}/resolve`, { body: { outcome } }))
    toast(r.ok ? `Esito registrato. Contestazione aperta per ${state.config.appealMin} minuti.` : r.error)
  },

  /** Contesta l'esito (solo chi ha puntato). Soglia e contatore non sono mai mostrati. */
  async appeal(marketId: number) {
    const r = await run(() => api(`/markets/${marketId}/appeal`, { body: {} }))
    toast(r.ok ? 'Ricorso registrato.' : r.error)
  },

  async readmit() {
    const r = await run(() => api('/readmit', { body: {} }), `Sei di nuovo in gara con ${cur(state.config.readmitBalance)}`)
    if (!r.ok) toast(r.error)
  },
}

/* ---------- boot + tick ---------- */

if (getToken()) void refresh()
else set({ ready: true })

setInterval(() => set({ now: serverNow() }), 1000)
setInterval(() => void refresh(), 3000)
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) void refresh()
})
