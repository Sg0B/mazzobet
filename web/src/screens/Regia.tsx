import { useCallback, useEffect, useState } from 'react'
import { fmt, hhmm } from '../lib/format'

/**
 * Banco di Regia (/regia): pagina separata, non linkata dall'app. Il codice sta solo nel browser di chi lo inserisce
 * (localStorage) e viene mandato a ogni richiesta; il controllo è tutto sul server.
 */
const CODE_KEY = 'mazzobet-regia'
const getCode = () => { try { return localStorage.getItem(CODE_KEY) ?? '' } catch { return '' } }
const setCode = (c: string | null) => { try { if (c === null) localStorage.removeItem(CODE_KEY); else localStorage.setItem(CODE_KEY, c) } catch { /* ignora */ } }

class RegiaError extends Error {
  constructor(public status: number, message: string) { super(message) }
}
async function call<T>(path: string, body?: unknown, code = getCode()): Promise<T> {
  let res: Response
  try {
    res = await fetch(`/api/regia/${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'x-admin-code': code, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  } catch {
    throw new RegiaError(0, 'Connessione assente.')
  }
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new RegiaError(res.status, data.message ?? 'Errore.')
  return data as T
}

interface Team { id: number; name: string; entered: boolean; balance: number | null; status: string | null; devices: number }
interface MarketRow {
  id: number; no: number; question: string; by: string; raceId: string | null; status: 'open' | 'closed' | 'resolved' | 'void' | 'empty'
  outcome: 'yes' | 'no' | null; flipped: boolean; byAdmin: boolean; expiresAt: string; yesPool: number; noPool: number
}
interface RaceAdmin {
  loaded: boolean; name?: string; distanceKm?: number; durationSeconds?: number
  status?: 'not_started' | 'running' | 'paused' | 'finished' | 'aborted'
  elapsed?: number; speed?: number; durationMin?: number; published?: number; totalEvents?: number; bets?: number
}
interface LogRow { id: number; at: string; action: string; detail: Record<string, unknown>; marketNo: number | null; team: string | null }
interface State {
  now: string
  sessions: { session: string; status: string; bankPaused: boolean; nextBank: string | null; nextSponsor: string | null; endsAt: string; teams: number; openMarkets: number; awaitingResult: number; inAppealWindow: number; bankCash: number }[]
  session: { id: string; name: string; status: string; endsAt: string; bankPaused: boolean; bankNextAt: string | null; sponsorNextAt: string | null } | null
  tvMessage: { text: string; until: string } | null
  race: RaceAdmin
  bankStart: string
  bankOpen: boolean
  params: Record<string, number>
  teams: Team[]
  markets: MarketRow[]
  log: LogRow[]
}

const PARAMS: { key: string; label: string; unit: string }[] = [
  { key: 'saldo_iniziale', label: 'Saldo iniziale', unit: 'Carletti' },
  { key: 'riammissione_saldo', label: 'Saldo dopo la riammissione', unit: 'Carletti' },
  { key: 'finestra_esito_min', label: 'Tempo totale per esitare (dalla scadenza)', unit: 'minuti' },
  { key: 'precedenza_creatore_min', label: 'Precedenza del creatore', unit: 'minuti' },
  { key: 'banco_importo_min', label: 'Banco: importo minimo', unit: 'Carletti' },
  { key: 'banco_importo_max', label: 'Banco: importo massimo', unit: 'Carletti' },
  { key: 'colletta_importo', label: 'Colletta per giro', unit: 'Carletti' },
]

const ACTION: Record<string, string> = {
  reset_squadra: 'Reset squadra', reset_totale: 'Reset totale', parametro: 'Parametro', banco_inizio: 'Orario Banco',
  banco_adesso: 'Banco avviato adesso', banco_pausa: 'Banco in pausa', banco_ripresa: 'Banco ripreso',
  chiusura_serata: 'Chiusura serata', chiusura_forzata: 'Chiusura forzata', esito_regia: 'Esito dalla Regia',
  annulla_rimborso: 'Annulla con rimborso', rettifica_saldo: 'Rettifica saldo',
  annuncio_tv: 'Annuncio sulla TV', annuncio_tv_tolto: 'Annuncio TV tolto',
  corsa_avvio: 'Corsa avviata', corsa_pausa: 'Corsa in pausa', corsa_ripresa: 'Corsa ripresa', corsa_durata: 'Durata della corsa',
}
const STATUS: Record<string, string> = { open: 'APERTA', closed: 'DA ESITARE', resolved: 'ESITATA', void: 'ANNULLATA', empty: 'SENZA PUNTATE' }

type Tab = 'serata' | 'corsa' | 'banco' | 'squadre' | 'scommesse' | 'schermo' | 'parametri' | 'log'
const TABS: { id: Tab; label: string }[] = [
  { id: 'serata', label: 'Serata' }, { id: 'corsa', label: 'Corsa' }, { id: 'banco', label: 'Banco' }, { id: 'squadre', label: 'Squadre' },
  { id: 'scommesse', label: 'Scommesse' }, { id: 'schermo', label: 'Schermo' }, { id: 'parametri', label: 'Parametri' }, { id: 'log', label: 'Log' },
]

const localInput = (iso: string) => {
  const d = new Date(iso)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}
const when = (iso: string | null) => (iso ? hhmm(new Date(iso).getTime()) : '—')

function detailText(l: LogRow): string {
  const d = l.detail
  const parts: string[] = []
  if (l.team) parts.push(l.team)
  if (l.marketNo) parts.push(`scommessa n. ${l.marketNo}`)
  if (l.action === 'parametro') parts.push(`${d.chiave}: ${d.prima} → ${d.dopo}`)
  if (l.action === 'rettifica_saldo') parts.push(`${Number(d.importo) > 0 ? '+' : ''}${d.importo} · ${d.motivo}`)
  if (l.action === 'esito_regia') parts.push(`esito ${d.esito === 'yes' ? 'SÌ' : 'NO'}, compenso creatore ${d.compensoCreatore}`)
  if (l.action === 'banco_inizio') parts.push(`alle ${when(String(d.dopo))}`)
  if (l.action === 'reset_squadra') parts.push(`${d.dispositivi} dispositivi scollegati`)
  if (l.action === 'reset_totale') parts.push(String(d.nome))
  return parts.join(' · ')
}

export function Regia() {
  const [code, setCodeState] = useState(getCode())
  const [draft, setDraft] = useState('')
  const [st, setSt] = useState<State | null>(null)
  const [err, setErr] = useState('')
  const [tab, setTab] = useState<Tab>('serata')
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    if (!getCode()) return
    try {
      setSt(await call<State>('state'))
      setErr('')
    } catch (e) {
      if (e instanceof RegiaError && (e.status === 401 || e.status === 503)) { setCode(null); setCodeState(''); setSt(null) }
      setErr(e instanceof Error ? e.message : 'Errore.')
    }
  }, [])

  useEffect(() => {
    if (!code) return
    void load()
    const t = setInterval(() => void load(), 5000)
    return () => clearInterval(t)
  }, [code, load])

  const login = async () => {
    const c = draft.trim()
    if (!c) return
    try {
      await call<State>('state', undefined, c)
      setCode(c)
      setCodeState(c)
      setDraft('')
      setErr('')
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Errore.')
    }
  }

  /** Esegue un'azione di Regia, poi ricarica lo stato; mostra l'esito in alto. */
  const act = async (path: string, body: unknown, ok: string, confirmText?: string) => {
    if (confirmText && !window.confirm(confirmText)) return false
    setBusy(true)
    setMsg('')
    try {
      await call(path, body)
      setMsg(ok)
      await load()
      return true
    } catch (e) {
      setMsg(e instanceof Error ? e.message : 'Errore.')
      return false
    } finally {
      setBusy(false)
    }
  }

  if (!code || !st) {
    return (
      <div id="app" className="regia">
        <div className="top"><div className="logo">BANCO DI REGIA</div></div>
        {!code ? (
          <>
            <label htmlFor="rcode">Codice Regia</label>
            <input id="rcode" type="password" autoComplete="off" value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && void login()} />
            <p className="err" role="alert">{err}</p>
            <button className="cta sm" onClick={() => void login()}>ENTRA</button>
          </>
        ) : <p className="empty">{err || 'Carico…'}</p>}
      </div>
    )
  }

  const s = st.session
  const cur = st.sessions[0]
  return (
    <div id="app" className="regia">
      <div className="top"><div className="logo">BANCO DI REGIA</div></div>
      <p className="note">
        {s ? <>Serata <b>{s.name}</b> · {s.status === 'active' ? 'attiva' : s.status === 'paused' ? 'in pausa' : s.status} · fine alle {when(s.endsAt)}</> : <b>Nessuna serata attiva.</b>}
        {' '}<button className="sm" style={{ textDecoration: 'underline' }} onClick={() => { setCode(null); setCodeState(''); setSt(null) }}>Esci</button>
      </p>
      <div className="rkchips" role="tablist">
        {TABS.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} className={`chip${tab === t.id ? ' on' : ''}`} onClick={() => setTab(t.id)}>{t.label}</button>
        ))}
      </div>
      {(msg || err) && <p className="err" role="status">{msg || err}</p>}

      {tab === 'serata' && <Serata st={st} cur={cur} act={act} busy={busy} />}
      {tab === 'corsa' && <Corsa st={st} act={act} busy={busy} />}
      {tab === 'banco' && <Banco st={st} act={act} busy={busy} />}
      {tab === 'squadre' && <Squadre st={st} act={act} busy={busy} />}
      {tab === 'scommesse' && <Scommesse st={st} act={act} busy={busy} />}
      {tab === 'schermo' && <Schermo st={st} act={act} busy={busy} />}
      {tab === 'parametri' && <Parametri st={st} act={act} busy={busy} />}
      {tab === 'log' && (
        <div className="tbl">
          {st.log.length ? st.log.map((l) => (
            <div className="rlog" key={l.id}>
              <span className="t">{hhmm(new Date(l.at).getTime())}</span>
              <span><b>{ACTION[l.action] ?? l.action}</b>{detailText(l) && <><br /><small>{detailText(l)}</small></>}</span>
            </div>
          )) : <p className="empty" style={{ padding: 14 }}>Nessuna azione registrata.</p>}
        </div>
      )}
    </div>
  )
}

type Act = (path: string, body: unknown, ok: string, confirmText?: string) => Promise<boolean>
interface P { st: State; act: Act; busy: boolean }

function Serata({ st, cur, act, busy }: P & { cur: State['sessions'][number] | undefined }) {
  const [word, setWord] = useState('')
  const [restore, setRestore] = useState(true)
  const status = st.session?.status
  return (
    <>
      {cur && (
        <div className="tbl" style={{ padding: 14 }}>
          <div className="rrow"><span>Squadre entrate</span><b>{cur.teams}</b></div>
          <div className="rrow"><span>Scommesse aperte</span><b>{cur.openMarkets}</b></div>
          <div className="rrow"><span>In attesa di esito</span><b>{cur.awaitingResult}</b></div>
          <div className="rrow"><span>In contestazione</span><b>{cur.inAppealWindow}</b></div>
          <div className="rrow"><span>Cassa del Banco</span><b>{fmt(Number(cur.bankCash))}</b></div>
        </div>
      )}
      <h2 className="sec">Reset totale</h2>
      <p className="note">Chiude la serata (puntate in corso rimborsate) e ne apre una nuova: saldi, squadre e scommesse ripartono da zero. I telefoni tornano alla scelta della squadra.</p>
      <label htmlFor="rw">Scrivi RESET per confermare</label>
      <input id="rw" autoCapitalize="characters" autoComplete="off" value={word} onChange={(e) => setWord(e.target.value)} />
      <label className="rcheck"><input type="checkbox" checked={restore} onChange={(e) => setRestore(e.target.checked)} /> Riporta l'apertura del Banco al 13/11 alle 20:00</label>
      <button className="cta sm" disabled={busy || word !== 'RESET'} onClick={async () => { if (await act('reset-all', { confirm: word, restoreBank: restore }, 'Nuova serata aperta.')) setWord('') }}>RESET TOTALE</button>
      <h2 className="sec">Chiusura serata</h2>
      <p className="note">Ferma nuove puntate e scommesse; esiti e contestazioni in corso finiscono, poi la classifica si congela.</p>
      <div className="btns">
        <button disabled={busy || status !== 'active' && status !== 'paused'} onClick={() => void act('close-session', {}, 'Chiusura avviata.', 'Chiudere la serata?')}>Chiudi serata</button>
        <button disabled={busy || status !== 'closing'} onClick={() => void act('force-finalize', {}, 'Serata chiusa.', 'Chiusura forzata: annulla e rimborsa subito tutto ciò che è in corso. Continuare?')}>Chiusura forzata</button>
      </div>
    </>
  )
}

function Banco({ st, act, busy }: P) {
  const [at, setAt] = useState(localInput(st.bankStart))
  const paused = !!st.session?.bankPaused
  return (
    <>
      <div className="tbl" style={{ padding: 14 }}>
        <div className="rrow"><span>Banco</span><b>{!st.bankOpen ? 'non ancora aperto' : paused ? 'in pausa' : 'in servizio'}</b></div>
        <div className="rrow"><span>Apre alle</span><b>{new Date(st.bankStart).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' })}</b></div>
        <div className="rrow"><span>Prossimo intervento</span><b>{when(st.session?.bankNextAt ?? null)}</b></div>
        <div className="rrow"><span>Prossimo sponsor</span><b>{when(st.session?.sponsorNextAt ?? null)}</b></div>
      </div>
      <p className="note">Prima dell'apertura non partono Banco, bonus, malus, sponsor e piogge. La colletta per bancarotta e la riammissione funzionano sempre.</p>
      <button className="cta sm" disabled={busy || !st.session} onClick={() => void act('bank-now', {}, 'Banco avviato.', 'Avviare il Banco adesso?')}>AVVIA BANCO ADESSO</button>
      <label htmlFor="rat">Orario di apertura (ora del tuo telefono)</label>
      <input id="rat" type="datetime-local" value={at} onChange={(e) => setAt(e.target.value)} />
      <button className="ghost" disabled={busy || !at} onClick={() => void act('bank-start', { at: new Date(at).toISOString() }, 'Orario aggiornato.')}>Imposta orario</button>
      <div className="btns" style={{ marginTop: 12 }}>
        <button disabled={busy || !st.session} onClick={() => void act('bank-pause', { paused: !paused }, paused ? 'Banco ripreso.' : 'Banco in pausa.')}>{paused ? 'Riprendi Banco' : 'Metti in pausa'}</button>
      </div>
    </>
  )
}

function Schermo({ st, act, busy }: P) {
  const [text, setText] = useState('')
  const [minutes, setMinutes] = useState('10')
  const m = Number(minutes)
  const valid = text.trim().length > 0 && Number.isInteger(m) && m >= 1 && m <= 240
  return (
    <>
      <p className="note">Lo schermo della sala è <b>/tv</b>: si apre da qualsiasi browser, senza codice. L'annuncio compare in un banner in alto per il tempo scelto.</p>
      <div className="tbl" style={{ padding: 14 }}>
        <div className="rrow"><span>Ora sullo schermo</span><b>{st.tvMessage ? `«${st.tvMessage.text}» fino alle ${when(st.tvMessage.until)}` : 'nessun annuncio'}</b></div>
      </div>
      <label htmlFor="tvt">Annuncio (max 140 caratteri)</label>
      <input id="tvt" maxLength={140} placeholder="Es. Si cena alle 21!" value={text} onChange={(e) => setText(e.target.value)} />
      <label htmlFor="tvm">Per quanti minuti</label>
      <input id="tvm" inputMode="numeric" value={minutes} onChange={(e) => setMinutes(e.target.value)} />
      <button className="cta sm" disabled={busy || !st.session || !valid} onClick={() => void act('tv-message', { text: text.trim(), minutes: m }, 'Annuncio sullo schermo.').then((ok) => { if (ok) setText('') })}>MANDA SULLO SCHERMO</button>
      <button className="ghost" disabled={busy || !st.tvMessage} onClick={() => void act('tv-message', { text: '' }, 'Annuncio tolto.')}>Togli l'annuncio</button>
    </>
  )
}

function Squadre({ st, act, busy }: P) {
  const [open, setOpen] = useState<number | null>(null)
  const [delta, setDelta] = useState('')
  const [sign, setSign] = useState<1 | -1>(1)
  const [reason, setReason] = useState('')
  return (
    <div className="tbl">
      {st.teams.map((t) => (
        <div className="rteam" key={t.id}>
          <div className="rh">
            <span className="nm">{t.name}{t.status === 'bankrupt' && <em> · bancarotta</em>}</span>
            <span className="val">{t.entered ? fmt(Number(t.balance)) : '—'}</span>
          </div>
          <div className="rs">{t.entered ? `${t.devices} ${t.devices === 1 ? 'dispositivo' : 'dispositivi'}` : 'non è ancora entrata'}</div>
          {t.entered && (
            <div className="btns">
              <button className="sm" disabled={busy} onClick={() => void act('reset-team', { teamId: t.id }, `${t.name} è di nuovo libera.`, `Resettare ${t.name}? Si scollegano i suoi telefoni, saldo e storico restano.`)}>Resetta</button>
              <button className="sm" onClick={() => setOpen(open === t.id ? null : t.id)}>Rettifica saldo</button>
            </div>
          )}
          {open === t.id && (
            <div className="rform">
              <div className="rkchips" role="group" aria-label="Segno della rettifica">
                <button className={`chip${sign === 1 ? ' on' : ''}`} onClick={() => setSign(1)}>+ Aggiungi</button>
                <button className={`chip${sign === -1 ? ' on' : ''}`} onClick={() => setSign(-1)}>− Togli</button>
              </div>
              <input inputMode="numeric" placeholder="Quanti Carletti (solo cifre)" value={delta} onChange={(e) => setDelta(e.target.value.replace(/\D/g, ''))} />
              <input placeholder="Motivo (obbligatorio)" value={reason} onChange={(e) => setReason(e.target.value)} />
              <button className="sm" disabled={busy || !/^[1-9]\d*$/.test(delta) || reason.trim().length < 3}
                onClick={async () => { if (await act('adjust', { teamId: t.id, delta: sign * Number(delta), reason }, 'Saldo rettificato.', `${sign === 1 ? 'Aggiungere' : 'Togliere'} ${delta} Carletti a ${t.name}?`)) { setOpen(null); setDelta(''); setReason(''); setSign(1) } }}>Applica</button>
            </div>
          )}
        </div>
      ))}
    </div>
  )
}

function Scommesse({ st, act, busy }: P) {
  const live = st.markets.filter((m) => m.status === 'open' || m.status === 'closed')
  const rest = st.markets.filter((m) => m.status !== 'open' && m.status !== 'closed')
  const row = (m: MarketRow) => (
    <div className="rteam" key={m.id}>
      <div className="rh"><span className="nm">{m.raceId ? `Corsa ${m.raceId}` : `n. ${m.no} · ${m.by}`}</span><span className="pill">{STATUS[m.status]}{m.outcome ? ` ${m.outcome === 'yes' ? 'SÌ' : 'NO'}` : ''}</span></div>
      <div className="rq">{m.question}</div>
      <div className="rs">Puntate: SÌ {fmt(Number(m.yesPool))} · NO {fmt(Number(m.noPool))}{m.byAdmin && ' · Esitata dalla Regia'}</div>
      {(m.status === 'open' || m.status === 'closed') && (
        <div className="btns">
          {!m.raceId && <button className="sm" disabled={busy} onClick={() => void act(`markets/${m.id}/resolve`, { outcome: 'yes' }, `Scommessa n. ${m.no} esitata SÌ.`, `Esitare la n. ${m.no} come SÌ? È definitivo.`)}>Esita SÌ</button>}
          {!m.raceId && <button className="sm" disabled={busy} onClick={() => void act(`markets/${m.id}/resolve`, { outcome: 'no' }, `Scommessa n. ${m.no} esitata NO.`, `Esitare la n. ${m.no} come NO? È definitivo.`)}>Esita NO</button>}
          <button className="sm" disabled={busy} onClick={() => void act(`markets/${m.id}/void`, {}, `Scommessa n. ${m.no} annullata e rimborsata.`, `Annullare la n. ${m.no} e rimborsare le puntate? Il costo di creazione non si restituisce.`)}>Annulla con rimborso</button>
        </div>
      )}
    </div>
  )
  return (
    <>
      <h2 className="sec">Da gestire</h2>
      <div className="tbl">{live.length ? live.map(row) : <p className="empty" style={{ padding: 14 }}>Nessuna scommessa aperta o da esitare.</p>}</div>
      <h2 className="sec">Chiuse</h2>
      <div className="tbl">{rest.length ? rest.map(row) : <p className="empty" style={{ padding: 14 }}>Nessuna.</p>}</div>
    </>
  )
}

const RACE_STATUS: Record<string, string> = {
  not_started: 'NON PARTITA', running: 'IN CORSO', paused: 'IN PAUSA', finished: 'CONCLUSA', aborted: 'INTERROTTA',
}
const clock = (sec: number) => {
  const t = Math.max(0, Math.floor(sec))
  return `${Math.floor(t / 3600)}:${String(Math.floor((t % 3600) / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`
}

function Corsa({ st, act, busy }: P) {
  const r = st.race
  const [mins, setMins] = useState('')
  const active = !!st.session && st.session.status === 'active'
  if (!r.loaded) return <p className="note">Nessuna corsa caricata sul server: controlla i file in server/data.</p>
  const status = r.status ?? 'not_started'
  const bets = st.markets.filter((m) => m.raceId)
  return (
    <>
      <div className="rteam">
        <div className="rh"><span className="nm">{r.name}</span><span className="pill">{RACE_STATUS[status]}</span></div>
        <div className="rs">
          Tempo di gara {clock(r.elapsed ?? 0)} su {clock(r.durationSeconds ?? 0)} · notizie uscite {r.published ?? 0} su {r.totalEvents ?? 0} · puntate raccolte {r.bets ?? 0}
        </div>
        <div className="btns">
          {status === 'not_started' && (
            <button className="sm" disabled={busy || !active} onClick={() => void act('race-start', {}, 'Corsa partita.', 'Far partire la corsa adesso? Si può fare una sola volta a serata e le notizie escono in tempo reale.')}>AVVIA CORSA</button>
          )}
          {status === 'running' && (
            <button className="sm" disabled={busy} onClick={() => void act('race-pause', { paused: true }, 'Corsa in pausa.', 'Mettere in pausa la corsa? Il tempo e le scommesse si fermano.')}>Pausa</button>
          )}
          {status === 'paused' && (
            <button className="sm" disabled={busy} onClick={() => void act('race-pause', { paused: false }, 'Corsa ripresa.')}>Riprendi</button>
          )}
        </div>
        <div className="rs">
          Durata della corsa: <b>{r.durationMin ?? 180} minuti</b>{(r.durationMin ?? 180) < 180 ? ` (prova accelerata ×${Math.round(180 / (r.durationMin ?? 180) * 10) / 10})` : ' (tempo reale)'}
          {status !== 'not_started' && r.speed && r.speed > 1 ? ` · in corso a ×${Math.round(r.speed * 10) / 10}` : ''}
        </div>
        {status === 'not_started' && (
          <div className="rform">
            <input inputMode="numeric" placeholder="Durata in minuti (da 5 a 180)" value={mins} onChange={(e) => setMins(e.target.value.replace(/[^0-9]/g, ''))} />
            <button className="sm" disabled={busy || !/^[0-9]+$/.test(mins) || Number(mins) < 5 || Number(mins) > 180 || Number(mins) === (r.durationMin ?? 180)}
              onClick={async () => { if (await act('race-duration', { minutes: Number(mins) }, `Durata della corsa: ${mins} minuti.`)) setMins('') }}>Imposta durata</button>
            <div className="rs">Vale solo prima di Avvia corsa. 180 = tempo normale; per esempio 18 minuti = 10 volte più veloce (notizie, aperture e chiusure comprese). Ricordati di rimettere 180 per la serata vera.</div>
          </div>
        )}
        {status === 'not_started' && !active && <div className="rs">Serve una serata attiva per avviare la corsa.</div>}
        {status === 'aborted' && <div className="rs">Interrotta dalla chiusura della serata o dal reset: le puntate non decise sono state rimborsate.</div>}
      </div>
      <h2 className="sec">Scommesse della corsa</h2>
      <div className="tbl">
        {bets.length ? bets.map((m) => (
          <div className="rteam" key={m.id}>
            <div className="rh"><span className="nm">{m.raceId}</span><span className="pill">{STATUS[m.status]}{m.outcome ? ` ${m.outcome === 'yes' ? 'SÌ' : 'NO'}` : ''}</span></div>
            <div className="rq">{m.question}</div>
            <div className="rs">Puntate: SÌ {fmt(Number(m.yesPool))} · NO {fmt(Number(m.noPool))}</div>
          </div>
        )) : <p className="empty" style={{ padding: 14 }}>Nessuna scommessa ancora aperta.</p>}
      </div>
    </>
  )
}

function Parametri({ st, act, busy }: P) {
  const [vals, setVals] = useState<Record<string, string>>({})
  return (
    <>
      <p className="note">Valgono subito. «Tempo totale per esitare» vale anche per le scommesse già scadute e non ancora annullate.</p>
      {PARAMS.map((p) => {
        const cur = st.params[p.key]
        const v = vals[p.key] ?? String(cur)
        return (
          <div className="rparam" key={p.key}>
            <label htmlFor={`p-${p.key}`}>{p.label} <small>({p.unit})</small></label>
            <div className="rp">
              <input id={`p-${p.key}`} inputMode="numeric" value={v} onChange={(e) => setVals({ ...vals, [p.key]: e.target.value })} />
              <button className="sm" disabled={busy || !/^\d+$/.test(v) || Number(v) === Number(cur)} onClick={async () => { if (await act('param', { key: p.key, value: Number(v) }, `${p.label}: ${v}.`)) setVals((o) => { const n = { ...o }; delete n[p.key]; return n }) }}>Salva</button>
            </div>
          </div>
        )
      })}
    </>
  )
}
