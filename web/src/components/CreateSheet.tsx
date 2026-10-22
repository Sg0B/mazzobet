import { useRef, useState } from 'react'
import { CREATE_FEE, parseOdds } from '../lib/rules'
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
  const [text, setText] = useState('')
  const [yes, setYes] = useState('1,90')
  const [no, setNo] = useState('1,90')
  const [close, setClose] = useState<Close>('20')
  const [time, setTime] = useState('')
  const [error, setError] = useState('')

  const attempt = useRef(crypto.randomUUID()) // stessa chiave a ogni retry: mai due mercati
  const [busy, setBusy] = useState(false)

  const publish = async () => {
    if (busy) return
    const q = text.trim()
    const y = parseOdds(yes)
    const n = parseOdds(no)
    if (q.length < 8) return setError('Scrivi una domanda chiara, almeno 8 caratteri.')
    if (!y || !n) return setError('Le quote devono essere tra 1,10 e 10,00, con due decimali.')
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
        {CHOICES.map((c) => (
          <button key={c.id} className={`chip${close === c.id ? ' on' : ''}`} onClick={() => setClose(c.id)}>
            {c.label}
          </button>
        ))}
      </div>
      {close === 'time' && (
        <>
          <label htmlFor="ctime">Orario di chiusura (entro le 03:00)</label>
          <input id="ctime" type="time" value={time} onChange={(e) => setTime(e.target.value)} />
        </>
      )}
      <p className="note">Dovrai indicare l’esito entro 15 minuti dalla scadenza; chiunque non abbia puntato può farlo al tuo posto. Se nessuno esita, la scommessa è annullata.</p>
      <p className="err" role="alert">{error}</p>
      <button className="cta sm" disabled={s.balance < CREATE_FEE || busy} onClick={publish}>PUBBLICA · {cur(CREATE_FEE)}</button>
      <button className="ghost" onClick={onClose}>Annulla</button>
    </Sheet>
  )
}
