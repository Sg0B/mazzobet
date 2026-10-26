import { useEffect, useState } from 'react'
import { actions, type TeamInfo } from '../store/game'
import { Sheet } from '../components/Sheet'

const digits = (v: string) => v.replace(/\D/g, '').slice(0, 4)

export function TeamSelect() {
  const [teams, setTeams] = useState<TeamInfo[] | null>(null)
  const [loadError, setLoadError] = useState(false)
  const [pick, setPick] = useState<TeamInfo | null>(null)
  const [pin, setPin] = useState('')
  const [pin2, setPin2] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [lockUntil, setLockUntil] = useState(0)
  const [now, setNow] = useState(Date.now())

  const load = () => actions.listTeams().then(setTeams).catch(() => setLoadError(true))
  useEffect(() => { void load() }, [])

  useEffect(() => {
    if (lockUntil <= Date.now()) return
    const i = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(i)
  }, [lockUntil])

  const open = (t: TeamInfo) => {
    setPick(t)
    setPin('')
    setPin2('')
    setError('')
    setLockUntil(t.lockedSecs > 0 ? Date.now() + t.lockedSecs * 1000 : 0)
    setNow(Date.now())
  }
  const close = () => { setPick(null); void load() }

  const setting = pick ? !pick.hasPin : false
  const lockedSecs = Math.max(0, Math.ceil((lockUntil - now) / 1000))
  const ready = pin.length === 4 && (!setting || pin2.length === 4) && lockedSecs === 0

  const enter = async () => {
    if (!pick || busy || !ready) return
    if (setting && pin !== pin2) {
      setError('I due PIN non coincidono.')
      return
    }
    setBusy(true)
    setError('')
    const r = await actions.enterTeam(pick.id, pin)
    setBusy(false)
    if (r.ok) return
    setError(r.error)
    setPin('')
    setPin2('')
    if (r.lockedSecs) {
      setLockUntil(Date.now() + r.lockedSecs * 1000)
      setNow(Date.now())
    }
  }

  return (
    <>
      <div className="top"><div className="logo">MAZZO<b>BET</b></div></div>
      <div className="hero">
        <h1>Con quale squadra giochi?</h1>
        <p>Scegli la tua squadra e imposta un PIN di 4 cifre: ti servirà per rientrare da un altro telefono. Nessuna registrazione.</p>
      </div>
      {loadError && <p className="err" role="alert">Non riesco a contattare il server. Ricarica la pagina.</p>}
      {!teams && !loadError && <p className="empty">Carico le squadre…</p>}
      <div style={{ marginTop: 18 }}>
        {teams?.map((t) => (
          <button key={t.id} className="team" onClick={() => open(t)}>
            <span>{t.name}</span>
            {t.entered && <small>già in gioco</small>}
          </button>
        ))}
      </div>
      {pick && (
        <Sheet onClose={close}>
          <div className="hd">{setting ? 'IMPOSTA IL PIN PER' : 'STAI ENTRANDO COME'}</div>
          <p className="sq" style={{ fontSize: 22 }}>{pick.name}</p>
          {pick.entered && !setting && <p className="note">Già in gioco. Se è la tua, inserisci il PIN.</p>}
          {pick.entered && setting && <p className="note">Questa squadra è già in gioco ma non ha ancora un PIN: scegline uno.</p>}
          {lockedSecs > 0 ? (
            <p className="err" role="alert">Troppi tentativi. Riprova tra {lockedSecs} secondi.</p>
          ) : (
            <>
              <label className="note" htmlFor="pin1">{setting ? 'Scegli un PIN di 4 cifre' : 'PIN'}</label>
              <input id="pin1" type="password" inputMode="numeric" autoComplete="off" maxLength={4} autoFocus
                value={pin} onChange={(e) => setPin(digits(e.target.value))}
                onKeyDown={(e) => e.key === 'Enter' && (setting ? undefined : void enter())} />
              {setting && (
                <>
                  <label className="note" htmlFor="pin2">Ripeti il PIN</label>
                  <input id="pin2" type="password" inputMode="numeric" autoComplete="off" maxLength={4}
                    value={pin2} onChange={(e) => setPin2(digits(e.target.value))}
                    onKeyDown={(e) => e.key === 'Enter' && void enter()} />
                </>
              )}
              {error && <p className="err" role="alert">{error}</p>}
            </>
          )}
          <button className="cta sm" disabled={busy || !ready} onClick={() => void enter()}>
            {setting ? 'ENTRA' : 'SONO IO, ENTRA'}
          </button>
          <button className="ghost" onClick={close}>Indietro</button>
        </Sheet>
      )}
    </>
  )
}
