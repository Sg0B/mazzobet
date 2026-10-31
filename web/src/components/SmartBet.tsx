import { useEffect, useRef, useState } from 'react'
import { cur, mmss, odds } from '../lib/format'
import { payout } from '../lib/rules'
import { actions, raceElapsed, useGame, type Market, type Side } from '../store/game'
import { PcsLogo } from './PcsLogo'

const CUTS = [50, 100, 250]
const ALL_IN = 'all'
type Pick = { side: Side | null; cut: number | typeof ALL_IN | null }

/**
 * Smart Bet: le scommesse del Banco aperte, una card per volta, nel tab Corsa sopra la cronaca.
 * Scorrimento a mano (swipe, frecce, pallini), nessun autoplay. La scelta SÌ/NO e il taglio restano
 * memorizzati passando da una card all'altra; la puntata parte solo con CONFERMA (ALL-IN compreso: nessun secondo dialogo).
 */
export function SmartBet() {
  const s = useGame()
  const list = s.markets
    .filter((m) => m.race && m.status === 'open')
    .sort((a, b) => a.race!.closesAt - b.race!.closesAt || a.race!.opensAt - b.race!.opensAt)
  const [picks, setPicks] = useState<Record<number, Pick>>({})
  const [idx, setIdx] = useState(0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<Record<number, string>>({})
  const track = useRef<HTMLDivElement>(null)

  // se la lista si accorcia (una scommessa si chiude) l'indice resta dentro i limiti
  const n = list.length
  const cur_ = Math.min(idx, Math.max(0, n - 1))
  useEffect(() => { if (idx !== cur_) setIdx(cur_) }, [idx, cur_])

  if (n === 0) return null

  const goTo = (i: number) => {
    const k = Math.max(0, Math.min(n - 1, i))
    const el = track.current
    if (el) el.scrollTo({ left: k * el.clientWidth, behavior: 'smooth' })
    setIdx(k)
  }
  const onScroll = () => {
    const el = track.current
    if (!el || !el.clientWidth) return
    const k = Math.round(el.scrollLeft / el.clientWidth)
    if (k !== idx) setIdx(k)
  }

  const min = s.config.betMin
  const rc = s.race
  const paused = rc?.status === 'paused'
  const bankrupt = s.bankruptUntil !== null
  const frozen = s.sessionStatus === 'closing' || s.sessionStatus === 'closed'

  const setPick = (id: number, p: Partial<Pick>) => {
    setPicks((all) => ({ ...all, [id]: { ...(all[id] ?? { side: null, cut: null }), ...p } }))
    setErr((e) => ({ ...e, [id]: '' }))
  }

  const confirm = async (m: Market, side: Side, amount: number) => {
    if (busy) return // doppio tap: una sola richiesta in volo
    setBusy(true)
    const r = await actions.placeBet(m.id, side, amount)
    setBusy(false)
    if (!r.ok) setErr((e) => ({ ...e, [m.id]: r.error }))
  }

  return (
    <section className="smart" aria-label="Scommesse del Banco aperte">
      <div className="smart-hd">
        <h2 className="sec rsec"><span className="dot" />Scommesse aperte</h2>
        <span className="smart-n num" aria-live="polite">{cur_ + 1} di {n}</span>
      </div>
      <div className="smart-wrap">
        <button className="smart-arrow" aria-label="Scommessa precedente" disabled={cur_ === 0} onClick={() => goTo(cur_ - 1)}>‹</button>
        <div className="smart-track" ref={track} onScroll={onScroll}>
          {list.map((m) => {
            const p = picks[m.id] ?? { side: null, cut: null }
            const toClose = (m.race!.closesAt - raceElapsed(rc, s.now)) / (rc?.speed || 1)
            const done = !!m.my
            const lock = done || bankrupt || frozen || paused
            const amount = p.cut === ALL_IN ? s.balance : p.cut ?? 0
            const cents = p.side === 'yes' ? m.yes : m.no
            const bad = amount < min ? `Puntata minima ${cur(min)}.` : amount > s.balance ? 'Saldo insufficiente.' : ''
            const ready = !!p.side && p.cut !== null && !bad
            return (
              <article className="smart-card" key={m.id} aria-hidden={list[cur_]?.id !== m.id}>
                <div className="card-top">
                  <span className="tag"><PcsLogo mini />{m.race!.id}</span>
                  <span className="cd"><small>chiude tra</small>{paused ? <span className="pause">in pausa</span> : <span className="num">{mmss(Math.max(0, toClose) * 1000)}</span>}</span>
                </div>
                {m.category && <div className="smart-cat">{m.category}</div>}
                <h3>{m.text}</h3>
                {done ? (
                  <p className="smart-done">✓ Hai puntato <b>{cur(m.my!.amount)}</b> su <b>{m.my!.side === 'yes' ? 'SÌ' : 'NO'}</b> — in attesa del risultato.</p>
                ) : (
                  <>
                    <div className="odds">
                      {(['yes', 'no'] as const).map((side) => (
                        <button key={side} className={`odd${p.side === side ? ' picked' : ''}`} disabled={lock} onClick={() => setPick(m.id, { side })}
                          aria-pressed={p.side === side} aria-label={`${side === 'yes' ? 'SÌ' : 'NO'} a quota ${odds(side === 'yes' ? m.yes : m.no)}`}>
                          <span className="lbl">{side === 'yes' ? 'SÌ' : 'NO'}</span>
                          <span className="q">{odds(side === 'yes' ? m.yes : m.no)}</span>
                        </button>
                      ))}
                    </div>
                    <div className="smart-bal">Saldo disponibile <b className="num">{cur(s.balance)}</b></div>
                    <div className="chips">
                      {CUTS.map((v) => (
                        <button key={v} className={`chip${p.cut === v ? ' on' : ''}`} disabled={lock || v > s.balance || v < min} onClick={() => setPick(m.id, { cut: v })}>₡{v}</button>
                      ))}
                      <button className={`chip${p.cut === ALL_IN ? ' on' : ''}`} disabled={lock || s.balance < min} onClick={() => setPick(m.id, { cut: ALL_IN })}>ALL-IN</button>
                    </div>
                    {ready && <p className="smart-sum">{cur(amount)} su {p.side === 'yes' ? 'SÌ' : 'NO'} @ {odds(cents)} · incasso potenziale <b>{cur(payout(amount, cents))}</b></p>}
                    <p className="err" role="alert">{err[m.id] ?? ''}</p>
                    <button className="cta sm" disabled={lock || !ready || busy} onClick={() => p.side && confirm(m, p.side, amount)}>CONFERMA PUNTATA</button>
                    {paused && <p className="note">La corsa è sospesa: le puntate sono ferme.</p>}
                    {bankrupt && <p className="note">Puntate sospese finché sei in bancarotta.</p>}
                  </>
                )}
              </article>
            )
          })}
        </div>
        <button className="smart-arrow" aria-label="Scommessa successiva" disabled={cur_ >= n - 1} onClick={() => goTo(cur_ + 1)}>›</button>
      </div>
      {n > 1 && (
        <div className="smart-dots" role="tablist" aria-label="Scegli la scommessa">
          {list.map((m, i) => <button key={m.id} role="tab" aria-selected={i === cur_} aria-label={`Scommessa ${i + 1}`} className={i === cur_ ? 'on' : ''} onClick={() => goTo(i)} />)}
        </div>
      )}
    </section>
  )
}
