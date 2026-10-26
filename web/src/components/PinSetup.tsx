import { useState } from 'react'
import { actions } from '../store/game'
import { Sheet } from './Sheet'

const digits = (v: string) => v.replace(/\D/g, '').slice(0, 4)

/** Per le squadre senza PIN (entrate prima della sua introduzione): senza, un altro telefono potrebbe sceglierlo lui. */
export function PinSetup({ teamId, team, onDone }: { teamId: number; team: string | null; onDone: () => void }) {
  const [pin, setPin] = useState('')
  const [pin2, setPin2] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const save = async () => {
    if (pin.length !== 4 || busy) return
    if (pin !== pin2) { setError('I due PIN non coincidono.'); return }
    setBusy(true)
    const r = await actions.setOwnPin(teamId, pin)
    setBusy(false)
    if (r.ok) onDone()
    else setError(r.error)
  }

  return (
    <Sheet onClose={onDone}>
      <div className="hd">IMPOSTA IL PIN</div>
      <p className="sq" style={{ fontSize: 22 }}>{team}</p>
      <p className="note">Scegli 4 cifre. Ti serviranno per rientrare in questa squadra da un altro telefono: senza PIN chiunque potrebbe prenderla.</p>
      <label className="note" htmlFor="npin1">PIN</label>
      <input id="npin1" type="password" inputMode="numeric" autoComplete="off" maxLength={4} value={pin} onChange={(e) => setPin(digits(e.target.value))} />
      <label className="note" htmlFor="npin2">Ripeti il PIN</label>
      <input id="npin2" type="password" inputMode="numeric" autoComplete="off" maxLength={4} value={pin2}
        onChange={(e) => setPin2(digits(e.target.value))} onKeyDown={(e) => e.key === 'Enter' && void save()} />
      {error && <p className="err" role="alert">{error}</p>}
      <button className="cta sm" disabled={busy || pin.length !== 4 || pin2.length !== 4} onClick={() => void save()}>SALVA PIN</button>
      <button className="ghost" onClick={onDone}>Più tardi</button>
    </Sheet>
  )
}
