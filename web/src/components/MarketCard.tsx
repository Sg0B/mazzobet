import { cur, hhmm, odds, MIN } from '../lib/format'
import { payout } from '../lib/rules'
import { isMine, useGame, type Market, type Side } from '../store/game'
import { Countdown } from './Countdown'

const SHORT_MAX_MIN = 30 // fino a questa durata la scommessa è «LIVE»

export function MarketCard({ m, onBet }: { m: Market; onBet: (id: number, side: Side) => void }) {
  const s = useGame()
  const mine = isMine(m)
  const bankrupt = s.bankruptUntil !== null
  const frozen = s.sessionStatus === 'closing' || s.sessionStatus === 'closed'
  const lock = mine || !!m.my || bankrupt || frozen
  const short = m.expiresAt - m.createdAt <= SHORT_MAX_MIN * MIN
  const total = m.yesPool + m.noPool
  const yesPct = total ? Math.round((m.yesPool / total) * 100) : 0

  const odd = (side: Side, label: string, cents: number) => (
    <button className={`odd${m.my?.side === side ? ' picked' : ''}`} disabled={lock} onClick={() => onBet(m.id, side)} aria-label={`${label} a quota ${odds(cents)}`}>
      <span className="lbl">{label}</span>
      <span className="q">{odds(cents)}</span>
    </button>
  )

  return (
    <article className="card">
      <div className="card-top">
        <span className={`tag${short ? ' live' : ''}`}>{short ? 'LIVE' : 'A SCADENZA'}</span>
        <span className="cd">
          <small>chiude tra</small>
          <Countdown until={m.expiresAt} />
        </span>
      </div>
      <h3>{m.text}</h3>
      <div className="by">Scommessa n. {m.num} · di {m.by}<br />Chiude alle {hhmm(m.expiresAt)}</div>
      <div className="odds">
        {odd('yes', 'SÌ', m.yes)}
        {odd('no', 'NO', m.no)}
      </div>
      {total ? (
        <>
          <div className="bar" aria-hidden="true">
            <i style={{ width: `${yesPct}%` }} />
          </div>
          <div className="barl">
            <span>SÌ {yesPct}%</span>
            <span>Carletti puntati</span>
            <span>NO {100 - yesPct}%</span>
          </div>
        </>
      ) : (
        <div className="barl" style={{ marginTop: 12 }}>
          <span>Nessuna puntata</span>
        </div>
      )}
      {mine && <p className="note">È la tua scommessa: non puoi puntare.</p>}
      {!mine && m.my && (
        <p className="note">
          Hai puntato <b>{m.my.side === 'yes' ? 'SÌ' : 'NO'} {cur(m.my.amount)}</b>, incasso potenziale <b>{cur(payout(m.my.amount, m.my.side === 'yes' ? m.yes : m.no))}</b>.
        </p>
      )}
      {!mine && !m.my && bankrupt && <p className="note">Puntate sospese finché sei in bancarotta.</p>}
    </article>
  )
}
