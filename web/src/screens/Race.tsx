import { Fragment, useEffect, useMemo, useState, type ReactNode } from 'react'
import { actions, loadRace, raceElapsed, useGame, type RaceEvent } from '../store/game'
import { PcsLogo } from '../components/PcsLogo'

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

/** Velocità media calcolata: km corrente dell'ultima notizia diviso il suo tempo di gara (approssimata). */
export function avgSpeed(feed: RaceEvent[]): number | null {
  const e = feed.find((x) => !x.kmEvent && x.km > 0 && x.at > 0)
  return e ? e.km / (e.at / 3600) : null
}

type Icon = 'flag' | 'final' | 'attack' | 'out' | 'warn' | 'data' | null
const iconFor = (e: RaceEvent, distance: number): Icon => {
  if (e.type === 'RESULT' || e.type === 'OFFICIAL RESULT') return distance - e.km <= 0.05 ? 'flag' : 'data'
  if (e.type === 'START') return 'flag'
  if (e.type === 'ATTACK') return 'attack'
  if (e.type === 'WITHDRAWAL') return 'out'
  if (e.type === 'INCIDENT' || e.type === 'MEDICAL UPDATE') return 'warn'
  if (e.type === 'RACE DATA' || e.type === 'PCS STATS') return 'data'
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
      {kind === 'attack' && <path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z" />}
      {kind === 'out' && <path d="M5 5l14 14M19 5L5 19" />}
      {kind === 'warn' && <path d="M12 4l9 16H3zM12 10v4M12 17v.5" />}
      {kind === 'data' && <path d="M4 5h16v14H4zM8 10h8M8 14h5" />}
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
  const lastKm = s.raceFeed.find((e) => !e.kmEvent)?.km ?? 0
  const left = r.status === 'finished' ? 0 : Math.max(0, r.distanceKm - lastKm)
  const avg = avgSpeed(s.raceFeed)
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
      {r.status === 'paused' && <p className="rnote">La corsa è sospesa: il tempo e le scommesse sono fermi.</p>}
      {r.status === 'aborted' && <p className="rnote">La corsa è stata interrotta. Le puntate non decise sono state rimborsate.</p>}
      {mine.length > 0 && <p className="rnote ok">Hai {mine.length} {mine.length === 1 ? 'puntata' : 'puntate'} in corso sulla corsa: le trovi in Scommesse.</p>}

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
