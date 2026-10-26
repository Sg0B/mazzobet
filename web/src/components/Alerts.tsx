import { useEffect, useState } from 'react'
import { disablePush, enablePush, pushState, type PushState } from '../lib/push'

const KEY = 'mazzobet-alerts-later'
const readLater = () => { try { return localStorage.getItem(KEY) !== null } catch { return false } }
const writeLater = () => { try { localStorage.setItem(KEY, '1') } catch { /* ignora */ } }

const linkStyle = { display: 'inline', textDecoration: 'underline', color: 'var(--muted)' } as const

/** Avvisi (notifiche push): il permesso si chiede solo dopo un tocco. Stati: attivi, disattivati, bloccati dal browser. */
export function Alerts() {
  const [state, setState] = useState<PushState | null>(null)
  const [later, setLater] = useState(readLater)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => { void pushState().then(setState) }, [])

  const run = async (f: () => Promise<PushState>) => {
    setBusy(true)
    setError('')
    try {
      setState(await f())
    } catch {
      setError('Non sono riuscito a cambiare gli avvisi. Riprova.')
    }
    setBusy(false)
  }

  if (!state || state === 'unsupported' || state === 'off-server') return null

  if (state === 'on') {
    return (
      <p className="note" style={{ marginTop: 12 }}>
        Avvisi attivi. <button style={linkStyle} disabled={busy} onClick={() => void run(disablePush)}>Disattiva</button>
      </p>
    )
  }

  if (state === 'blocked') {
    return (
      <p className="note" style={{ marginTop: 12 }}>
        Avvisi bloccati: il telefono non permette le notifiche di MazzoBet. Per sbloccarle apri le impostazioni del telefono (Notifiche → MazzoBet, oppure le impostazioni del sito in Chrome) e poi riapri l'app.
      </p>
    )
  }

  if (later) {
    return (
      <p className="note" style={{ marginTop: 12 }}>
        Avvisi disattivati. <button style={linkStyle} disabled={busy} onClick={() => void run(enablePush)}>Attiva</button>
        {error && <span className="err"> {error}</span>}
      </p>
    )
  }

  return (
    <div className="radio" role="note" style={{ textAlign: 'left' }}>
      <p style={{ WebkitLineClamp: 'unset', display: 'block', color: 'var(--fg)' }}>
        <b>Vuoi ricevere un avviso quando devi esitare una scommessa?</b>
      </p>
      {error && <p className="err" role="alert">{error}</p>}
      <button className="cta sm" disabled={busy} onClick={() => void run(enablePush)}>ATTIVA AVVISI</button>
      <button className="ghost" onClick={() => { writeLater(); setLater(true) }}>Non ora</button>
    </div>
  )
}
