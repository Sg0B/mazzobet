import { useEffect, useState } from 'react'
import { START_BALANCE } from '../lib/rules'
import { cur } from '../lib/format'
import { actions, type TeamInfo } from '../store/game'
import { Sheet } from '../components/Sheet'

export function TeamSelect() {
  const [teams, setTeams] = useState<TeamInfo[] | null>(null)
  const [loadError, setLoadError] = useState(false)
  const [confirm, setConfirm] = useState<TeamInfo | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    actions.listTeams().then(setTeams).catch(() => setLoadError(true))
  }, [])

  const enter = async (t: TeamInfo) => {
    if (busy) return
    setBusy(true)
    setError('')
    const r = await actions.enterTeam(t.id)
    setBusy(false)
    if (!r.ok) {
      setConfirm(null)
      setError(r.error)
    }
  }

  return (
    <>
      <div className="top"><div className="logo">MAZZO<b>BET</b></div></div>
      <div className="hero">
        <h1>Con quale squadra giochi?</h1>
        <p>Scegli la tua squadra ed entri in gara con {cur(START_BALANCE)}. Nessuna registrazione.</p>
      </div>
      {error && <p className="err" role="alert">{error}</p>}
      {loadError && <p className="err" role="alert">Non riesco a contattare il server. Ricarica la pagina.</p>}
      {!teams && !loadError && <p className="empty">Carico le squadre…</p>}
      <div style={{ marginTop: 18 }}>
        {teams?.map((t) => (
          <button key={t.id} className="team" disabled={busy} onClick={() => (t.entered ? setConfirm(t) : enter(t))}>
            <span>{t.name}</span>
            {t.entered && <small>già in gara</small>}
          </button>
        ))}
      </div>
      {confirm && (
        <Sheet onClose={() => setConfirm(null)}>
          <div className="hd">STAI ENTRANDO COME</div>
          <p className="sq" style={{ fontSize: 22 }}>{confirm.name}</p>
          <p className="note">Questa squadra è già in gara, magari su un altro dispositivo. Il Banco vede tutto e non perdona gli scambi di persona.</p>
          <button className="cta sm" disabled={busy} onClick={() => enter(confirm)}>SONO IO, ENTRA</button>
          <button className="ghost" onClick={() => setConfirm(null)}>Indietro</button>
        </Sheet>
      )}
    </>
  )
}
