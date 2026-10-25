import { useEffect, useMemo, useRef, useState } from 'react'
import qrcode from 'qrcode-generator'
import { fmt, hhmm, mmss, odds } from '../lib/format'

/**
 * Schermo della sala (/tv): sola lettura, senza codice, pensato per una smart TV o un telefono in mirroring.
 * Una scena alla volta a rotazione, RadioCorsa che scorre in basso, eventi grossi a tutto schermo, annuncio della Regia in alto.
 */
interface Row { teamId: number; name: string; pos: number | null; value?: number; balance?: number; won?: number; done?: number; pct?: number | null; best?: number; cur?: number }
interface Tv {
  now: string
  session: { name: string; status: string; endsAt: string } | null
  announcement?: { text: string; until: string } | null
  config?: { bankruptThreshold: number }
  rankings?: { minEsitate: number; patrimonio: Row[]; pronostici: Row[]; striscia: Row[]; puntate: Row[]; bancarotte: Row[] }
  teams?: { teamId: number; name: string; balance: number; status: string }[]
  open?: { no: number; question: string; by: string; yesOdds: number; noOdds: number; expiresAt: string; yesPool: number; noPool: number; bets: number }[]
  waiting?: { no: number; question: string; by: string; resolveBy: string; yesPool: number; noPool: number }[]
  results?: { no: number; question: string; by: string; outcome: 'yes' | 'no'; flipped: boolean; byAdmin: boolean; yesPool: number; noPool: number; best: { name: string; payout: number } | null }[]
  news?: { id: number; at: string; kind: string; title: string; text: string }[]
  bank?: { cash: number; inPlay: number; open: boolean; events: { id: number; at: string; kind: 'bonus' | 'malus' | 'sponsor'; amount: number; teams: string[] }[] }
}

const SCENE_MS = 12_000
const EVENT_MS = 8_000
const POLL_MS = 5_000
const KIND: Record<string, string> = { bonus: 'BONUS', malus: 'MALUS', giuria: 'GIURIA', bank: 'RADIOCORSA', sponsor: 'SPONSOR' }

function useTv() {
  const [data, setData] = useState<Tv | null>(null)
  const [offline, setOffline] = useState(false)
  const offset = useRef(0)
  useEffect(() => {
    let stop = false
    const load = async () => {
      try {
        const res = await fetch('/api/tv', { cache: 'no-store' })
        if (!res.ok) throw new Error()
        const d = (await res.json()) as Tv
        offset.current = Date.parse(d.now) - Date.now()
        if (!stop) { setData(d); setOffline(false) }
      } catch {
        if (!stop) setOffline(true)
      }
    }
    void load()
    const t = setInterval(() => void load(), POLL_MS)
    return () => { stop = true; clearInterval(t) }
  }, [])
  return { data, offline, offset }
}

/** Tiene lo schermo acceso (dove il browser lo permette). */
function useWakeLock() {
  useEffect(() => {
    let lock: { release: () => Promise<void> } | null = null
    const ask = async () => {
      try {
        const nav = navigator as Navigator & { wakeLock?: { request: (t: 'screen') => Promise<{ release: () => Promise<void> }> } }
        lock = (await nav.wakeLock?.request('screen')) ?? null
      } catch { /* non supportato: pazienza */ }
    }
    void ask()
    const vis = () => { if (document.visibilityState === 'visible') void ask() }
    document.addEventListener('visibilitychange', vis)
    return () => { document.removeEventListener('visibilitychange', vis); void lock?.release() }
  }, [])
}

function Qr({ url }: { url: string }) {
  const svg = useMemo(() => {
    const q = qrcode(0, 'M')
    q.addData(url)
    q.make()
    return q.createSvgTag({ cellSize: 4, margin: 2, scalable: true })
  }, [url])
  return <div className="tv-qr" aria-label={`Codice QR per entrare: ${url}`} dangerouslySetInnerHTML={{ __html: svg }} />
}

type SceneId = 'patrimonio' | 'pronostici' | 'altre' | 'aperte' | 'esiti' | 'banco'

export function TvScreen() {
  const { data, offline, offset } = useTv()
  const [tick, setTick] = useState(0)
  const [idx, setIdx] = useState(0)
  const [event, setEvent] = useState<{ kind: string; title: string; text: string } | null>(null)
  const seen = useRef<number | null>(null)
  const queue = useRef<{ kind: string; title: string; text: string }[]>([])
  useWakeLock()

  useEffect(() => { document.title = 'MazzoBet TV' }, [])
  useEffect(() => { const t = setInterval(() => setTick((n) => n + 1), 1000); return () => clearInterval(t) }, [])
  const nowMs = Date.now() + offset.current
  void tick

  // Eventi grossi: ogni comunicato nuovo (dopo il primo caricamento) passa a tutto schermo, uno alla volta.
  useEffect(() => {
    const news = data?.news
    if (!news) return
    const top = news.length ? news[0].id : 0
    if (seen.current === null) { seen.current = top; return }
    const fresh = news.filter((n) => n.id > (seen.current ?? 0)).sort((a, b) => a.id - b.id)
    if (fresh.length) {
      seen.current = top
      queue.current.push(...fresh.map((n) => ({ kind: KIND[n.kind] ?? 'RADIOCORSA', title: n.title, text: n.text })))
      queue.current = queue.current.slice(-4)
    }
  }, [data])
  useEffect(() => {
    if (event) { const t = setTimeout(() => setEvent(null), EVENT_MS); return () => clearTimeout(t) }
    const t = setTimeout(() => { const next = queue.current.shift(); if (next) setEvent(next) }, 300)
    return () => clearTimeout(t)
  }, [event, tick])

  const scenes = useMemo<SceneId[]>(() => {
    if (!data?.rankings) return []
    const r = data.rankings
    const s: SceneId[] = []
    if (r.patrimonio.length) s.push('patrimonio')
    if (r.pronostici.some((x) => x.pos !== null)) s.push('pronostici')
    if (r.striscia.some((x) => (x.best ?? 0) > 0) || r.puntate.some((x) => (x.value ?? 0) > 0) || r.bancarotte.length) s.push('altre')
    if (data.open?.length || data.waiting?.length) s.push('aperte')
    if (data.results?.length) s.push('esiti')
    if (r.patrimonio.length) s.push('banco')
    return s
  }, [data])

  useEffect(() => {
    const t = setInterval(() => setIdx((i) => i + 1), SCENE_MS)
    return () => clearInterval(t)
  }, [])

  const url = window.location.origin
  const toggleFs = () => {
    if (document.fullscreenElement) void document.exitFullscreen()
    else void document.documentElement.requestFullscreen?.().catch(() => undefined)
  }

  if (!data) return <div className="tv" onClick={toggleFs}><p className="tv-wait">{offline ? 'Connessione assente… riprovo.' : 'Carico…'}</p></div>

  const scene = scenes.length ? scenes[idx % scenes.length] : null
  const closed = data.session?.status === 'closed'
  const ann = data.announcement && Date.parse(data.announcement.until) > nowMs ? data.announcement : null

  return (
    <div className="tv" onClick={toggleFs}>
      <header className="tv-top">
        <div className="tv-logo">MAZZO<b>BET</b></div>
        <div className="tv-ses">{data.session?.name ?? ''}{closed ? ' · SERATA CONCLUSA' : ''}</div>
        <div className="tv-clock num">{hhmm(nowMs)}</div>
        <div className="tv-join"><Qr url={url} /><span>{url.replace(/^https?:\/\//, '')}</span></div>
      </header>

      {ann && <div className="tv-ann" role="alert"><span>ANNUNCIO</span>{ann.text}</div>}

      <main className="tv-main" key={scene ?? 'vuota'}>
        {scene === null && <Waiting url={url} />}
        {scene === 'patrimonio' && <Patrimonio data={data} />}
        {scene === 'pronostici' && <Pronostici data={data} />}
        {scene === 'altre' && <Altre data={data} />}
        {scene === 'aperte' && <Aperte data={data} now={nowMs} />}
        {scene === 'esiti' && <Esiti data={data} />}
        {scene === 'banco' && <Banco data={data} />}
      </main>

      <footer className="tv-foot">
        <span className="tv-k">RADIOCORSA</span>
        <Ticker items={(data.news ?? []).slice(0, 8)} />
        {offline && <span className="tv-off">connessione instabile</span>}
      </footer>

      {event && (
        <div className="tv-event" role="alert" key={event.title + event.text}>
          <div className="tv-evk">{event.kind}</div>
          <h2>{event.title}</h2>
          <p>{event.text}</p>
        </div>
      )}
    </div>
  )
}

function Ticker({ items }: { items: NonNullable<Tv['news']> }) {
  const text = items.map((n) => `${n.title.toUpperCase()}: ${n.text}`).join('   •   ')
  if (!text) return <div className="tv-tick" />
  const secs = Math.max(30, Math.round(text.length * 0.2))
  return (
    <div className="tv-tick">
      <div className="tv-tickin" style={{ animationDuration: `${secs}s` }}><span>{text}</span><span aria-hidden="true">{text}</span></div>
    </div>
  )
}

function Waiting({ url }: { url: string }) {
  return (
    <div className="tv-wait">
      <h1>In attesa delle squadre</h1>
      <p>Scegli la tua squadra da telefono: inquadra il codice o scrivi {url.replace(/^https?:\/\//, '')}</p>
    </div>
  )
}

const posCls = (p: number | null) => (p === 1 ? ' p1' : p === 2 ? ' p2' : p === 3 ? ' p3' : '')

function Board({ title, note, rows }: { title: string; note?: string; rows: { key: number; pos: number | null; name: string; val: string; sub?: string; tag?: string }[] }) {
  const cols = rows.length > 9 ? 2 : 1
  const per = Math.ceil(rows.length / cols)
  return (
    <section className="tv-scene">
      <h1>{title}</h1>
      <ol className="tv-rows" style={{ gridTemplateRows: `repeat(${per}, minmax(0, 1fr))`, gridAutoFlow: 'column', gridTemplateColumns: `repeat(${cols}, 1fr)` }}>
        {rows.map((r) => (
          <li key={r.key} className={`tv-row${posCls(r.pos)}`}>
            <span className="tv-pos num">{r.pos ?? '–'}</span>
            <span className="tv-nm">{r.name}{r.tag && <em>{r.tag}</em>}</span>
            <span className="tv-val num">{r.val}{r.sub && <small>{r.sub}</small>}</span>
          </li>
        ))}
      </ol>
      {note && <p className="tv-note">{note}</p>}
    </section>
  )
}

function Patrimonio({ data }: { data: Tv }) {
  const st = new Map((data.teams ?? []).map((t) => [t.teamId, t]))
  return (
    <Board
      title="Classifica Carletti"
      note="Patrimonio: saldo più le puntate ancora in corso."
      rows={(data.rankings?.patrimonio ?? []).map((x) => ({
        key: x.teamId, pos: x.pos, name: x.name, val: fmt(x.value ?? 0),
        sub: x.balance !== x.value ? `saldo ${fmt(x.balance ?? 0)}` : undefined,
        tag: st.get(x.teamId)?.status === 'bankrupt' ? 'in bancarotta' : undefined,
      }))}
    />
  )
}

function Pronostici({ data }: { data: Tv }) {
  const min = data.rankings?.minEsitate ?? 0
  return (
    <Board
      title="Chi indovina di più"
      note={`In classifica con almeno ${min} scommesse esitate.`}
      rows={(data.rankings?.pronostici ?? []).filter((x) => x.pos !== null).map((x) => ({
        key: x.teamId, pos: x.pos, name: x.name, val: `${x.won} su ${x.done}`, sub: x.pct != null ? `${x.pct}%` : undefined,
      }))}
    />
  )
}

function Mini({ title, rows }: { title: string; rows: { key: number; pos: number | null; name: string; val: string }[] }) {
  return (
    <div className="tv-mini">
      <h2>{title}</h2>
      {rows.length === 0 && <p className="tv-none">nessuno, per ora</p>}
      <ol>
        {rows.map((r) => (
          <li key={r.key} className={`tv-row${posCls(r.pos)}`}>
            <span className="tv-pos num">{r.pos}</span><span className="tv-nm">{r.name}</span><span className="tv-val num">{r.val}</span>
          </li>
        ))}
      </ol>
    </div>
  )
}

function Altre({ data }: { data: Tv }) {
  const r = data.rankings!
  return (
    <section className="tv-scene">
      <h1>Le altre classifiche</h1>
      <div className="tv-three">
        <Mini title="Striscia vincente" rows={r.striscia.filter((x) => (x.best ?? 0) > 0).slice(0, 5).map((x) => ({ key: x.teamId, pos: x.pos, name: x.name, val: x.cur ? `${x.best} · ora ${x.cur}` : String(x.best) }))} />
        <Mini title="Più puntato" rows={r.puntate.filter((x) => (x.value ?? 0) > 0).slice(0, 5).map((x) => ({ key: x.teamId, pos: x.pos, name: x.name, val: fmt(x.value ?? 0) }))} />
        <Mini title="Bancarotte" rows={r.bancarotte.slice(0, 5).map((x) => ({ key: x.teamId, pos: x.pos, name: x.name, val: String(x.value) }))} />
      </div>
    </section>
  )
}

function Aperte({ data, now }: { data: Tv; now: number }) {
  const open = (data.open ?? []).slice(0, 4)
  const waiting = (data.waiting ?? []).slice(0, 3)
  return (
    <section className="tv-scene">
      <h1>Scommesse in corso</h1>
      <div className="tv-cards">
        {open.map((m) => (
          <article key={m.no} className="tv-card">
            <div className="tv-cd num">{mmss(Date.parse(m.expiresAt) - now)}</div>
            <h3>{m.question}</h3>
            <div className="tv-by">di {m.by} · {m.bets} {m.bets === 1 ? 'puntata' : 'puntate'} · {fmt(m.yesPool + m.noPool)} Carletti</div>
            <div className="tv-odds">
              <span><b>SÌ</b><i className="num">{odds(m.yesOdds)}</i></span>
              <span><b>NO</b><i className="num">{odds(m.noOdds)}</i></span>
            </div>
          </article>
        ))}
        {open.length === 0 && <p className="tv-none">Nessuna scommessa aperta: creane una dal telefono.</p>}
      </div>
      {waiting.length > 0 && (
        <div className="tv-wl">
          <h2>In attesa di esito</h2>
          {waiting.map((m) => <p key={m.no}>«{m.question}» · di {m.by}</p>)}
        </div>
      )}
    </section>
  )
}

function Esiti({ data }: { data: Tv }) {
  return (
    <section className="tv-scene">
      <h1>Ultimi esiti</h1>
      <div className="tv-res">
        {(data.results ?? []).slice(0, 5).map((m) => (
          <article key={m.no} className="tv-resrow">
            <span className={`tv-out ${m.outcome}`}>{m.outcome === 'yes' ? 'SÌ' : 'NO'}</span>
            <div>
              <h3>{m.question}</h3>
              <p>di {m.by}{m.byAdmin ? ' · esitata dalla Regia' : m.flipped ? ' · esito ribaltato dal ricorso' : ''}{m.best ? ` · miglior vincita: ${m.best.name} ${fmt(m.best.payout)}` : ' · nessun vincitore'}</p>
            </div>
          </article>
        ))}
      </div>
    </section>
  )
}

function Banco({ data }: { data: Tv }) {
  const b = data.bank!
  const label = { bonus: 'Bonus', malus: 'Malus', sponsor: 'Sponsor' }
  return (
    <section className="tv-scene">
      <h1>Il Banco</h1>
      {!b.open && <p className="tv-note big">Il Banco non è ancora aperto: bonus, malus e sponsor arriveranno a breve.</p>}
      <div className="tv-bank">
        <div><span>Cassa del Banco</span><b className="num">{fmt(b.cash)}</b><small>indicativo</small></div>
        <div><span>In gioco ora</span><b className="num">{fmt(b.inPlay)}</b><small>Carletti puntati</small></div>
      </div>
      {b.events.length > 0 && (
        <ul className="tv-ev">
          {b.events.map((e) => (
            <li key={e.id} className={e.kind}>
              <b>{label[e.kind]}</b>
              <span>{e.kind === 'sponsor' ? `pioggia per tutte le squadre · ${fmt(e.amount)} in cassa` : `${e.teams.join(', ')} · ${e.kind === 'malus' ? '−' : '+'}${fmt(e.amount)}`}</span>
              <time className="num">{hhmm(Date.parse(e.at))}</time>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
