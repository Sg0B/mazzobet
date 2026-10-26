import { useEffect, useState } from 'react'

interface InstallEvent extends Event {
  prompt: () => Promise<void>
}

const KEY = 'mazzobet-install-hint'
const read = () => { try { return localStorage.getItem(KEY) } catch { return null } }
const write = () => { try { localStorage.setItem(KEY, '1') } catch { /* ignora */ } }

const standalone = () =>
  window.matchMedia('(display-mode: standalone)').matches || (navigator as { standalone?: boolean }).standalone === true

/** Suggerisce «Aggiungi a Home»: su Android col pulsante di installazione, su iPhone con le istruzioni (Safari non ha il pulsante). */
export function InstallHint() {
  const [hidden, setHidden] = useState(() => read() !== null || standalone())
  const [ev, setEv] = useState<InstallEvent | null>(null)

  useEffect(() => {
    const h = (e: Event) => { e.preventDefault(); setEv(e as InstallEvent) }
    window.addEventListener('beforeinstallprompt', h)
    return () => window.removeEventListener('beforeinstallprompt', h)
  }, [])

  if (hidden) return null
  const ios = /iphone|ipad|ipod/i.test(navigator.userAgent)
  if (!ios && !ev) return null   // altri browser: nessun suggerimento che non possiamo mantenere

  const close = () => { write(); setHidden(true) }
  return (
    <div className="radio" role="note" style={{ textAlign: 'left' }}>
      <p style={{ WebkitLineClamp: 'unset', display: 'block', color: 'var(--fg)' }}>
        <b>Mettila sulla Home.</b>{' '}
        {ios ? 'In Safari tocca Condividi, poi «Aggiungi alla schermata Home»: si apre a tutto schermo.' : 'Si apre a tutto schermo, come un’app.'}
      </p>
      {ev && <button className="cta sm" onClick={() => { void ev.prompt(); close() }}>AGGIUNGI A HOME</button>}
      <button className="ghost" onClick={close}>Non ora</button>
    </div>
  )
}
