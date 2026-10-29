import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

/** Definizione della corsa pronta per il database (quote in centesimi, esiti yes/no). Gli esiti restano solo lato server. */
export interface RacePayload {
  race: { race_id: string; name: string; edition: number; distance_km: number; duration_seconds: number }
  events: {
    id: string; seq: number; at_seconds: number; km: number; km_is_event_location: boolean; km_approximate: boolean
    block: number | null; type: string; text: string; is_puncture: boolean
  }[]
  markets: {
    id: string; seq: number; category: string | null; question: string; opens_at: number; closes_at: number
    yes_odds: number; no_odds: number; winning: 'yes' | 'no'; settlement: Record<string, unknown>
  }[]
}

type Obj = Record<string, unknown>
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v)
const ans = (v: unknown): 'yes' | 'no' | null => (v === 'SÌ' || v === 'SI' ? 'yes' : v === 'NO' ? 'no' : null)

/**
 * Controlla i due file e prepara la definizione. `problems` blocca il caricamento; `warnings` no (sono segnalazioni
 * da leggere: per esempio B07 chiude 15 secondi prima dell'evento invece di 30).
 * Non corregge mai nulla da solo.
 */
export function buildRace(timeline: unknown, banco: unknown): { payload: RacePayload | null; problems: string[]; warnings: string[] } {
  const problems: string[] = []
  const warnings: string[] = []
  if (!isObj(timeline) || !isObj(timeline.race) || !Array.isArray(timeline.events)) return { payload: null, problems: ['timeline: forma non valida'], warnings }
  if (!isObj(banco) || !Array.isArray(banco.markets)) return { payload: null, problems: ['banco: forma non valida'], warnings }

  const r = timeline.race
  const raceId = String(r.race_id ?? '')
  const duration = Number(r.duration_seconds)
  if (!raceId || raceId !== banco.race_id) problems.push(`race_id diverso tra i file (${raceId} / ${String(banco.race_id)})`)
  if (!Number.isInteger(duration) || duration <= 0) problems.push('durata della corsa non valida')

  const events: RacePayload['events'] = []
  const byId = new Map<string, RacePayload['events'][number]>()
  let prev = -1
  ;(timeline.events as unknown[]).forEach((raw, i) => {
    if (!isObj(raw)) { problems.push(`evento ${i + 1}: non è un oggetto`); return }
    const id = String(raw.id ?? '')
    const at = Number(raw.at_seconds)
    const km = Number(raw.km)
    if (!/^PCS\d{3}$/.test(id)) problems.push(`evento ${i + 1}: id non valido (${id})`)
    if (byId.has(id)) problems.push(`id duplicato: ${id}`)
    if (!Number.isInteger(at) || at < 0 || at > duration) problems.push(`${id}: orario fuori dalla corsa`)
    if (at < prev) problems.push(`${id}: non è in ordine di tempo`)
    if (!Number.isFinite(km)) problems.push(`${id}: km non valido`)
    if (typeof raw.text !== 'string' || !raw.text.trim()) problems.push(`${id}: testo vuoto`)
    if (typeof raw.type !== 'string' || !raw.type) problems.push(`${id}: tipo mancante`)
    prev = at
    const ev = {
      id, seq: i + 1, at_seconds: at, km, km_is_event_location: raw.km_is_event_location === true,
      km_approximate: raw.km_approximate === true, block: Number.isInteger(raw.block) ? (raw.block as number) : null,
      type: String(raw.type ?? ''), text: String(raw.text ?? ''),
      // foratura: ricavata qui, una volta, dal tipo e dall'inizio del testo; poi confrontata con l'ID dichiarato dal palinsesto
      is_puncture: raw.type === 'INCIDENT' && /^foratura/i.test(String(raw.text ?? '')),
    }
    events.push(ev)
    byId.set(id, ev)
  })
  if (events.length === 0) problems.push('nessuna notizia')

  const markets: RacePayload['markets'] = []
  const seen = new Set<string>()
  ;(banco.markets as unknown[]).forEach((raw, i) => {
    if (!isObj(raw)) { problems.push(`mercato ${i + 1}: non è un oggetto`); return }
    const id = String(raw.id ?? '')
    if (!/^B\d{2}$/.test(id)) problems.push(`mercato ${i + 1}: id non valido (${id})`)
    if (seen.has(id)) problems.push(`mercato duplicato: ${id}`)
    seen.add(id)
    const q = typeof raw.question === 'string' ? raw.question.trim() : ''
    if (q.length < 8 || q.length > 120) problems.push(`${id}: domanda da 8 a 120 caratteri`)
    const opens = Number(raw.opens_at_seconds)
    const closes = Number(raw.closes_at_seconds)
    if (!Number.isInteger(opens) || opens < 0) problems.push(`${id}: apertura non valida`)
    if (!Number.isInteger(closes) || closes <= opens || closes > duration) problems.push(`${id}: chiusura non valida`)
    const odds = isObj(raw.odds) ? raw.odds : {}
    const cents = (v: unknown, side: string) => {
      const n = Number(v)
      const c = Math.round(n * 100)
      if (!Number.isFinite(n) || Math.abs(n * 100 - c) > 1e-6 || c < 110 || c > 1000) problems.push(`${id}: quota ${side} non valida (${String(v)})`)
      return c
    }
    const yes = cents(odds.SI, 'SÌ')
    const no = cents(odds.NO, 'NO')
    const win = ans(raw.winning_answer)
    if (!win) problems.push(`${id}: esito vincente non valido`)
    const st = isObj(raw.settlement) ? raw.settlement : {}
    const need = (key: string): { id: string; at: number } | null => {
      const eid = String(st[key] ?? '')
      const ev = byId.get(eid)
      if (!ev) { problems.push(`${id}: ${key} ${eid || '(mancante)'} non esiste nella timeline`); return null }
      return { id: eid, at: ev.at_seconds }
    }
    const lead = (label: string, at: number) => {
      if (at < closes) problems.push(`${id}: ${label} arriva prima della chiusura`)
      else if (at - closes < 30) warnings.push(`${id}: chiude ${at - closes} secondi prima di ${label} (la regola generale è 30)`)
      if (st.at_seconds !== undefined && Number(st.at_seconds) !== at && label !== 'la foratura') {
        problems.push(`${id}: at_seconds del palinsesto (${String(st.at_seconds)}) diverso dall'orario della notizia (${at})`)
      }
    }
    const mode = String(st.mode ?? '')
    if (mode === 'on_published_result') {
      const e = need('event_id'); if (e) lead(e.id, e.at)
    } else if (mode === 'official_result_after_provisional') {
      const p = need('provisional_event_id'); const o = need('official_event_id')
      if (p && o) {
        if (p.at < closes) problems.push(`${id}: la notizia provvisoria arriva prima della chiusura`)
        else if (p.at - closes < 30) warnings.push(`${id}: chiude ${p.at - closes} secondi prima della notizia provvisoria`)
        if (o.at <= p.at) problems.push(`${id}: la conferma ufficiale non segue la notizia provvisoria`)
        if (Number(st.at_seconds) !== o.at) problems.push(`${id}: at_seconds del palinsesto diverso dalla conferma ufficiale`)
      }
    } else if (mode === 'first_matching_event_or_deadline') {
      const first = need('first_matching_event_id'); const dl = need('deadline_event_id')
      const maxKm = Number(st.no_if_no_matching_event_by_km)
      if (!Number.isFinite(maxKm)) problems.push(`${id}: soglia in km non valida`)
      if (first) {
        lead('la foratura', first.at)
        if (!byId.get(first.id)?.is_puncture) problems.push(`${id}: ${first.id} non risulta una foratura`)
        const real = events.find((e) => e.is_puncture && e.at_seconds >= opens && e.km <= maxKm)
        if (real?.id !== first.id) problems.push(`${id}: la prima foratura valida è ${real?.id ?? 'nessuna'}, il palinsesto dice ${first.id}`)
        if (win && win !== 'yes') problems.push(`${id}: con ${first.id} l'esito deve essere SÌ`)
      }
      if (dl) {
        const e = byId.get(dl.id)!
        if (!(e.km > maxKm)) problems.push(`${id}: ${dl.id} non supera il km ${maxKm}`)
        // la soglia del NO scatta alla prima notizia con km corrente oltre la soglia: deve essere proprio quella dichiarata
        const firstOver = events.find((x) => !x.km_is_event_location && x.km > maxKm)
        if (firstOver?.id !== dl.id) problems.push(`${id}: la prima notizia oltre il km ${maxKm} è ${firstOver?.id}, il palinsesto dice ${dl.id}`)
        else warnings.push(`${id}: il NO scatterebbe alla notizia ${dl.id} (km ${e.km}), la prima oltre il km ${maxKm}`)
      }
    } else problems.push(`${id}: modalità di liquidazione sconosciuta (${mode})`)

    markets.push({
      id, seq: i + 1, category: typeof raw.category === 'string' ? raw.category : null, question: q,
      opens_at: opens, closes_at: closes, yes_odds: yes, no_odds: no, winning: win ?? 'yes', settlement: st,
    })
  })
  if (markets.length === 0) problems.push('nessuna scommessa')

  if (problems.length) return { payload: null, problems, warnings }
  return {
    payload: {
      race: { race_id: raceId, name: String(r.name), edition: Number(r.edition), distance_km: Number(r.distance_km), duration_seconds: duration },
      events, markets,
    },
    problems,
    warnings,
  }
}

export function readRace(dir = process.env.RACE_DIR ?? 'data'): { timeline: unknown; banco: unknown } {
  const read = (f: string) => JSON.parse(readFileSync(resolve(dir, f), 'utf8'))
  return { timeline: read('la_teramana_timeline.json'), banco: read('la_teramana_banco.json') }
}
