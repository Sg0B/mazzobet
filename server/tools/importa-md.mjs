// Converte i due documenti di redazione (Timeline PCS e Palinsesto del Banco, in Markdown) nei due JSON che il server carica.
// Uso (dalla radice):  node server/tools/importa-md.mjs "<timeline.md>" "<palinsesto.md>"
// Non corregge nulla da solo: le sole eccezioni editoriali sono in OVERRIDE qui sotto, ognuna con il motivo.
import fs from 'node:fs'
import { buildRace } from '../src/race.ts'

const [tlPath, bancoPath] = process.argv.slice(2)
if (!tlPath || !bancoPath) { console.error('Servono i due file .md'); process.exit(1) }
const out = new URL('../data/', import.meta.url)

const clean = (s) => s
  .replace(/\s*<br\s*\/?>\s*/g, ' ').replace(/\*\*/g, '').replace(/\\([\[\]\\~*_])/g, '$1').replace(/\\\\/g, '')
  .replace(/\s+/g, ' ').replace(/\s+([?.,;:])/g, '$1').trim()
const secs = (t) => { const m = /(\d+):(\d\d)/.exec(t); return Number(m[1]) * 60 + Number(m[2]) }
const mmss = (s) => `+${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`

// ------------------------------------------------------------------ timeline
const rows = fs.readFileSync(tlPath, 'utf8').split(/\r?\n/).filter((l) => /^\|\d{2,3}:\d\d\|/.test(l)).map((l) => l.split('|'))
const events = rows.map((c, i) => {
  const kmRaw = c[2].trim()
  const at = secs(c[1])
  return {
    id: 'PCS' + String(i + 1).padStart(3, '0'),
    at_seconds: at, at: mmss(at),
    km: Number(kmRaw.replace(/\s*\(.*\)/, '').replace(',', '.')),
    km_is_event_location: /\(TV\)/.test(kmRaw),
    km_approximate: at >= 197 * 60 + 29 && at <= 197 * 60 + 51,   // ultimo tratto: km indicativi (nota del documento)
    block: Number(c[3]), type: clean(c[4]), text: clean(c[6]),
  }
})
const ev = (time, type) => {
  const hit = events.filter((e) => e.at === time && (!type || e.type === type))
  if (hit.length !== 1) throw new Error(`notizia ${time} ${type ?? ''}: ne trovo ${hit.length}`)
  return hit[0]
}

// Eccezioni editoriali approvate dall'utente il 31/10/2026 (B17: numeri che non tornavano).
const OVERRIDE_TEXT = { '+196:00': [/^Una decina di ragazzi/, 'Cinque ragazzi'] }
for (const e of events) { const o = OVERRIDE_TEXT[e.at]; if (o && o[0].test(e.text)) e.text = e.text.replace(o[0], o[1]) }

const timeline = {
  race: { race_id: 'la_teramana_58', name: 'La Teramana', edition: 58, distance_km: 136.2, duration_seconds: 11880, start_mode: 'manual', clock: 'server_relative_seconds',
          source: 'La_Teramana_Timeline_PCS_MASTER_v1.3.md' },
  events,
}

// ------------------------------------------------------------------ palinsesto
// Come si chiude ogni mercato: notizia che decide (orario della cronaca v1.3, non l'arrotondamento del palinsesto).
const SETTLE = {
  B01: ['+40:26', 'RESULT'], B02: ['+66:18', 'RESULT'], B03: ['+118:45', 'RESULT'], B04: ['+95:57'], B05: ['+125:36'],
  B11: ['+40:26', 'RESULT'], B12: ['+27:13', 'ATTACK'], B13: ['+66:18', 'RESULT'],
  // B14: il km 90 è superato alla prima notizia con km corrente oltre 90 (131:28, km 91): il palinsesto indicava +135:00, senza una notizia.
  B14: ['+131:28'], B15: ['+168:48', 'WITHDRAWAL'],
  // B16 (domanda riscritta, vedi OVERRIDE_Q): il «nuovo avvistamento» è la notizia delle 122:00.
  B16: ['+122:00'], B17: ['+196:00'],
  B08: ['+198:00', 'RESULT'], B09: ['+198:00', 'RESULT'], B10: ['+198:00', 'RESULT'],
}
const OVERRIDE_Q = { B16: 'Verranno avvistati di nuovo maiali tra i tifosi entro il km 85?' }   // approvato dall'utente il 31/10/2026

const table = fs.readFileSync(bancoPath, 'utf8').split(/\r?\n/).filter((l) => /^\|B\d\d\|/.test(l)).map((l) => l.split('|'))
const num = (s) => Number(clean(s).replace(',', '.'))
const markets = table.map((c) => {
  const id = c[1]
  const times = (s) => [...clean(s).matchAll(/\+(\d+):(\d\d)/g)].map((m) => Number(m[1]) * 60 + Number(m[2]))
  const opens = times(c[4].replace(/¹/g, ''))[0]
  const closes = times(c[5])[0]
  const win = clean(c[9]).replace(/\*/g, '')
  const m = {
    id, category: clean(c[2]), question: OVERRIDE_Q[id] ?? clean(c[3]),
    opens_at_seconds: opens, closes_at_seconds: closes,
    odds: { SI: num(c[7]), NO: num(c[8]) }, winning_answer: win,
  }
  if (id === 'B06') {
    const p = ev('+162:13'), o = ev('+189:07')
    m.settlement = { mode: 'official_result_after_provisional', provisional_event_id: p.id, official_event_id: o.id, at_seconds: o.at_seconds }
  } else if (id === 'B07') {
    const first = ev('+86:09')
    const dl = events.find((e) => !e.km_is_event_location && e.km > 107)
    m.settlement = { mode: 'first_matching_event_or_deadline', event_type: 'INCIDENT', match_rule: 'foratura pubblicata dopo apertura e non oltre km 107',
      first_matching_event_id: first.id, yes_at_seconds: first.at_seconds, no_if_no_matching_event_by_km: 107.0, deadline_event_id: dl.id, at_seconds: first.at_seconds }
  } else {
    const e = ev(...SETTLE[id])
    m.settlement = { mode: 'on_published_result', event_id: e.id, at_seconds: e.at_seconds }
  }
  return m
}).sort((a, b) => a.id.localeCompare(b.id))

const banco = {
  race_id: 'la_teramana_58', currency: '₡', odds_format: 'decimal', markets,
  rules: { independent_yes_no_markets: true, odds_fixed_at_open: true, server_authoritative_clock: true, settle_only_once: true,
           never_expose_future_results_to_clients: true, no_race_pauses_for_betting: true },
  source: 'La_Teramana_Palinsesto_Banco_MASTER_v1.0.md',
}

const r = buildRace(timeline, banco)
console.log(`notizie ${events.length}, mercati ${markets.length}`)
r.warnings.forEach((w) => console.log('  avviso:', w))
if (r.problems.length) { r.problems.forEach((p) => console.log('  PROBLEMA:', p)); process.exit(1) }
fs.writeFileSync(new URL('la_teramana_timeline.json', out), JSON.stringify(timeline, null, 2) + '\n')
fs.writeFileSync(new URL('la_teramana_banco.json', out), JSON.stringify(banco, null, 2) + '\n')
console.log('scritti i due JSON in server/data')

// ------------------------------------------------------------------ traiettoria dei km (per i km che avanzano tra una notizia e l'altra)
// Provvisoria: costruita dai km e dai tempi delle notizie (nessun esito, solo posizione); si sostituisce con il file del gruppo quando c'è.
const pts = []
for (const e of events) {
  if (e.km_is_event_location) continue
  const last = pts[pts.length - 1]
  if (last && e.at_seconds === last[0]) { last[1] = Math.max(last[1], e.km); continue }
  pts.push([e.at_seconds, Math.max(e.km, last ? last[1] : 0)])
}
fs.writeFileSync(new URL('../../web/src/lib/raceTrack.ts', import.meta.url),
  `// GENERATO da server/tools/importa-md.mjs — non modificare a mano.\n// Traiettoria provvisoria [secondi di gara, km] ricavata dalle notizie; solo posizione, nessun esito.\nexport const RACE_TRACK: [number, number][] = ${JSON.stringify(pts)}\n`)
console.log(`traiettoria: ${pts.length} punti`)
