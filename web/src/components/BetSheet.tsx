import { useState } from 'react'
import { cur, odds } from '../lib/format'
import { MIN_BET, payout } from '../lib/rules'
import { actions, useGame, type Side } from '../store/game'
import { Sheet } from './Sheet'

export function BetSheet({ marketId, side, onClose }: { marketId: number; side: Side; onClose: () => void }) {
  const s = useGame()
  const m = s.markets.find((x) => x.id === marketId)
  const [raw, setRaw] = useState('50')
  const [serverError, setServerError] = useState('')
  const [busy, setBusy] = useState(false)
  if (!m) return null

  const cents = side === 'yes' ? m.yes : m.no
  const amount = Number(raw)
  const valid = raw.trim() !== '' && Number.isInteger(amount)
  let error = ''
  if (!valid || amount < MIN_BET) error = `Puntata minima ${cur(MIN_BET)}.`
  else if (amount > s.balance) error = `Saldo insufficiente: hai ${cur(s.balance)}.`

  const confirm = async () => {
    if (busy) return // doppio tap: una sola richiesta in volo
    setBusy(true)
    const r = await actions.placeBet(marketId, side, amount)
    setBusy(false)
    if (r.ok) onClose()
    else setServerError(r.error)
  }

  return (
    <Sheet onClose={onClose}>
      <div className="hd">
        <span className="qq">{side === 'yes' ? 'SÌ' : 'NO'}</span>
        <span className="num">@ {odds(cents)}</span>
      </div>
      <p className="sq">{m.text}</p>
      <label htmlFor="amt">Importo (₡)</label>
      <input
        id="amt"
        type="number"
        inputMode="numeric"
        min={MIN_BET}
        step={1}
        value={raw}
        onChange={(e) => {
          setRaw(e.target.value)
          setServerError('')
        }}
      />
      <div className="chips">
        {[25, 50, 100, 250].map((v) => (
          <button key={v} className={`chip${amount === v ? ' on' : ''}`} onClick={() => setRaw(String(v))}>
            {v}
          </button>
        ))}
        <button className={`chip${amount === s.balance ? ' on' : ''}`} onClick={() => setRaw(String(s.balance))}>
          MAX
        </button>
      </div>
      <dl className="sum">
        <div><dt>Quota</dt><dd>{odds(cents)}</dd></div>
        <div><dt>Puntata</dt><dd>{valid ? cur(amount) : '—'}</dd></div>
        <div className="big"><dt>Incasso potenziale</dt><dd>{valid && amount > 0 ? cur(payout(amount, cents)) : '—'}</dd></div>
      </dl>
      <p className="err" role="alert">{error || serverError}</p>
      <button className="cta sm" disabled={!!error || busy} onClick={confirm}>CONFERMA PUNTATA</button>
      <button className="ghost" onClick={onClose}>Annulla</button>
    </Sheet>
  )
}
