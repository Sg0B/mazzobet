import { Fragment, useEffect, useMemo, useState, type ReactNode } from 'react'
import { actions, loadRace, raceElapsed, useGame, type RaceEvent } from '../store/game'
import { PcsLogo } from '../components/PcsLogo'
import { RACE_BADGE } from '../lib/raceTypes'
import { kmAt } from '../lib/raceKm'
import { SmartBet } from '../components/SmartBet'

const TOTAL_LABEL: Record<string, string> = {
  not_started: 'Non ancora partita',
  running: 'In diretta',
  paused: 'Corsa sospesa',
  finished: 'Corsa conclusa',
  aborted: 'Corsa interrotta',
}

/** Secondi di gara come h:mm:ss. */
export const raceTime = (sec: number) => {
  const t = Math.max(0, Math.floor(sec))
  const h = Math.floor(t / 3600)
  const m = Math.floor((t % 3600) / 60)
  const s = t % 60
  return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

const kmFmt = (n: number) => (Math.round(n * 10) / 10).toString().replace('.', ',')

/** Km mancanti all'arrivo per il cerchietto: «F» al traguardo. */
const toGo = (distance: number, e: RaceEvent) => {
  const left = distance - e.km
  return left <= 0.05 ? 'F' : kmFmt(left)
}

/** Velocità media della corsa: km percorsi diviso ore di gara (stima dalla simulazione, non un dato misurato). */
export const avgSpeed = (km: number, elapsed: number): number | null => (elapsed > 0 ? km / (elapsed / 3600) : null)

type Icon = 'flag' | 'final' | null
const iconFor = (e: RaceEvent, distance: number): Icon => {
  if (e.type === 'RESULT' || e.type === 'OFFICIAL RESULT') return distance - e.km <= 0.05 ? 'flag' : null
  if (e.type === 'START') return 'flag'
  if (/ultimo chilometro/i.test(e.text)) return 'final'
  return null
}

function EventIcon({ kind }: { kind: Icon }) {
  if (!kind) return null
  const common = { viewBox: '0 0 24 24', 'aria-hidden': true } as const
  return (
    <svg className={`ico ${kind}`} {...common}>
      {kind === 'flag' && <path d="M5 3v18M5 4h14v9H5M9 4v9M13 4v9M17 4v9M5 8.5h14" />}
      {kind === 'final' && <path d="M3 5h18L12 20z" />}
    </svg>
  )
}

/** Il testo con i nomi delle squadre in azzurro (la propria in evidenza), come i corridori su PCS. */
function Marked({ text, names, me }: { text: string; names: string[]; me: string | null }) {
  const parts = useMemo(() => {
    if (!names.length) return [text]
    const esc = names.slice().sort((a, b) => b.length - a.length).map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    return text.split(new RegExp(`(${esc.join('|')})`, 'g'))
  }, [text, names])
  const set = useMemo(() => new Set(names), [names])
  return (
    <>
      {parts.map((p, i): ReactNode =>
        set.has(p) ? <b key={i} className={`tm${p === me ? ' me' : ''}`}>{p}</b> : <Fragment key={i}>{p}</Fragment>,
      )}
    </>
  )
}

export function Race() {
  const s = useGame()
  const [teams, setTeams] = useState<string[]>([])
  useEffect(() => {
    void loadRace()
    const t = setInterval(() => void loadRace(), 3000)
    return () => clearInterval(t)
  }, [])
  useEffect(() => {
    let live = true
    void actions.listTeams().then((l) => { if (live) setTeams(l.map((x) => x.name)) }).catch(() => undefined)
    return () => { live = false }
  }, [])

  const r = s.race
  if (!r) {
    return (
      <>
        <div className="top"><PcsLogo /></div>
        <p className="empty">La corsa di questa serata non è ancora stata preparata.</p>
      </>
    )
  }

  const elapsed = raceElapsed(r, s.now)
  // i km avanzano col tempo di gara del server, anche senza notizie nuove; all'arrivo 0 km mancanti
  const done = r.status === 'not_started' ? 0 : r.status === 'finished' ? r.distanceKm : Math.min(r.distanceKm, kmAt(elapsed))
  const left = Math.max(0, r.distanceKm - done)
  const avg = avgSpeed(done, elapsed)
  const mine = s.markets.filter((m) => m.race && m.my && (m.status === 'open' || m.status === 'closed'))

  return (
    <div className="racepage">
      <div className="top">
        <PcsLogo />
        <span className={`rstate ${r.status}`}>{TOTAL_LABEL[r.status]}</span>
      </div>
      <h1 className="rname">{r.name} <small>{r.edition}ª edizione · {kmFmt(r.distanceKm)} km</small></h1>

      <div className="rhead" aria-label="Situazione di gara">
        <div><span className="v num">{kmFmt(left)}</span><span className="l">km mancanti</span></div>
        <div><span className="v num">{r.status === 'not_started' ? '0:00:00' : raceTime(elapsed)}</span><span className="l">tempo di gara</span></div>
        <div><span className="v num">{avg ? avg.toFixed(1).replace('.', ',') : '—'}</span><span className="l">km/h media</span></div>
      </div>
      {r.speed > 1 && <p className="rnote">Prova accelerata ×{Math.round(r.speed * 10) / 10}: la corsa dura meno di 3 ore.</p>}
      {r.status === 'paused' && <p className="rnote">La corsa è sospesa: il tempo e le scommesse sono fermi.</p>}
      {r.status === 'aborted' && <p className="rnote">La corsa è stata interrotta. Le puntate non decise sono state rimborsate.</p>}
      {mine.length > 0 && <p className="rnote ok">Hai {mine.length} {mine.length === 1 ? 'puntata' : 'puntate'} in corso sulla corsa: le trovi in Scommesse.</p>}

      <SmartBet />

      <h2 className="sec rsec">Cronaca live</h2>
      {s.raceFeed.length === 0 ? (
        <p className="empty">{r.status === 'not_started' ? 'La corsa non è ancora partita. Le notizie compariranno qui.' : 'In attesa della prima notizia.'}</p>
      ) : (
        <ol className="rfeed">
          {s.raceFeed.map((e) => (
            <li key={e.id} className={e.type === 'RESULT' || e.type === 'OFFICIAL RESULT' ? 'big' : ''}>
              <span className="km num" title={e.kmApprox ? 'km approssimativo' : undefined}>{toGo(r.distanceKm, e)}</span>
              <div className="tx">
                <EventIcon kind={iconFor(e, r.distanceKm)} />
                {RACE_BADGE[e.type] && <span className={`rbadge ${RACE_BADGE[e.type].cls}`}>{RACE_BADGE[e.type].label}</span>}
                <p><Marked text={e.text} names={teams} me={s.team} /></p>
                <small className="num">{raceTime(e.at)}</small>
              </div>
            </li>
          ))}
        </ol>
      )}
    </div>
  )
}
