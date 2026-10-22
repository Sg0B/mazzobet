import { useRef, useState } from 'react'
import { oddsMarginOk, parseOdds } from '../lib/rules'
import { MIN, cur } from '../lib/format'
import { actions, serverNow, useGame } from '../store/game'
import { Sheet } from './Sheet'

type Close = '20' | '30' | '60' | '120' | 'time'
const CHOICES: { id: Close; label: string }[] = [
  { id: '20', label: 'LIVE 20 MIN' },
  { id: '30', label: '+30 min' },
  { id: '60', label: '+1 h' },
  { id: '120', label: '+2 h' },
  { id: 'time', label: 'Orario' },
]

export function CreateSheet({ onClose }: { onClose: () => void }) {
  const s = useGame()
  const c = s.config
  const [text, setText] = useState('')
  const [yes, setYes] = useState('1,90')
  const [no, setNo] = useState('1,90')
  const [close, setClose] = useState<Close>('20')
  const [time, setTime] = useState('')
  const [error, setError] = useState('')
  const attempt = useRef(crypto.randomUUID()) // stessa chiave a ogni retry: mai due scommesse
  const [busy, setBusy] = useState(false)

  const publish = async () => {
    if (busy) return
    const q = text.trim()
    const y = parseOdds(yes, c.oddsMin, c.oddsMax)
    const n = parseOdds(no, c.oddsMin, c.oddsMax)
    if (q.length < 8) return setError('Scrivi una domanda chiara, almeno 8 caratteri.')
    if (!y || !n) return setError('Le quote devono essere tra 1,10 e 10,00, con due decimali.')
    if (!oddsMarginOk(y, n)) return setError('Quote troppo generose: con queste il Banco regalerebbe Carletti. Abbassa una delle due.')
    const now = serverNow()
    let expiresAt: number
    if (close === 'time') {
      if (!time) return setError('Scegli un orario di chiusura.')
      const [h, mi] = time.split(':').map(Number)
      const d = new Date()
      d.setHours(h, mi, 0, 0)
      if (d.getTime() <= now) d.setDate(d.getDate() + 1)
      expiresAt = d.getTime()
    } else expiresAt = now + Number(close) * MIN
    if (expiresAt - now < MIN) return setError('Scegli un orario più avanti.')
    if (s.endsAt && expiresAt > s.endsAt) return setError('Oltre le 03:00 non si può.')
    setBusy(true)
    const r = await actions.createMarket({ text: q, yes: y, no: n, expiresAt, key: attempt.current })
    setBusy(false)
    if (r.ok) onClose()
    else setError(r.error)
  }

  return (
    <Sheet onClose={onClose}>
      <div className="hd">NUOVA SCOMMESSA</div>
      <label htmlFor="cq">Domanda con esito SÌ / NO</label>
      <textarea id="cq" maxLength={120} value={text} onChange={(e) => setText(e.target.value)} placeholder="Es. Paolo offre una birra a Sonia entro le 23:00?" />
      <p className="note">Meglio un fatto verificabile da chiunque al tavolo.</p>
      <div className="two">
        <div>
          <label htmlFor="cy">Quota SÌ</label>
          <input id="cy" inputMode="decimal" value={yes} onChange={(e) => setYes(e.target.value)} />
        </div>
        <div>
          <label htmlFor="cn">Quota NO</label>
          <input id="cn" inputMode="decimal" value={no} onChange={(e) => setNo(e.target.value)} />
        </div>
      </div>
      <p className="note">Quote da 1,10 a 10,00, fisse per tutta la durata.</p>
      <label>Chiusura</label>
      <div className="chips">
        {CHOICES.map((ch) => (
          <button key={ch.id} className={`chip${close === ch.id ? ' on' : ''}`} onClick={() => setClose(ch.id)}>
            {ch.label}
          </button>
        ))}
      </div>
      {close === 'time' && (
        <>
          <label htmlFor="ctime">Orario di chiusura (entro le 03:00)</label>
          <input id="ctime" type="time" value={time} onChange={(e) => setTime(e.target.value)} />
        </>
      )}
      <p className="note">
        Se esiti tu la scommessa ricevi il {c.feePct}% delle puntate (max {cur(c.feeCap)}). Se la esita un altro, non ricevi nulla.
      </p>
      <p className="note">
        Dopo la scadenza esiti per primo tu ({c.creatorPriorityMin} minuti); poi può farlo chiunque non abbia puntato, fino a {c.creatorPriorityMin + c.resolveWindowMin} minuti.
        Se nessuno esita la scommessa è annullata. Senza puntate si chiude da sola.
      </p>
      <p className="err" role="alert">{error}</p>
      <button className="cta sm" disabled={s.balance < c.createFee || busy} onClick={publish}>PUBBLICA · {cur(c.createFee)}</button>
      <button className="ghost" onClick={onClose}>Annulla</button>
    </Sheet>
  )
}
